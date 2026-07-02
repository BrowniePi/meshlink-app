import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshlink_app/core/message_factory.dart';
import 'package:meshlink_app/core/pipeline.dart';
import 'package:meshlink_app/core/test_identity.dart';
import 'package:meshlink_app/transport/transport.dart';
import 'package:meshlink_app/ui/chat_screen.dart';

/// In-memory transport double: records sends, lets tests inject received
/// packets, and proves the UI works against the Transport contract alone.
class FakeTransport implements Transport {
  final List<(String, Uint8List)> sent = [];
  ReceiveCallback? _callback;
  List<String> peers = ['fake-peer'];

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> send(String peerId, Uint8List data) async {
    sent.add((peerId, data));
  }

  @override
  void onReceive(ReceiveCallback callback) => _callback = callback;

  @override
  List<String> listPeers() => peers;

  void receive(String peerId, Uint8List data) => _callback!(peerId, data);
}

void main() {
  late TestIdentity identity;

  setUpAll(() async {
    identity = await TestIdentity.load();
  });

  Widget app(FakeTransport transport) => MaterialApp(
        home: ChatScreen(
          transport: transport,
          pipeline: RelayPipeline(),
          identity: identity,
        ),
      );

  testWidgets('sending a message signs it, sends to peers, and displays it',
      (tester) async {
    final transport = FakeTransport();
    await tester.pumpWidget(app(transport));

    await tester.enterText(find.byType(TextField), 'hello mesh');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();

    expect(find.text('hello mesh'), findsOneWidget);
    expect(transport.sent, hasLength(1));
    // What went on the wire passes a fresh pipeline with signature checks on.
    final onWire = transport.sent.single.$2;
    final result = await RelayPipeline().process(onWire);
    expect(result.outcome, Outcome.deliver);
    expect(utf8.decode(result.message!.payload), 'hello mesh');
  });

  testWidgets('received packet passes the pipeline and appears in the list',
      (tester) async {
    final transport = FakeTransport();
    await tester.pumpWidget(app(transport));

    final packet = await buildSignedPacket(
      identity: identity,
      ephemId: Uint8List.fromList(List.filled(16, 7)),
      payload: utf8.encode('incoming!'),
    );
    transport.receive('fake-peer', packet);
    await tester.pumpAndSettle();

    expect(find.text('incoming!'), findsOneWidget);
  });

  testWidgets('tampered packet is rejected, not displayed', (tester) async {
    final transport = FakeTransport();
    await tester.pumpWidget(app(transport));

    final packet = await buildSignedPacket(
      identity: identity,
      ephemId: Uint8List.fromList(List.filled(16, 7)),
      payload: utf8.encode('forged'),
    );
    packet[80] ^= 0xff;
    transport.receive('fake-peer', packet);
    await tester.pumpAndSettle();

    expect(find.text('forged'), findsNothing);
    expect(find.textContaining('invalid signature'), findsOneWidget);
  });

  testWidgets('empty input does nothing', (tester) async {
    final transport = FakeTransport();
    await tester.pumpWidget(app(transport));

    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();

    expect(transport.sent, isEmpty);
  });
}
