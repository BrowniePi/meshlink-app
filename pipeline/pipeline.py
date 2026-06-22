from dataclasses import dataclass
from enum import Enum
from typing import Optional

from .message import Message, parse_packet
from .size_check import check_size
from .ttl_check import check_ttl
from .timestamp_check import check_timestamp
from .dedup_check import DedupCache
from .rate_limit_check import check_rate_limit
from .signature_check import check_signature
from .attestation_check import check_attestation


class Outcome(Enum):
    DELIVER = "deliver"
    RELAY = "relay"
    DROP = "drop"


@dataclass
class PipelineResult:
    outcome: Outcome
    drop_reason: Optional[str] = None
    message: Optional[Message] = None


class RelayPipeline:
    """Ordered relay pipeline for MeshLink messages.

    Steps run cheapest-first: a flood attacker sending forged packets hits the
    rate-limit (step 5) before any Ed25519 work is done. Violating this order
    opens a CPU and battery exhaustion vector on mobile relays.

    Steps 5–7 are stubs at Phase 0; they are replaced with real implementations
    in Phases 0 (rate-limit), 4 (signature), and 5 (attestation) respectively.
    """

    def __init__(self) -> None:
        self._dedup = DedupCache()

    def process(self, raw: bytes) -> PipelineResult:
        # Step 1 — size (pre-parse, one comparison)
        if reason := check_size(raw):
            return PipelineResult(Outcome.DROP, reason)

        # Parse header; drop if structurally malformed (e.g. payload_len mismatch)
        try:
            msg = parse_packet(raw)
        except ValueError as exc:
            return PipelineResult(Outcome.DROP, f"malformed: {exc}")

        # Step 2 — TTL
        if reason := check_ttl(msg):
            return PipelineResult(Outcome.DROP, reason)

        # Step 3 — timestamp (replay prevention, before dedup state is written)
        if reason := check_timestamp(msg):
            return PipelineResult(Outcome.DROP, reason)

        # Step 4 — dedup (Bloom filter / LRU in production)
        if reason := self._dedup.check(msg):
            return PipelineResult(Outcome.DROP, reason)

        # Step 5 — rate limit (stub)
        if reason := check_rate_limit(msg):
            return PipelineResult(Outcome.DROP, reason)

        # Step 6 — Ed25519 signature (stub; real in Phase 4)
        if reason := check_signature(msg):
            return PipelineResult(Outcome.DROP, reason)

        # Step 7 — attestation token (stub; real in Phase 5)
        if reason := check_attestation(msg):
            return PipelineResult(Outcome.DROP, reason)

        # Step 8 — deliver or relay (stub: always deliver at Phase 0)
        return PipelineResult(Outcome.DELIVER, message=msg)
