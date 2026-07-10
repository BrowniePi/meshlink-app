import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import 'auth/auth_client.dart';
import 'auth/auth_service.dart';
import 'auth/login_screen.dart';
import 'auth/session_storage.dart';
import 'auth/welcome_screen.dart';
import 'ble_poc/ble_scan_poc_screen.dart';
import 'config/backend_config.dart';
import 'config/wifi_config.dart';
import 'core/pipeline.dart';
import 'friends/directory_client.dart';
import 'friends/friend_service.dart';
import 'friends/friend_store.dart';
import 'identity/device_identity.dart';
import 'identity/encryption_identity.dart';
import 'identity/secure_storage.dart';
import 'identity/token_storage.dart';
import 'onboarding/attestation_flow.dart';
import 'onboarding/onboarding_screen.dart';
import 'onboarding/wifi_mesh_toggle.dart';
import 'power/battery_tier_manager.dart';
import 'telemetry/phone_ping_responder.dart';
import 'transport/ble_transport.dart';
import 'transport/failover_transport.dart';
import 'transport/relay_service.dart';
import 'transport/wifi_transport.dart';
import 'ui/firefly/firefly_home.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Android: keep the BLE relay alive across backgrounding (no-op on iOS).
  RelayService.start();

  final storage = SecureStorage();
  // Real per-device identity (Phase 4): generated once on first launch,
  // private seed held in Keychain/Keystore via the secure-storage bridge.
  final identity = await DeviceIdentity.loadOrGenerate(storage);
  // Friendship: the account's X25519 encryption keypair, kept in the same
  // Keychain/Keystore as the signing seed (no second key store).
  final encryption = await EncryptionIdentity.loadOrGenerate(storage);
  // Phase 5: an attestation token gates relaying. Reuse any still-valid token
  // from a previous launch; onboarding fetches one otherwise.
  final tokenStorage = TokenStorage(storage);
  final stored = await tokenStorage.read();
  final validToken =
      (stored != null && !stored.isExpiredAt(DateTime.now())) ? stored : null;

  // Account session (email + password auth), independent of the attestation
  // token and the device keypairs. Restored from secure storage if present;
  // the first gate is login when it isn't.
  final authService = AuthService(
    client: AuthClient(config: BackendConfig.fromEnvironment),
    sessionStorage: SessionStorage(storage),
    identity: identity,
    encryption: encryption,
    tokenStorage: tokenStorage,
  );
  await authService.init();

  // The welcome/onboarding intro is shown once, after the first verified
  // login. Persisted so returning users skip it.
  final welcomeSeen = await storage.read(_welcomeSeenKey) == 'true';

  runApp(MeshLinkApp(
    identity: identity,
    encryption: encryption,
    storage: storage,
    tokenStorage: tokenStorage,
    authService: authService,
    initialToken: validToken,
    initialWelcomeSeen: welcomeSeen,
  ));
}

/// Secure-storage key marking that the post-first-login welcome intro ran.
const String _welcomeSeenKey = 'meshlink_welcome_seen_v1';

class MeshLinkApp extends StatefulWidget {
  const MeshLinkApp({
    super.key,
    required this.identity,
    required this.encryption,
    required this.storage,
    required this.tokenStorage,
    required this.authService,
    this.initialToken,
    this.initialWelcomeSeen = false,
  });

  final DeviceIdentity identity;
  final EncryptionIdentity encryption;
  final SecureStorage storage;
  final TokenStorage tokenStorage;
  final AuthService authService;
  final AttestationToken? initialToken;
  final bool initialWelcomeSeen;

  @override
  State<MeshLinkApp> createState() => _MeshLinkAppState();
}

class _MeshLinkAppState extends State<MeshLinkApp> {
  AttestationToken? _token;

  /// Phase 6: BLE always-on with WiFi as an opt-in second transport. Built
  /// once — the WiFi toggle state must survive token refreshes and screen
  /// swaps, and the pipeline sees it as the one Transport it always had.
  final FailoverTransport _transport = FailoverTransport(
    ble: BleTransport(),
    wifi: WifiTransport(config: WifiConfig.fromEnvironment),
    // Phase 7: answer the node's 2-minute telemetry pings (location +
    // battery) on whichever transport they arrive on.
    phonePing: PhonePingResponder(),
  );

  /// Phase 7 four-tier battery management: polls every 60 s and throttles
  /// the radios through [FailoverTransport.applyTier] on each transition.
  final BatteryTierManager _batteryTier = BatteryTierManager();

