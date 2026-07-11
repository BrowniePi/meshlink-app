import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshlink_app/auth/auth_chrome.dart';
import 'package:meshlink_app/config/wifi_config.dart';
import 'package:meshlink_app/onboarding/wifi_mesh_toggle.dart';
import 'package:meshlink_app/transport/failover_transport.dart';
import 'package:meshlink_app/transport/wifi/wifi_join.dart';
import 'package:meshlink_app/transport/wifi_transport.dart';
import 'package:meshlink_app/ui/widgets/mesh_status_indicator.dart';

import 'failover_transport_test.dart' show FakeBleTransport;
import 'wifi_transport_test.dart' show FakeNode, FakeWifiJoin;

void main() {
  late FakeNode node;
  late FakeWifiJoin join;
  late FailoverTransport transport;

  setUp(() async {
    node = await FakeNode.start();
    join = FakeWifiJoin();
    transport = FailoverTransport(
      ble: FakeBleTransport(),
      wifi: WifiTransport(
        config: WifiConfig(
          ssid: 'MeshLink-Test',
          passphrase: 'test-passphrase',
          nodeHost: '127.0.0.1',
          nodePort: node.port,
        ),
        join: join,
      ),
    );
  });

  tearDown(() async {
    await transport.stop();
    await node.close();
  });

  Future<void> pumpToggle(WidgetTester tester, {VoidCallback? onDone}) async {
    await tester.pumpWidget(MaterialApp(
      home: WifiMeshToggleScreen(
        transport: transport,
        onDone: onDone ?? () {},
      ),
    ));
  }

  testWidgets('frames WiFi as opt-in, off by default, with a skip path',
      (tester) async {
    var done = false;
    await pumpToggle(tester, onDone: () => done = true);

    expect(find.textContaining('Connect to venue mesh network'), findsOneWidget);
    expect(transport.wifiEnabled.value, isFalse);

    await tester.tap(find.text('Not now'));
    expect(done, isTrue);
    expect(transport.wifiEnabled.value, isFalse); // skip = BLE-only
  });

  testWidgets('warning names the network the phone is already on',
      (tester) async {
    join.state = const WifiState(currentSsid: 'HomeNetwork-5G');
    await pumpToggle(tester);

    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();

    expect(find.textContaining('"HomeNetwork-5G"'), findsOneWidget);
    expect(find.textContaining('disconnect you from it'), findsOneWidget);
    expect(find.textContaining('no internet access'), findsWidgets);
  });

  testWidgets('active WiFi Calling escalates to the call-specific warning',
      (tester) async {
    join.state = const WifiState(
        currentSsid: 'HomeNetwork-5G', wifiCallingActive: true);
    await pumpToggle(tester);

    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();

    expect(find.textContaining('WiFi Calling'), findsOneWidget);
    expect(find.textContaining('unreachable for'), findsOneWidget);
    expect(find.text('Connect anyway'), findsOneWidget);
  });

  testWidgets('confirming the dialog enables the mesh and completes the step',
      (tester) async {
    var done = false;
    await pumpToggle(tester, onDone: () => done = true);

    // The whole flow runs inside runAsync: the enable chain is created by
    // the first tap, and it must live in a real-async zone so the
    // transport's socket connect (and its timeout timer) completes against
    // the fake node instead of leaking past the fake-async test zone.
    await tester.runAsync(() async {
      await tester.tap(find.text('Connect'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(AuthButton, 'Connect').last);
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();

    expect(join.joinedSsid, 'MeshLink-Test');
    expect(transport.wifiEnabled.value, isTrue);
    expect(done, isTrue);
  });

  testWidgets('cancelling the dialog leaves WiFi off', (tester) async {
    await pumpToggle(tester);

    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Not now').last);
    await tester.pumpAndSettle();

    expect(join.joinedSsid, isNull);
    expect(transport.wifiEnabled.value, isFalse);
  });

  testWidgets('indicator appears while mesh is on and disappears when off',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MeshStatusIndicator(wifiEnabled: transport.wifiEnabled),
      ),
    ));
    expect(find.textContaining('No Internet (by design)'), findsNothing);

    transport.wifiEnabled.value = true;
    await tester.pump();
    expect(find.textContaining('Mesh Network Active'), findsOneWidget);
    expect(find.textContaining('No Internet (by design)'), findsOneWidget);

    transport.wifiEnabled.value = false;
    await tester.pump();
    expect(find.textContaining('No Internet (by design)'), findsNothing);
  });
}
