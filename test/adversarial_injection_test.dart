import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshlink_app/core/message_factory.dart';
import 'package:meshlink_app/core/pipeline.dart';
import 'package:meshlink_app/identity/device_identity.dart';

import 'helpers/test_identity.dart';

/// Dart port of meshlink-core/tests/adversarial/inject_attacks.py: injects
/// deliberately invalid packets into a fresh in-process RelayPipeline (the
/// pipeline IS the node's message processing) and asserts each is rejected
/// at the correct, documented pipeline step — not just "rejected somewhere".
/// Every attack pipeline first accepts an honest control message, proving
/// rejections are real and not a broken pipeline dropping everything.
///
/// Replay-vs-duplicate mapping (PHASE4_CHANGES.md §Adversarial): a replay
/// inside the 5-min freshness window is caught at step 4 (dedup); a replay
/// older than 5 min is the stale-timestamp attack at step 3. Benign
/// double-send and attacker re-injection are mechanically identical at
/// step 4.
void main() {
  const fixedNow = 1_700_000_000;
  final ephemId = Uint8List.fromList(List.filled(16, 0xa7));

  late DeviceIdentity attacker;
  late DeviceIdentity honest;

  setUpAll(() async {
    attacker = await testIdentity();
    honest = await testIdentity();
  });

  /// Fresh pipeline that has already accepted one honest control message.
  Future<RelayPipeline> freshPipeline() async {
    final pipeline = RelayPipeline(now: () => fixedNow);
    final control = await buildSignedPacket(
      identity: honest,
      ephemId: ephemId,
      payload: utf8.encode('honest control'),
      timestamp: fixedNow,
    );
    final result = await pipeline.process(control);
    expect(result.outcome, Outcome.deliver,
        reason: 'control message must pass before any attack is meaningful');
    return pipeline;
  }

  test('attack: forged signature → rejected at step 6 (signature)', () async {
    final pipeline = await freshPipeline();
    final packet = await buildSignedPacket(
      identity: attacker,
      ephemId: ephemId,
      payload: utf8.encode('forged'),
      timestamp: fixedNow,
    );
    // Corrupt the signature itself.
    packet[packet.length - 1] ^= 0xff;

    final result = await pipeline.process(packet);
    expect(result.outcome, Outcome.drop);
    expect(result.dropReason, 'invalid signature');
  });

  test('attack: replayed message → rejected at step 4 (dedup)', () async {
    final pipeline = await freshPipeline();
    final packet = await buildSignedPacket(
      identity: attacker,
      ephemId: ephemId,
      payload: utf8.encode('replay me'),
      timestamp: fixedNow,
    );
    expect((await pipeline.process(packet)).outcome, Outcome.deliver);

    // Attacker re-injects the captured packet inside the freshness window.
    final replayed = await pipeline.process(packet);
    expect(replayed.outcome, Outcome.drop);
    expect(replayed.dropReason, 'duplicate: msg_id already seen');
  });

  test('attack: stale timestamp → rejected at step 3 (timestamp)', () async {
    final pipeline = await freshPipeline();
    final packet = await buildSignedPacket(
      identity: attacker,
      ephemId: ephemId,
      payload: utf8.encode('from the past'),
      timestamp: fixedNow - 301, // strictly older than the 5-min window
    );

    final result = await pipeline.process(packet);
    expect(result.outcome, Outcome.drop);
    expect(result.dropReason, startsWith('timestamp too old'));
  });

  test('attack: future timestamp → rejected at step 3 (timestamp)', () async {
    final pipeline = await freshPipeline();
    final packet = await buildSignedPacket(
      identity: attacker,
      ephemId: ephemId,
      payload: utf8.encode('from the future'),
      timestamp: fixedNow + 31, // beyond the 30-s clock-skew tolerance
    );

    final result = await pipeline.process(packet);
    expect(result.outcome, Outcome.drop);
    expect(result.dropReason, startsWith('timestamp too far in future'));
  });

  test('attack: duplicate message (benign double-send) → rejected at step 4',
      () async {
    final pipeline = await freshPipeline();
    final packet = await buildSignedPacket(
      identity: honest,
      ephemId: ephemId,
      payload: utf8.encode('sent twice'),
      timestamp: fixedNow,
    );
    expect((await pipeline.process(packet)).outcome, Outcome.deliver);

    final duplicate = await pipeline.process(packet);
    expect(duplicate.outcome, Outcome.drop);
    expect(duplicate.dropReason, 'duplicate: msg_id already seen');
  });

  test('attack: flood → rejected at step 5 (rate limit) before crypto',
      () async {
    final pipeline = await freshPipeline();
    // Dedicated ephem_id so the honest control message doesn't share the
    // attacker's window; 10 distinct messages fill it exactly.
    final floodEphem = Uint8List.fromList(List.filled(16, 0x66));
    for (var i = 0; i < 10; i++) {
      final packet = await buildSignedPacket(
        identity: attacker,
        ephemId: floodEphem,
        payload: utf8.encode('flood $i'),
        timestamp: fixedNow,
      );
      expect((await pipeline.process(packet)).outcome, Outcome.deliver);
    }
    final over = await buildSignedPacket(
      identity: attacker,
      ephemId: floodEphem,
      payload: utf8.encode('flood 11'),
      timestamp: fixedNow,
    );
    final result = await pipeline.process(over);
    expect(result.outcome, Outcome.drop);
    expect(result.dropReason, contains('rate limited'));
  });
}
