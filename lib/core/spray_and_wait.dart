/// Spray-and-Wait copy-split logic (Spyropoulos et al., 2005) — Dart mirror
/// of meshlink-core routing/spray_and_wait.py.
///
/// Routing cases (Technical Reference §3): Case 1 (both node-connected) uses
/// spray_L=1 — no spray needed. Case 2 (one end disconnected) uses L=8-16,
/// flooded toward the destination's last-known zone. Case 3 (both ends
/// disconnected) uses L=16-32, two feeder hops needed.
library;

class SprayCopies {
  const SprayCopies({required this.forward, required this.keep});

  final int forward; // copies given to the peer
  final int keep; // copies retained by this device
}

/// Binary split rule: peer gets floor(L/2), this device keeps ceil(L/2).
///
/// spray_l <= 0 means no copies remain to split — nothing is forwarded or
/// kept (the message has already entered or exhausted the Wait phase).
SprayCopies splitCopies(int sprayL) {
  if (sprayL <= 0) return const SprayCopies(forward: 0, keep: 0);
  final forward = sprayL ~/ 2;
  return SprayCopies(forward: forward, keep: sprayL - forward);
}

/// True once spray_l has reached 1 (or below) — stop spraying, only
/// deliver directly to the actual destination if encountered.
bool isWaitPhase(int sprayL) => sprayL <= 1;

/// Enforces the spray budget contract: a relay must never forward a
/// spray_L higher than the value it first observed for a given msg_id.
///
/// Each relay stores the expected L from first sight of msg_id (Technical
/// Reference §8.3 "Spray-L inflation"). A later sighting with a higher L
/// indicates a relay inflated the budget in transit and is rejected.
class SprayBudgetTracker {
  final Map<String, int> _expected = {};

  String? check(List<int> msgId, int observedL) {
    final key =
        msgId.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final expected = _expected[key];
    if (expected == null) {
      _expected[key] = observedL;
      return null;
    }
    if (observedL > expected) {
      return 'spray_L inflated: expected <= $expected, got $observedL';
    }
    return null;
  }
}
