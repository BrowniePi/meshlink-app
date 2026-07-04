import 'package:flutter/material.dart';

import 'ble_poc/ble_scan_poc_screen.dart';
import 'core/pipeline.dart';
import 'identity/device_identity.dart';
import 'identity/secure_storage.dart';
import 'transport/ble_transport.dart';
import 'transport/relay_service.dart';
import 'ui/chat_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Android: keep the BLE relay alive across backgrounding (no-op on iOS).
  RelayService.start();
  // Real per-device identity (Phase 4): generated once on first launch,
  // private seed held in Keychain/Keystore via the secure-storage bridge.
  final identity = await DeviceIdentity.loadOrGenerate(SecureStorage());
  runApp(MeshLinkApp(identity: identity));
}

class MeshLinkApp extends StatelessWidget {
  const MeshLinkApp({super.key, required this.identity});

  final DeviceIdentity identity;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MeshLink',
      theme: ThemeData(colorSchemeSeed: Colors.indigo),
      home: ChatScreen(
        transport: BleTransport(),
        pipeline: RelayPipeline(),
        identity: identity,
      ),
      routes: {
        // Throwaway plugin PoC, kept reachable for debugging BLE issues.
        '/ble-poc': (_) => const BleScanPocScreen(),
      },
    );
  }
}
