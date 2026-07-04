import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshlink_app/core/message_factory.dart';
import 'package:meshlink_app/core/pipeline.dart';

import 'helpers/test_identity.dart';

/// Send-path round trip with real Ed25519 verification enabled: a signed
/// message is delivered; a forged (tampered) message and a duplicate are
/// rejected; a relay's ttl/spray_L rewrite does NOT invalidate the origin
/// signature (the Phase 4 signed region excludes those two bytes).
void main() {
  final ephemId = Uint8List.fromList(List.filled(16, 0x0f));

  test('signed packet passes the full pipeline with verification on', () async {
    final identity = await testIdentity();
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
    final identity = await testIdentity();
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
    final identity = await testIdentity();
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

  test('relay ttl/spray_L rewrite keeps the origin signature valid', () async {
    // The multi-hop case that motivated excluding offsets 68–69 from the
    // signed region: a relay decrements ttl and splits spray_L but cannot
    // re-sign; verification at hop 2+ must still succeed.
    final identity = await testIdentity();
    final pipeline = RelayPipeline();
    final packet = await buildSignedPacket(
      identity: identity,
      ephemId: ephemId,
      payload: utf8.encode('via relay'),
      ttl: 5,
      sprayL: 8,
    );
    packet[68] = 4; // ttl decremented by relay hop
    packet[69] = 4; // spray_L binary-split by relay hop

    final result = await pipeline.process(packet);
    expect(result.dropReason, isNull);
    expect(result.outcome, Outcome.deliver);
  });

  test('packet signed by a different keypair than sender_key is rejected',
      () async {
    final claimed = await testIdentity();
    final actualSigner = await testIdentity();
    final pipeline = RelayPipeline();
    // Build honestly with the signer, then swap in the claimed sender_key —
    // the signature no longer matches the key the packet claims.
    final packet = await buildSignedPacket(
      identity: actualSigner,
      ephemId: ephemId,
      payload: utf8.encode('impersonation'),
    );
    packet.setRange(16, 48, claimed.publicKey);

    final result = await pipeline.process(packet);
    expect(result.outcome, Outcome.drop);
    expect(result.dropReason, 'invalid signature');
  });
}
