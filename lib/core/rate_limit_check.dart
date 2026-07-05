import 'dart:collection';

import 'message.dart';

int _wallClockSeconds() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

class _SenderState {
  final Queue<int> timestamps = Queue<int>(); // oldest first
  int consecutiveViolations = 0;
  int? bannedUntil; // unix seconds; null = not banned
  int lastSeen = 0;
}

/// Step 5: per-sender sliding-window rate limit, keyed on ephem_id (the
/// long-term key must not be used here per the security model). Phase 4 port
/// of meshlink-core/pipeline/rate_limit_check.py.
///
/// Semantics (PHASE4_CHANGES.md §Pipeline checks, confirmed 2026-07-04):
/// N = 10 messages per 10 s window; over-limit messages are dropped and do
/// NOT consume window budget; a message that passes resets the
/// consecutive-violation streak; 3 violations in a row ⇒ 60 s ban; while
/// banned, messages are dropped without touching the window; the streak
/// restarts at zero after a ban expires. Boundary: a message exactly
/// windowSeconds old still counts inside the window (evict when age
/// strictly > window).
///
/// Runs before signature verification (step 6) so a flood attacker cannot
/// force Ed25519 work before being throttled. [clock] is injectable for
/// tests. Per-sender state is pruned opportunistically (every 1,000 checks,
/// drop senders idle > 10 min and not banned) so the map can't grow
/// unbounded at event scale.
class RateLimiter {
  RateLimiter({
    this.maxMessages = 10,
    this.windowSeconds = 10,
    this.banAfterViolations = 3,
    this.banSeconds = 60,
    int Function()? clock,
  }) : _clock = clock ?? _wallClockSeconds;

  final int maxMessages;
  final int windowSeconds;
  final int banAfterViolations;
  final int banSeconds;
  final int Function() _clock;

  static const int _pruneEveryChecks = 1000;
  static const int _idleSeconds = 600;

  final Map<String, _SenderState> _senders = {};
  int _checks = 0;

  String? check(Message msg) {
    final now = _clock();
    _checks++;
    if (_checks % _pruneEveryChecks == 0) {
      _prune(now);
    }

    final key = _hex(msg.ephemId);
    final state = _senders.putIfAbsent(key, _SenderState.new);
    state.lastSeen = now;

    final bannedUntil = state.bannedUntil;
    if (bannedUntil != null) {
      if (now < bannedUntil) {
        return 'rate limited: sender banned for '
            '${bannedUntil - now}s more';
      }
      state.bannedUntil = null;
      state.consecutiveViolations = 0;
    }

    while (state.timestamps.isNotEmpty &&
        now - state.timestamps.first > windowSeconds) {
      state.timestamps.removeFirst();
    }

    if (state.timestamps.length >= maxMessages) {
      state.consecutiveViolations++;
      if (state.consecutiveViolations >= banAfterViolations) {
        state.bannedUntil = now + banSeconds;
      }
      return 'rate limited: over $maxMessages msgs in ${windowSeconds}s window';
    }

    state.timestamps.addLast(now);
    state.consecutiveViolations = 0;
    return null;
  }

  void _prune(int now) {
    _senders.removeWhere((_, s) =>
        s.bannedUntil == null && now - s.lastSeen > _idleSeconds);
  }
}

String _hex(Iterable<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
