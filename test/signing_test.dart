import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshlink_app/core/message_factory.dart';
import 'package:meshlink_app/core/pipeline.dart';
import 'package:meshlink_app/core/test_identity.dart';

/// Send-path round trip with real Ed25519 verification enabled — the
/// software-verifiable half of the Phase 1 demo criteria: a signed message is
/// delivered; a forged (tampered) message and a duplicate are rejected.
void main() {
  final ephemId = Uint8List.fromList(List.filled(16, 0x0f));

  test('signed packet passes the full pipeline with verification on', () async {
    final identity = await TestIdentity.load();
    final pipeline = RelayPipeline();
    final packet = await buildSignedPacket(
      identity: identity,
      ephemId: ephemId,
      payload: utf8.encode('hello over BLE'),
    );

    final result = await pipeline.process(packet);
    expect(result.dropReason, isNull);
    expect(result.outcome, Outcome.deliver);
    expect(utf8.decode(result.message!.payload), 'hello over BLE');
  });

  test('tampered payload is dropped as forged', () async {
    final identity = await TestIdentity.load();
    final pipeline = RelayPipeline();
    final packet = await buildSignedPacket(
      identity: identity,
      ephemId: ephemId,
      payload: utf8.encode('pay Alice 5'),
    );
    packet[80] ^= 0xff; // flip a payload byte after signing

    final result = await pipeline.process(packet);
    expect(result.outcome, Outcome.drop);
    expect(result.dropReason, 'invalid signature');
  });

  test('replayed packet is dropped as duplicate before crypto', () async {
    final identity = await TestIdentity.load();
    final pipeline = RelayPipeline();
    final packet = await buildSignedPacket(
      identity: identity,
      ephemId: ephemId,
      payload: utf8.encode('once only'),
    );

    expect((await pipeline.process(packet)).outcome, Outcome.deliver);
    final replayed = await pipeline.process(packet);
    expect(replayed.outcome, Outcome.drop);
    expect(replayed.dropReason, 'duplicate: msg_id already seen');
  });
}
