import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshlink_app/core/dedup_check.dart';
import 'package:meshlink_app/core/message.dart';

Message _msg(int n) {
  final msgId = Uint8List(16)
    ..buffer.asByteData().setUint32(0, n)
    ..[15] = 0xd5;
  return Message(
    raw: Uint8List(0),
    msgId: msgId,
    senderKey: Uint8List(32),
    ephemId: Uint8List(16),
    timestamp: 0,
    ttl: 5,
    sprayL: 8,
    zoneId: 3,
    msgType: 1,
    payloadLen: 0,
    payload: Uint8List(0),
    signature: Uint8List(64),
  );
}

void main() {
  test('first sighting passes, second is a duplicate', () {
    final cache = DedupCache(clock: () => 1000);
    expect(cache.check(_msg(1)), isNull);
    expect(cache.check(_msg(1)), 'duplicate: msg_id already seen');
    expect(cache.check(_msg(2)), isNull);
  });

  test('entry exactly at the 10-min TTL is still a duplicate', () {
    var now = 1000;
    final cache = DedupCache(clock: () => now);
    expect(cache.check(_msg(1)), isNull);
    now = 1000 + 600; // age == TTL: not yet evicted (evict strictly > TTL)
    expect(cache.check(_msg(1)), 'duplicate: msg_id already seen');
  });

  test('bloom rebuild clears expired entries once evictions accumulate', () {
    var now = 0;
    // Small cache: capacity 100 → rebuild threshold 10. errorRate tiny so
    // tiny-filter false positives can't flake the test.
    final cache =
        DedupCache(capacity: 100, errorRate: 1e-9, clock: () => now);
    for (var i = 0; i < 11; i++) {
      expect(cache.check(_msg(i)), isNull);
    }
    // Age all 11 past the TTL; the next check evicts them (11 ≥ threshold)
    // and rebuilds the bloom, so a re-send is accepted as new again.
    now = 601;
    expect(cache.check(_msg(999)), isNull);
    expect(cache.check(_msg(0)), isNull,
        reason: 'expired entry cleared from bloom after rebuild');
  });

  test('LRU capacity bound evicts the oldest entries', () {
    // errorRate tiny so tiny-filter false positives can't flake the test —
    // production keeps the spec'd 1%.
    var now = 0;
    final cache =
        DedupCache(capacity: 50, errorRate: 1e-9, clock: () => now);
    for (var i = 0; i < 56; i++) {
      now = i; // keep everything inside the TTL
      expect(cache.check(_msg(i)), isNull);
    }
    // 6 overflow evictions ≥ rebuild threshold (50 ~/ 10 = 5), so the bloom
    // was rebuilt from live entries: the oldest evicted id is accepted as
    // new again, while a live one is still a duplicate.
    expect(cache.check(_msg(55)), 'duplicate: msg_id already seen',
        reason: 'live entry still deduped');
    expect(cache.check(_msg(0)), isNull,
        reason: 'capacity-evicted entry cleared from bloom after rebuild');
  });
}
