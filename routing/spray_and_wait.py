"""Spray-and-Wait copy-split logic (Spyropoulos et al., 2005).

Routing cases (Technical Reference §3): Case 1 (both node-connected) uses
spray_L=1 — no spray needed. Case 2 (one end disconnected) uses L=8-16,
flooded toward the destination's last-known zone. Case 3 (both ends
disconnected) uses L=16-32, two feeder hops needed.
"""
from dataclasses import dataclass


@dataclass(frozen=True)
class SprayCopies:
    forward: int  # copies given to the peer
    keep: int     # copies retained by this device


def split_copies(spray_l: int) -> SprayCopies:
    """Binary split rule: peer gets floor(L/2), this device keeps ceil(L/2).

    spray_l <= 0 means no copies remain to split — nothing is forwarded or
    kept (the message has already entered or exhausted the Wait phase).
    """
    if spray_l <= 0:
        return SprayCopies(forward=0, keep=0)
    forward = spray_l // 2
    keep = spray_l - forward
    return SprayCopies(forward=forward, keep=keep)


def is_wait_phase(spray_l: int) -> bool:
    """True once spray_l has reached 1 (or below) — stop spraying, only
    deliver directly to the actual destination if encountered."""
    return spray_l <= 1


class SprayBudgetTracker:
    """Enforces the spray budget contract: a relay must never forward a
    spray_L higher than the value it first observed for a given msg_id.

    Each relay stores the expected L from first sight of msg_id (Technical
    Reference §8.3 "Spray-L inflation"). A later sighting with a higher L
    indicates a relay inflated the budget in transit and is rejected.
    """

    def __init__(self) -> None:
        self._expected: dict[bytes, int] = {}

    def check(self, msg_id: bytes, observed_l: int) -> str | None:
        expected = self._expected.get(msg_id)
        if expected is None:
            self._expected[msg_id] = observed_l
            return None
        if observed_l > expected:
            return f"spray_L inflated: expected <= {expected}, got {observed_l}"
        return None