  /// One pipeline for the whole app: chat and the friend service must share
  /// dedup/rate-limit state, or a friend message sent by us would be
  /// re-processed when a peer echoes it back.
  final RelayPipeline _pipeline = RelayPipeline();

  /// Friendship flows (account, requests, location sharing, queries) —
  /// see docs/friendship.md. Built once; screens observe it.
  late final FriendService _friends;
  bool _friendsReady = false;

  /// Whether the WiFi opt-in step has been offered this launch. Offered only
  /// after a fresh attestation fetch (first launch / expiry) — a valid stored
  /// token skips straight to chat, where the AppBar toggle takes over.
  bool _wifiOffered = false;

  /// Whether the one-time post-first-login welcome intro has been shown.
  late bool _welcomeSeen;

  @override
  void initState() {
    super.initState();
    _wifiOffered = widget.initialToken != null;
    _welcomeSeen = widget.initialWelcomeSeen;
    _batteryTier.tier.addListener(_onTierChanged);
    _batteryTier.start();

    _friends = FriendService(
      store: FriendStore(widget.storage),
      directory: DirectoryClient(config: BackendConfig.fromEnvironment),
      identity: widget.identity,
      encryption: widget.encryption,
      transport: _transport,
      pipeline: _pipeline,
      readPosition: _readBeaconPosition,
    );
    // Auth binds the account's username into this FriendService on login.
    widget.authService.attachFriends(_friends);
    widget.authService.addListener(_onAuthChanged);
    unawaited(_friends.init().then((_) {
      if (mounted) setState(() => _friendsReady = true);
    }));
  }

  void _onAuthChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _markWelcomeSeen() async {
    await widget.storage.write(_welcomeSeenKey, 'true');
    if (mounted) setState(() => _welcomeSeen = true);
  }

  /// Position source for the friend-location beacon. Same permission-aware
  /// Geolocator flow as the telemetry pong: null (no beacon) on any denial
  /// or failure, never an error.
  static Future<({double lat, double lon, double accuracyM})?>
      _readBeaconPosition() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return null;
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return null;
      }
      Position? position;
      try {
        position = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            timeLimit: Duration(seconds: 4),
          ),
        );
      } on TimeoutException {
        position = await Geolocator.getLastKnownPosition();
      }
      if (position == null) return null;
      return (
        lat: position.latitude,
        lon: position.longitude,
        accuracyM: position.accuracy,
      );
    } catch (_) {
      return null;
    }
  }

  void _onTierChanged() =>
      unawaited(_transport.applyTier(_batteryTier.tier.value));

  @override
  void dispose() {
    _batteryTier.tier.removeListener(_onTierChanged);
    _batteryTier.stop();
    widget.authService.removeListener(_onAuthChanged);
    _friends.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Widget home;
    if (!_friendsReady) {
      // Friend store still loading from secure storage (fast, one read).
      home = const Scaffold(body: Center(child: CircularProgressIndicator()));
    } else if (!widget.authService.isLoggedIn) {
      // Account gate: login runs first so the device's keypairs bind to the
      // account and yield the username. Login screen routes to signup/forgot.
      home = LoginScreen(auth: widget.authService);
    } else if (_token == null) {
      home = OnboardingScreen(
        identity: widget.identity,
        flow: AttestationFlow(config: BackendConfig.fromEnvironment),
        tokenStorage: widget.tokenStorage,
        onComplete: (token) => setState(() => _token = token),
      );
    } else if (!_welcomeSeen) {
      // One-time intro after the first verified login, before mesh setup.
      home = WelcomeScreen(
        username: _friends.store.ownUsername ?? '',
        onContinue: _markWelcomeSeen,
      );
    } else if (!_wifiOffered) {
      home = WifiMeshToggleScreen(
        transport: _transport,
        onDone: () => setState(() => _wifiOffered = true),
      );
    } else {
      home = FireflyHome(
        transport: _transport,
        pipeline: _pipeline,
        identity: widget.identity,
        friendService: _friends,
        attestationToken: _token!,
        batteryTier: _batteryTier,
        readPosition: _readBeaconPosition,
        // Token expired mid-session: drop back to onboarding, which
        // fetches and (on the fresh home) re-presents a new one.
        onTokenExpired: () => setState(() => _token = null),
        onLogout: widget.authService.logout,
      );
    }
    return MaterialApp(
      title: 'Firefly',
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFFE6B34D),
        fontFamily: 'Space Grotesk',
      ),
      home: home,
      routes: {
        // Throwaway plugin PoC, kept reachable for debugging BLE issues.
        '/ble-poc': (_) => BleScanPocScreen(wifiTransport: _transport.wifi),
      },
    );
  }
}
