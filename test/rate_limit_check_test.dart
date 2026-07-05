import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshlink_app/core/message.dart';
import 'package:meshlink_app/core/rate_limit_check.dart';

Message _msg(int sender) {
  final ephemId = Uint8List(16)..buffer.asByteData().setUint32(0, sender);
  return Message(
    raw: Uint8List(0),
    msgId: Uint8List(16),
    senderKey: Uint8List(32),
    ephemId: ephemId,
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

/// Semantics per PHASE4_CHANGES.md §Pipeline checks: N = 10 per 10 s window;
/// over-limit drops don't consume budget; a pass resets the violation
/// streak; 3 consecutive violations ⇒ 60 s ban; banned drops don't touch
/// the window; streak restarts at zero after a ban expires; a message
/// exactly windowSeconds old still counts inside the window.
void main() {
  test('11th message in the window is dropped, budget not consumed', () {
    var now = 1000;
    final limiter = RateLimiter(clock: () => now);
    for (var i = 0; i < 10; i++) {
      expect(limiter.check(_msg(1)), isNull);
    }
    expect(limiter.check(_msg(1)), contains('rate limited'));
    // The drop consumed no budget: once the original ten age out of the
    // window, capacity is fully back — the drop left no timestamp behind.
    now = 1011;
    expect(limiter.check(_msg(1)), isNull);
  });

  test('message exactly windowSeconds old still counts inside the window', () {
    var now = 1000;
    final limiter = RateLimiter(clock: () => now);
    for (var i = 0; i < 10; i++) {
      expect(limiter.check(_msg(1)), isNull);
    }
    now = 1010; // oldest timestamp is exactly 10 s old — still counted
    expect(limiter.check(_msg(1)), contains('rate limited'));
  });

  test('senders are limited independently', () {
    final limiter = RateLimiter(clock: () => 1000);
    for (var i = 0; i < 10; i++) {
      expect(limiter.check(_msg(1)), isNull);
    }
    expect(limiter.check(_msg(1)), contains('rate limited'));
    expect(limiter.check(_msg(2)), isNull);
  });

  test('3 consecutive violations ban for 60 s; streak resets after expiry',
      () {
    var now = 1000;
    final limiter = RateLimiter(clock: () => now);
    for (var i = 0; i < 10; i++) {
      expect(limiter.check(_msg(1)), isNull);
    }
    expect(limiter.check(_msg(1)), contains('over 10 msgs')); // violation 1
    expect(limiter.check(_msg(1)), contains('over 10 msgs')); // violation 2
    expect(limiter.check(_msg(1)), contains('over 10 msgs')); // violation 3 → ban
    expect(limiter.check(_msg(1)), contains('banned'));

    // Still banned just before expiry, even though the window has drained.
    now = 1059;
    expect(limiter.check(_msg(1)), contains('banned'));

    // Ban expired: streak restarted at zero, window long empty — passes.
    now = 1060;
    expect(limiter.check(_msg(1)), isNull);
  });

  test('a pass resets the consecutive-violation streak', () {
    var now = 1000;
    final limiter = RateLimiter(clock: () => now);
    for (var i = 0; i < 10; i++) {
      expect(limiter.check(_msg(1)), isNull);
    }
    expect(limiter.check(_msg(1)), contains('over 10 msgs')); // violation 1
    expect(limiter.check(_msg(1)), contains('over 10 msgs')); // violation 2

    now = 1011; // window drained — this passes and resets the streak
    expect(limiter.check(_msg(1)), isNull);
    // Refill the window; the two pre-pass violations must NOT count toward
    // the ban, so it takes three fresh ones to trigger it.
    for (var i = 0; i < 9; i++) {
      expect(limiter.check(_msg(1)), isNull);
    }
    expect(limiter.check(_msg(1)), contains('over 10 msgs')); // violation 1
    expect(limiter.check(_msg(1)), contains('over 10 msgs')); // violation 2
    expect(limiter.check(_msg(1)), contains('over 10 msgs')); // violation 3 → ban
    expect(limiter.check(_msg(1)), contains('banned'));
  });
}
