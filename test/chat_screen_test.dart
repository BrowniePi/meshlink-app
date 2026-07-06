import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshlink_app/core/message.dart';
import 'package:meshlink_app/core/message_factory.dart';
import 'package:meshlink_app/core/pipeline.dart';
import 'package:meshlink_app/debug/debug_log.dart';
import 'package:meshlink_app/identity/device_identity.dart';
import 'package:meshlink_app/transport/transport.dart';
import 'package:meshlink_app/ui/chat_screen.dart';

import 'helpers/test_identity.dart';

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
  late DeviceIdentity identity;

  setUpAll(() async {
    identity = await testIdentity();
  });

  Widget app(FakeTransport transport) => MaterialApp(
        home: ChatScreen(
          transport: transport,
          pipeline: RelayPipeline(),
          identity: identity,
          attestationToken: 'test.jwt.token',
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
    // Two packets on the wire: the attestation token is presented to the peer
    // first (Phase 5), then the chat message.
    expect(transport.sent, hasLength(2));
    final presented = await RelayPipeline().process(transport.sent.first.$2);
    expect(presented.message!.msgType, msgTypeAttestation);
    expect(utf8.decode(presented.message!.payload), 'test.jwt.token');

    // The chat message passes a fresh pipeline with signature checks on.
    final onWire = transport.sent.last.$2;
    final result = await RelayPipeline().process(onWire);
    expect(result.outcome, Outcome.deliver);
    expect(result.message!.msgType, msgTypeText);
    expect(utf8.decode(result.message!.payload), 'hello mesh');
    // Sent to the broadcast zone so a node relays it to every other node and
    // its local cell — both directions relay, not just away from zone owner.
    expect(result.message!.zoneId, broadcastZone);
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

  testWidgets(
      'receiving a forged packet logs the rejection to DebugLog for the '
      'BLE-log screen', (tester) async {
    DebugLog.instance.clear();
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

    final logged = DebugLog.instance.entries
        .where((e) => e.tag == 'pipeline' && e.message.contains('DROPPED'));
    expect(logged, isNotEmpty,
        reason: 'the receiving node must log its own rejection verdict');
    expect(logged.single.message, contains('invalid signature'));
  });

  testWidgets('empty input does nothing', (tester) async {
    final transport = FakeTransport();
    await tester.pumpWidget(app(transport));

    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();

    expect(transport.sent, isEmpty);
  });

  testWidgets('test menu sends a normal message', (tester) async {
    final transport = FakeTransport();
    await tester.pumpWidget(app(transport));

    await tester.tap(find.byIcon(Icons.science_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Send a normal message'));
    await tester.pumpAndSettle();

    // Attestation presentation first, then the chat message.
    expect(transport.sent, hasLength(2));
    final chat = await RelayPipeline().process(transport.sent.last.$2);
    expect(chat.message!.msgType, msgTypeText);
    expect(find.text('Test message #1'), findsOneWidget);
  });

  testWidgets(
      'forged-signature attack is transmitted raw — this device never '
      'checks it locally', (tester) async {
    final transport = FakeTransport();
    await tester.pumpWidget(app(transport));

    await tester.tap(find.byIcon(Icons.science_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Forged signature'));
    await tester.pumpAndSettle();

    // The whole point: the forged packet must actually reach the wire.
    // If this device's own pipeline had filtered it, nothing would be sent.
    expect(transport.sent, hasLength(1));
    final onWire = transport.sent.single.$2;

    // Only a receiving node's pipeline determines the outcome — simulate
    // that node here and confirm it's the one rejecting the forgery.
    final result = await RelayPipeline().process(onWire);
    expect(result.outcome, Outcome.drop);
    expect(result.dropReason, 'invalid signature');

    expect(find.text('Attack: Forged signature'), findsOneWidget);
    expect(find.textContaining('bypassing'), findsWidgets);
  });

  testWidgets('flood attack transmits all 11 packets raw to the peer',
      (tester) async {
    final transport = FakeTransport();
    await tester.pumpWidget(app(transport));

    await tester.tap(find.byIcon(Icons.science_outlined));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Flood (rate limit)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Flood (rate limit)'));
    await tester.pumpAndSettle();

    // This device must not run its own rate limiter over the flood — all
    // 11 packets go out; the target's limiter is what should trip.
    expect(transport.sent, hasLength(11));
  });

  testWidgets(
      'unattested-sender attack uses a fresh identity, not the device\'s own',
      (tester) async {
    final transport = FakeTransport();
    await tester.pumpWidget(app(transport));

    await tester.tap(find.byIcon(Icons.science_outlined));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Unattested sender'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Unattested sender'));
    await tester.pumpAndSettle();

    expect(transport.sent, hasLength(1));
    // Otherwise perfectly valid — passes every check this device's pipeline
    // can enforce locally (attestation is a node-side, Phase 5 check this
    // app's own pipeline still stubs).
    final result = await RelayPipeline().process(transport.sent.single.$2);
    expect(result.outcome, Outcome.deliver);
    // The whole point: sender_key must NOT be this device's real identity,
    // or the message would already be attested via the normal chat flow.
    expect(result.message!.senderKey, isNot(equals(identity.publicKey)));

    expect(find.text('Attack: Unattested sender'), findsOneWidget);
  });

  testWidgets('attack with no peers connected sends nothing and warns',
      (tester) async {
    final transport = FakeTransport()..peers = [];
    await tester.pumpWidget(app(transport));

    await tester.tap(find.byIcon(Icons.science_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Forged signature'));
    await tester.pumpAndSettle();

    expect(transport.sent, isEmpty);
    expect(find.textContaining('No peers connected'), findsOneWidget);
  });

  testWidgets('long-pressing a message opens the packet info sheet',
      (tester) async {
    final transport = FakeTransport();
    await tester.pumpWidget(app(transport));

    await tester.enterText(find.byType(TextField), 'inspect me');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('inspect me'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Packet info'));
    await tester.pumpAndSettle();

    expect(find.text('Packet details'), findsOneWidget);
    expect(find.text('sender_key'), findsOneWidget);
    expect(find.text('signature'), findsOneWidget);
  });
}
