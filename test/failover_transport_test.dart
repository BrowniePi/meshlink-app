import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshlink_app/config/wifi_config.dart';
import 'package:meshlink_app/transport/failover_transport.dart';
import 'package:meshlink_app/transport/transport.dart';
import 'package:meshlink_app/transport/wifi_transport.dart';

import 'wifi_transport_test.dart' show FakeNode, FakeWifiJoin;

/// In-memory BLE stand-in with a controllable peer list.
class FakeBleTransport implements Transport {
  bool started = false;
  final List<String> peers = ['ble:aa:bb'];
  final List<(String, Uint8List)> sent = [];
  ReceiveCallback? callback;

  @override
  Future<void> start() async => started = true;

  @override
  Future<void> stop() async => started = false;

  @override
  Future<void> send(String peerId, Uint8List data) async =>
      sent.add((peerId, data));

  @override
  void onReceive(ReceiveCallback cb) => callback = cb;

  @override
  List<String> listPeers() => peers;
}

Future<void> _pump() => Future<void>.delayed(const Duration(milliseconds: 50));

void main() {
  late FakeNode node;
  late FakeBleTransport ble;
  late FailoverTransport transport;

  setUp(() async {
    node = await FakeNode.start();
    ble = FakeBleTransport();
    transport = FailoverTransport(
      ble: ble,
      wifi: WifiTransport(
        config: WifiConfig(
          ssid: 'MeshLink-Test',
          passphrase: 'test-passphrase',
          nodeHost: '127.0.0.1',
          nodePort: node.port,
        ),
        join: FakeWifiJoin(),
        reconnectDelay: const Duration(milliseconds: 50),
      ),
    );
  });

  tearDown(() async {
    await transport.stop();
    await node.close();
  });

  test('start starts BLE only; WiFi stays off until the toggle', () async {
    await transport.start();
    expect(ble.started, isTrue);
    expect(transport.wifiEnabled.value, isFalse);
    expect(transport.listPeers(), ['ble:aa:bb']);
    expect(node.sockets, isEmpty);
  });

  test('enableWifi prefers the WiFi node; disableWifi falls back to BLE',
      () async {
    await transport.start();
    await transport.enableWifi();
    await _pump();
    expect(transport.wifiEnabled.value, isTrue);
    expect(transport.listPeers(), ['wifi:127.0.0.1:${node.port}']);

    await transport.disableWifi();
    expect(transport.wifiEnabled.value, isFalse);
    expect(transport.listPeers(), ['ble:aa:bb']);
    expect(ble.started, isTrue); // BLE never stopped underneath
  });

  test('WiFi enabled but node connection down falls back to BLE peers',
      () async {
    await transport.start();
    await transport.enableWifi();
    await _pump();
    node.sockets.single.destroy();
    await _pump();
    expect(transport.listPeers(), ['ble:aa:bb']);
  });

  test('send routes by peer id regardless of preference', () async {
    await transport.start();
    await transport.enableWifi();
    await _pump();

    // In-flight BLE sends still work while WiFi is preferred.
    await transport.send('ble:aa:bb', Uint8List.fromList([5]));
    expect(ble.sent.single.$1, 'ble:aa:bb');

    await transport.send(
        'wifi:127.0.0.1:${node.port}', Uint8List.fromList([6]));
    await _pump();
    expect(node.received.single, [6]);
  });

  test('receives are accepted from both transports', () async {
    final received = <String>[];
    transport.onReceive((peer, data) => received.add(peer));
    await transport.start();
    await transport.enableWifi();
    await _pump();

    ble.callback!('ble:aa:bb', Uint8List.fromList([1]));
    node.send([2]);
    await _pump();
    expect(received, hasLength(2));
  });
}
