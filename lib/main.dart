import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

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
import 'onboarding/account_screen.dart';
import 'onboarding/attestation_flow.dart';
import 'onboarding/onboarding_screen.dart';
import 'onboarding/wifi_mesh_toggle.dart';
import 'power/battery_tier_manager.dart';
import 'telemetry/phone_ping_responder.dart';
import 'transport/ble_transport.dart';
import 'transport/failover_transport.dart';
import 'transport/relay_service.dart';
import 'transport/wifi_transport.dart';
import 'ui/chat_screen.dart';

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

  runApp(MeshLinkApp(
    identity: identity,
    encryption: encryption,
    storage: storage,
    tokenStorage: tokenStorage,
    initialToken: validToken,
  ));
}

class MeshLinkApp extends StatefulWidget {
  const MeshLinkApp({
    super.key,
    required this.identity,
    required this.encryption,
    required this.storage,
    required this.tokenStorage,
    this.initialToken,
  });

  final DeviceIdentity identity;
  final EncryptionIdentity encryption;
  final SecureStorage storage;
  final TokenStorage tokenStorage;
  final AttestationToken? initialToken;

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

  @override
  void initState() {
    super.initState();
    _wifiOffered = widget.initialToken != null;
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
    unawaited(_friends.init().then((_) {
      if (mounted) setState(() => _friendsReady = true);
    }));
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
    _friends.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Widget home;
    if (_token == null) {
      home = OnboardingScreen(
        identity: widget.identity,
        flow: AttestationFlow(config: BackendConfig.fromEnvironment),
        tokenStorage: widget.tokenStorage,
        onComplete: (token) => setState(() => _token = token),
      );
    } else if (!_friendsReady) {
      // Friend store still loading from secure storage (fast, one read).
      home = const Scaffold(body: Center(child: CircularProgressIndicator()));
    } else if (!_friends.hasAccount) {
      // Friendship onboarding: pick a username after attestation, before the
      // WiFi step. One-time; skipped on every later launch.
      home = AccountScreen(
        friends: _friends,
        onDone: () => setState(() {}),
      );
    } else if (!_wifiOffered) {
      home = WifiMeshToggleScreen(
        transport: _transport,
        onDone: () => setState(() => _wifiOffered = true),
      );
    } else {
      home = ChatScreen(
        transport: _transport,
        pipeline: _pipeline,
        identity: widget.identity,
        friendService: _friends,
        attestationToken: _token!,
        batteryTier: _batteryTier,
        // Token expired mid-session: drop back to onboarding, which
        // fetches and (on the fresh ChatScreen) re-presents a new one.
        onTokenExpired: () => setState(() => _token = null),
      );
    }
    return MaterialApp(
      title: 'MeshLink',
      theme: ThemeData(colorSchemeSeed: Colors.indigo),
      home: home,
      routes: {
        // Throwaway plugin PoC, kept reachable for debugging BLE issues.
        '/ble-poc': (_) => BleScanPocScreen(wifiTransport: _transport.wifi),
      },
    );
  }
}
