import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshlink_app/core/message.dart';
import 'package:meshlink_app/core/message_factory.dart';
import 'package:meshlink_app/core/pipeline.dart';
import 'package:meshlink_app/core/spray_and_wait.dart';

import 'helpers/test_identity.dart';

/// Step 8 relay — Dart mirror of meshlink-core tests/test_pipeline_relay.py.
/// An accepted packet is delivered locally AND (budget permitting) yields a
/// `forward` packet with ttl-1 and spray_L binary-split to the peer's share.
void main() {
  final ephemId = Uint8List.fromList(List.filled(16, 0x0f));

  Future<Uint8List> packet({int ttl = 5, int sprayL = 8}) async =>
      buildSignedPacket(
        identity: await testIdentity(),
        ephemId: ephemId,
        payload: utf8.encode('onward'),
        ttl: ttl,
        sprayL: sprayL,
      );

  test('accepted packet yields a forward copy with ttl-1, spray_L split',
      () async {
    final result = await RelayPipeline().process(await packet());
    expect(result.outcome, Outcome.deliver);
    final forwarded = parsePacket(result.forward!);
    expect(forwarded.ttl, 4);
    expect(forwarded.sprayL, 4); // peer gets floor(8/2)
  });

  test('odd spray_L: peer gets floor half', () async {
    final result = await RelayPipeline().process(await packet(sprayL: 5));
    expect(parsePacket(result.forward!).sprayL, 2);
  });

  test('forward copy still carries a valid origin signature', () async {
    // Fresh pipeline = fresh dedup: the onward copy must pass end-to-end.
    final result = await RelayPipeline().process(await packet());
    final relayed = await RelayPipeline().process(result.forward!);
    expect(relayed.dropReason, isNull);
    expect(relayed.outcome, Outcome.deliver);
  });

  test('wait phase (spray_L=1) stops forwarding but still delivers',
      () async {
    final result = await RelayPipeline().process(await packet(sprayL: 1));
    expect(result.outcome, Outcome.deliver);
    expect(result.forward, isNull);
  });

  test('ttl=1 stops forwarding — the onward copy would arrive dead',
      () async {
    final result = await RelayPipeline().process(await packet(ttl: 1));
    expect(result.outcome, Outcome.deliver);
    expect(result.forward, isNull);
  });

  test('payload and header otherwise untouched', () async {
    final raw = await packet();
    final result = await RelayPipeline().process(raw);
    final original = parsePacket(raw);
    final forwarded = parsePacket(result.forward!);
    expect(forwarded.msgId, original.msgId);
    expect(forwarded.zoneId, original.zoneId);
    expect(forwarded.payload, original.payload);
    expect(forwarded.signature, original.signature);
  });

  test('inflated spray_L re-send is dropped by the budget tracker', () {
    // Unit-level: the pipeline's dedup normally masks re-sends; the tracker
    // backstops dedup eviction (mirrors core SprayBudgetTracker tests).
    final tracker = SprayBudgetTracker();
    final msgId = List.filled(16, 1);
    expect(tracker.check(msgId, 8), isNull);
    expect(tracker.check(msgId, 4), isNull);
    expect(tracker.check(msgId, 16), contains('inflated'));
  });

  test('binary split matches the Python reference table', () {
    expect(splitCopies(8).forward, 4);
    expect(splitCopies(8).keep, 4);
    expect(splitCopies(5).forward, 2);
    expect(splitCopies(5).keep, 3);
    expect(splitCopies(1).forward, 0);
    expect(splitCopies(1).keep, 1);
    expect(splitCopies(0).forward, 0);
    expect(isWaitPhase(1), isTrue);
    expect(isWaitPhase(2), isFalse);
  });
}
