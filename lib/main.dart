import 'dart:async';
import 'dart:io';

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
import 'notifications/notification_service.dart';
import 'onboarding/attestation_flow.dart';
import 'online/online_client.dart';
import 'online/online_service.dart';
import 'onboarding/event_select_screen.dart';
import 'onboarding/event_store.dart';
import 'onboarding/onboarding_screen.dart';
import 'onboarding/wifi_mesh_toggle.dart';
import 'power/battery_tier_manager.dart';
import 'telemetry/phone_ping_responder.dart';
import 'transport/backend_proxy.dart';
import 'transport/ble_transport.dart';
import 'transport/failover_transport.dart';
import 'transport/relay_service.dart';
import 'transport/wifi_transport.dart';
import 'ui/firefly/firefly_home.dart';
import 'ui/firefly/firefly_theme.dart';

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

  // Backend-via-node: every backend client below shares this HTTP client,
  // which tries the internet first and falls back to proxying through the
  // connected mesh node (MLBP1 channel) when the phone has none. The channel
  // binds to the transport when FailoverTransport is built in the app state.
  final backendChannel = NodeBackendChannel();
  final backendClient = MeshBackendClient(channel: backendChannel);

  // Account session (email + password auth), independent of the attestation
  // token and the device keypairs. Restored from secure storage if present;
  // the first gate is login when it isn't.
  final authService = AuthService(
    client: AuthClient(config: BackendConfig.fromEnvironment,
        client: backendClient),
    sessionStorage: SessionStorage(storage),
    identity: identity,
    encryption: encryption,
    tokenStorage: tokenStorage,
  );
  await authService.init();

  // Online mode: the backend push socket + REST relay. Primary transport for
  // friend requests, DMs and location whenever it is up; the mesh takes over
  // seamlessly when it isn't. Started/stopped with the login session.
  final onlineService = OnlineService(
    client: OnlineClient(
      config: BackendConfig.fromEnvironment,
      accessToken: authService.validAccessToken,
      fallbackAvailable: () => backendChannel.available,
      client: backendClient,
    ),
    accessToken: authService.validAccessToken,
    config: BackendConfig.fromEnvironment,
  );

  // Notifications: local banners for messages/requests that arrive over the
  // mesh or the online socket while backgrounded, FCM push for when the app
  // is not running at all. FCM degrades to a no-op until Firebase config
  // files are added (see docs/notifications.md).
  final notifications = NotificationService();
  await notifications.init();

  // The welcome/onboarding intro is shown once, after the first verified
  // login. Persisted so returning users skip it.
  final welcomeSeen = await storage.read(_welcomeSeenKey) == 'true';

  // Which event this install joined. Chosen once on the event-select screen
  // (post-login, pre-attestation — the token is bound to it).
  final eventStore = EventStore(storage);
  final storedEvent = await eventStore.read();

  runApp(MeshLinkApp(
    identity: identity,
    encryption: encryption,
    storage: storage,
    tokenStorage: tokenStorage,
    authService: authService,
    onlineService: onlineService,
    notifications: notifications,
    eventStore: eventStore,
    backendChannel: backendChannel,
    backendClient: backendClient,
    initialToken: validToken,
    initialWelcomeSeen: welcomeSeen,
    initialEvent: storedEvent,
  ));
}

/// Secure-storage key marking that the post-first-login welcome intro ran.
const String _welcomeSeenKey = 'meshlink_welcome_seen_v1';

/// First frame while the friend store loads: the Firefly night gradient and
/// an accent spinner instead of a bare Material scaffold, so launch doesn't
/// flash a white screen before the glass chrome. Pre-login there is no user
/// theme preference yet, so it follows the platform brightness (same rule
/// as the auth screens).
class _BootScreen extends StatelessWidget {
  const _BootScreen();

  @override
  Widget build(BuildContext context) {
    final dark = MediaQuery.platformBrightnessOf(context) == Brightness.dark;
    final c = dark ? FfColors.dark : FfColors.light;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Container(
        decoration: BoxDecoration(gradient: c.bg),
        alignment: Alignment.center,
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(strokeWidth: 2.5, color: c.accent),
        ),
      ),
    );
  }
}

