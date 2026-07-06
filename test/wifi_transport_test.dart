import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshlink_app/config/wifi_config.dart';
import 'package:meshlink_app/transport/wifi/wifi_join.dart';
import 'package:meshlink_app/transport/wifi_transport.dart';

/// Fake platform join — records calls, never touches a real radio.
class FakeWifiJoin implements WifiJoin {
  String? joinedSsid;
  String? joinedPassphrase;
  bool left = false;
  void Function()? lostCallback;
  WifiState state = const WifiState();

  @override
  Future<WifiState> currentState() async => state;

  @override
  Future<void> join(String ssid, String passphrase) async {
    joinedSsid = ssid;
    joinedPassphrase = passphrase;
  }

  @override
  Future<void> leave() async {
    left = true;
  }

  @override
  void onLost(void Function() callback) {
    lostCallback = callback;
  }
}

/// Minimal in-process stand-in for the node's WiFi listener
/// (meshlink-node node/transport/wifi_transport.py): accepts one socket,
/// reassembles 2-byte length-prefixed packets, can send framed packets back.
class FakeNode {
  FakeNode(this.server) {
    server.listen((socket) {
      sockets.add(socket);
      final buffer = BytesBuilder();
      socket.listen((chunk) {
        buffer.add(chunk);
        while (true) {
          final bytes = buffer.toBytes();
          if (bytes.length < 2) return;
          final total = ByteData.sublistView(bytes).getUint16(0);
          if (bytes.length < 2 + total) return;
          received.add(Uint8List.sublistView(bytes, 2, 2 + total));
          buffer
            ..clear()
            ..add(Uint8List.sublistView(bytes, 2 + total));
        }
      });
    });
  }

  static Future<FakeNode> start() async =>
      FakeNode(await ServerSocket.bind('127.0.0.1', 0));

  final ServerSocket server;
  final List<Socket> sockets = [];
  final List<Uint8List> received = [];

  int get port => server.port;

  void send(List<int> packet) {
    final framed = Uint8List(2 + packet.length);
    ByteData.sublistView(framed).setUint16(0, packet.length);
    framed.setRange(2, framed.length, packet);
    sockets.last.add(framed);
  }

  Future<void> close() async {
    for (final s in sockets) {
      s.destroy();
    }
    await server.close();
  }
}

Future<void> _pump() => Future<void>.delayed(const Duration(milliseconds: 50));

void main() {
  late FakeNode node;
  late FakeWifiJoin join;
  late WifiTransport transport;

  setUp(() async {
    node = await FakeNode.start();
    join = FakeWifiJoin();
    transport = WifiTransport(
      config: WifiConfig(
        ssid: 'MeshLink-Test',
        passphrase: 'test-passphrase',
        nodeHost: '127.0.0.1',
        nodePort: node.port,
      ),
      join: join,
      reconnectDelay: const Duration(milliseconds: 50),
    );
  });

  tearDown(() async {
    await transport.stop();
    await node.close();
  });

  test('start joins the configured SSID and connects to the node', () async {
    await transport.start();
    await _pump();
    expect(join.joinedSsid, 'MeshLink-Test');
    expect(join.joinedPassphrase, 'test-passphrase');
    expect(transport.connected, isTrue);
    expect(transport.listPeers(), ['wifi:127.0.0.1:${node.port}']);
  });

  test('send frames packets with the 2-byte length prefix', () async {
    await transport.start();
    await _pump();
    await transport.send(
        transport.listPeers().single, Uint8List.fromList([1, 2, 3, 4]));
    await _pump();
    expect(node.received.single, [1, 2, 3, 4]);
  });

  test('receives framed packets from the node, including split chunks',
      () async {
    final received = <(String, Uint8List)>[];
    transport.onReceive((peer, data) => received.add((peer, data)));
    await transport.start();
    await _pump();

    node.send([9, 8, 7]);
    // Two packets in one TCP write must both come out.
    node.send([1, 1]);
    node.send([2, 2]);
    await _pump();

    expect(received.map((r) => r.$2).toList(), [
      [9, 8, 7],
      [1, 1],
      [2, 2],
    ]);
    expect(received.first.$1, 'wifi:127.0.0.1:${node.port}');
  });

  test('reconnects after the node drops the connection', () async {
    await transport.start();
    await _pump();
    node.sockets.single.destroy();
    await _pump();
    expect(transport.connected, isFalse);
    expect(transport.listPeers(), isEmpty);

    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(transport.connected, isTrue);
    expect(node.sockets, hasLength(2));
  });

  test('OS network-lost callback tears down and later reconnects', () async {
    await transport.start();
    await _pump();
    join.lostCallback!();
    expect(transport.connected, isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(transport.connected, isTrue);
  });

  test('stop leaves the network and stops reconnecting', () async {
    await transport.start();
    await _pump();
    await transport.stop();
    expect(join.left, isTrue);
    expect(transport.connected, isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(node.sockets, hasLength(1)); // no reconnect after stop
  });

  test('send to an unknown peer throws like BleTransport', () async {
    await transport.start();
    await _pump();
    expect(
      () => transport.send('wifi:10.0.0.9:1', Uint8List(1)),
      throwsStateError,
    );
  });
}
