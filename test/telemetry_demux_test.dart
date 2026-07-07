import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshlink_app/config/wifi_config.dart';
import 'package:meshlink_app/telemetry/phone_ping_responder.dart';
import 'package:meshlink_app/transport/failover_transport.dart';
import 'package:meshlink_app/transport/wifi_transport.dart';

import 'failover_transport_test.dart' show FakeBleTransport;
import 'wifi_transport_test.dart' show FakeNode, FakeWifiJoin;

Uint8List _ping() =>
    Uint8List.fromList([...phonePingMagic, ...utf8.encode('{"t":"ping"}')]);

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
      phonePing: PhonePingResponder(
        reader: () async =>
            const TelemetryReading(lat: 1.0, lon: 2.0, battery: 66),
      ),
    );
  });

  tearDown(() async {
    await transport.stop();
    await node.close();
  });

  test('BLE ping never reaches the pipeline; pong goes back over BLE',
      () async {
    final delivered = <Uint8List>[];
    transport.onReceive((peer, data) => delivered.add(data));
    await transport.start();

    ble.callback!('ble:aa:bb', _ping());
    await _pump();

    expect(delivered, isEmpty); // demuxed away from the mesh path
    expect(ble.sent, hasLength(1));
    expect(ble.sent.single.$1, 'ble:aa:bb');
    expect(utf8.decode(ble.sent.single.$2),
        'MLPP1{"t":"pong","lat":1.0,"lon":2.0,"battery":66}');
  });

  test('WiFi ping never reaches the pipeline; pong goes back over WiFi',
      () async {
    final delivered = <Uint8List>[];
    transport.onReceive((peer, data) => delivered.add(data));
    await transport.start();
    await transport.enableWifi();
    await _pump();

    node.send(_ping());
    await _pump();

    expect(delivered, isEmpty);
    expect(ble.sent, isEmpty); // answered on the transport it arrived on
    expect(utf8.decode(node.received.single),
        'MLPP1{"t":"pong","lat":1.0,"lon":2.0,"battery":66}');
  });

  test('mesh packets still pass through to the pipeline callback', () async {
    final delivered = <Uint8List>[];
    transport.onReceive((peer, data) => delivered.add(data));
    await transport.start();

    final meshPacket = Uint8List(131); // random msg_id start, no MLPP1 magic
    ble.callback!('ble:aa:bb', meshPacket);
    await _pump();

    expect(delivered, hasLength(1));
    expect(ble.sent, isEmpty);
  });
}
