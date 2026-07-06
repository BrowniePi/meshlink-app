import 'package:flutter/material.dart';

import 'ble_poc/ble_scan_poc_screen.dart';
import 'config/backend_config.dart';
import 'core/pipeline.dart';
import 'identity/device_identity.dart';
import 'identity/secure_storage.dart';
import 'identity/token_storage.dart';
import 'onboarding/attestation_flow.dart';
import 'onboarding/onboarding_screen.dart';
import 'transport/ble_transport.dart';
import 'transport/relay_service.dart';
import 'ui/chat_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Android: keep the BLE relay alive across backgrounding (no-op on iOS).
  RelayService.start();

  final storage = SecureStorage();
  // Real per-device identity (Phase 4): generated once on first launch,
  // private seed held in Keychain/Keystore via the secure-storage bridge.
  final identity = await DeviceIdentity.loadOrGenerate(storage);
  // Phase 5: an attestation token gates relaying. Reuse any still-valid token
  // from a previous launch; onboarding fetches one otherwise.
  final tokenStorage = TokenStorage(storage);
  final stored = await tokenStorage.read();
  final validToken =
      (stored != null && !stored.isExpiredAt(DateTime.now())) ? stored : null;

  runApp(MeshLinkApp(
    identity: identity,
    tokenStorage: tokenStorage,
    initialToken: validToken,
  ));
}

class MeshLinkApp extends StatefulWidget {
  const MeshLinkApp({
    super.key,
    required this.identity,
    required this.tokenStorage,
    this.initialToken,
  });

  final DeviceIdentity identity;
  final TokenStorage tokenStorage;
  final AttestationToken? initialToken;

  @override
  State<MeshLinkApp> createState() => _MeshLinkAppState();
}

class _MeshLinkAppState extends State<MeshLinkApp> {
  AttestationToken? _token;

  @override
  void initState() {
    super.initState();
    _token = widget.initialToken;
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MeshLink',
      theme: ThemeData(colorSchemeSeed: Colors.indigo),
      home: _token == null
          ? OnboardingScreen(
              identity: widget.identity,
              flow: AttestationFlow(config: BackendConfig.fromEnvironment),
              tokenStorage: widget.tokenStorage,
              onComplete: (token) => setState(() => _token = token),
            )
          : ChatScreen(
              transport: BleTransport(),
              pipeline: RelayPipeline(),
              identity: widget.identity,
              attestationToken: _token!,
              // Token expired mid-session: drop back to onboarding, which
              // fetches and (on the fresh ChatScreen) re-presents a new one.
              onTokenExpired: () => setState(() => _token = null),
            ),
      routes: {
        // Throwaway plugin PoC, kept reachable for debugging BLE issues.
        '/ble-poc': (_) => const BleScanPocScreen(),
      },
    );
  }
}