class MeshLinkApp extends StatefulWidget {
  const MeshLinkApp({
    super.key,
    required this.identity,
    required this.encryption,
    required this.storage,
    required this.tokenStorage,
    required this.authService,
    required this.onlineService,
    required this.notifications,
    required this.eventStore,
    required this.backendChannel,
    required this.backendClient,
    this.initialToken,
    this.initialWelcomeSeen = false,
    this.initialEvent,
  });

  final DeviceIdentity identity;
  final EncryptionIdentity encryption;
  final SecureStorage storage;
  final TokenStorage tokenStorage;
  final AuthService authService;
  final OnlineService onlineService;
  final NotificationService notifications;
  final EventStore eventStore;
  final NodeBackendChannel backendChannel;
  final MeshBackendClient backendClient;
  final AttestationToken? initialToken;
  final bool initialWelcomeSeen;
  final EventInfo? initialEvent;

  @override
  State<MeshLinkApp> createState() => _MeshLinkAppState();
}

class _MeshLinkAppState extends State<MeshLinkApp> {
  AttestationToken? _token;

  /// The event this install joined; null until chosen on the event-select
  /// gate. The attestation token is bound to it.
  EventInfo? _event;

  /// Phase 6: BLE always-on with WiFi as an opt-in second transport. Built
  /// once — the WiFi toggle state must survive token refreshes and screen
  /// swaps, and the pipeline sees it as the one Transport it always had.
  /// Late: it binds the backend-via-node channel from the widget.
  late final FailoverTransport _transport = FailoverTransport(
    ble: BleTransport(),
    wifi: WifiTransport(config: WifiConfig.fromEnvironment),
    // Phase 7: answer the node's 2-minute telemetry pings (location +
    // battery) on whichever transport they arrive on.
    phonePing: PhonePingResponder(),
    // Backend-via-node: MLBP1 replies demux to the channel the shared
    // MeshBackendClient falls back to when the internet is unreachable.
    backendProxy: widget.backendChannel,
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
    _token = widget.initialToken;
    _event = widget.initialEvent;
    _wifiOffered = widget.initialToken != null;
    _welcomeSeen = widget.initialWelcomeSeen;
    _batteryTier.tier.addListener(_onTierChanged);
    _batteryTier.start();

    _friends = FriendService(
      store: FriendStore(widget.storage),
      directory: DirectoryClient(config: BackendConfig.fromEnvironment,
          accessToken: widget.authService.validAccessToken,
          client: widget.backendClient),
      identity: widget.identity,
      encryption: widget.encryption,
      transport: _transport,
      pipeline: _pipeline,
      readPosition: _readBeaconPosition,
    );
    // Auth binds the account's username into this FriendService on login.
    widget.authService.attachFriends(_friends);
    widget.authService.addListener(_onAuthChanged);
    // Online mode rides the login session: the push socket authenticates
    // with the account's access token, so it runs exactly while logged in.
    _friends.attachOnline(widget.onlineService);
    // Notifications: banner inbound DMs/requests when backgrounded, and let
    // an FCM wake-up trigger an immediate inbox poll while foregrounded.
    _friends.onDmReceived = (from, text, key) => unawaited(widget.notifications
        .notifyDm(fromUser: from, text: text, dedupKey: key));
    _friends.onFriendRequestReceived =
        (from) => unawaited(widget.notifications.notifyFriendRequest(from));
    widget.notifications.onForegroundPush =
        () => unawaited(widget.onlineService.pollNow());
    _tokenRefreshSub = widget.notifications.onTokenRefresh
        .listen((_) => unawaited(_registerPushToken()));
    _syncOnlineLifecycle();
    unawaited(_friends.init().then((_) {
      if (mounted) setState(() => _friendsReady = true);
    }));
  }

  /// Subscription to FCM token rotation → re-register with the backend.
  StreamSubscription<String>? _tokenRefreshSub;

  /// Whether this login session has registered its FCM token server-side.
  bool _pushRegistered = false;

  Future<void> _registerPushToken() async {
    if (!widget.authService.isLoggedIn) return;
    final token = await widget.notifications.fcmToken();
    if (token == null) return; // Firebase not configured — mesh-only banners
    try {
      await widget.onlineService.client
          .registerPushToken(token, Platform.isIOS ? 'ios' : 'android');
      _pushRegistered = true;
    } on OnlineException {
      // Retried on the next auth/connectivity change; pushes just start late.
      _pushRegistered = false;
    }
  }

  void _onAuthChanged() {
    _syncOnlineLifecycle();
    if (mounted) setState(() {});
  }

  void _syncOnlineLifecycle() {
    if (widget.authService.isLoggedIn) {
      widget.onlineService.start();
      if (!_pushRegistered) unawaited(_registerPushToken());
    } else {
      widget.onlineService.stop();
      if (_pushRegistered) {
        // Logged out: the account session is already gone, so instead of an
        // authenticated unregister, kill the FCM token itself — the backend
        // prunes dead tokens when a push bounces.
        unawaited(widget.notifications.deleteToken());
        _pushRegistered = false;
      }
    }
  }

  Future<void> _markWelcomeSeen() async {
    await widget.storage.write(_welcomeSeenKey, 'true');
    if (mounted) setState(() => _welcomeSeen = true);
  }

  /// Event chosen on the select gate. Any token held so far was fetched for
  /// the previously effective event (the stored one, or the compile-time
  /// default on legacy installs), so switching events invalidates it and
  /// routes back through onboarding for a token bound to the new event.
  Future<void> _selectEvent(EventInfo event) async {
    final previousId =
        _event?.eventId ?? BackendConfig.fromEnvironment.eventId;
    await widget.eventStore.write(event);
    if (event.eventId != previousId) {
      await widget.tokenStorage.clear();
      _token = null;
    }
    if (mounted) setState(() => _event = event);
  }

  /// Position source for the friend-location beacon. Same permission-aware
  /// Geolocator flow as the telemetry pong: null (no beacon) on any denial
  /// or failure, never an error.
  static Future<({double lat, double lon, double accuracyM})?>
      _readBeaconPosition() async {
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return null;
      }
      Position? position;
      if (await Geolocator.isLocationServiceEnabled()) {
        try {
          position = await Geolocator.getCurrentPosition(
            locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.high,
              timeLimit: Duration(seconds: 4),
            ),
          );
        } catch (_) {
          // Fall through to the OS-maintained last fix below.
        }
      }
      position ??= await Geolocator.getLastKnownPosition();
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
    _tokenRefreshSub?.cancel();
    widget.authService.removeListener(_onAuthChanged);
    widget.onlineService.stop();
    _friends.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Widget home;
    if (!_friendsReady) {
      // Friend store still loading from secure storage (fast, one read).
      home = const _BootScreen();
    } else if (!widget.authService.isLoggedIn) {
      // Account gate: login runs first so the device's keypairs bind to the
      // account and yield the username. Login screen routes to signup/forgot.
      home = LoginScreen(auth: widget.authService);
    } else if (_event == null) {
      // Event gate: the attestation token below is bound to an event id, so
      // the choice must land before the fetch.
      home = EventSelectScreen(
        events: EventsClient(config: BackendConfig.fromEnvironment,
            client: widget.backendClient),
        defaultEvent: EventInfo(
          eventId: BackendConfig.fromEnvironment.eventId,
          name: BackendConfig.fromEnvironment.eventId,
        ),
        onSelected: (event) => unawaited(_selectEvent(event)),
      );
    } else if (_token == null) {
      home = OnboardingScreen(
        identity: widget.identity,
        flow: AttestationFlow(
          config: BackendConfig(
            baseUrl: BackendConfig.fromEnvironment.baseUrl,
            eventId: _event!.eventId,
          ),
          client: widget.backendClient,
        ),
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
