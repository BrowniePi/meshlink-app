from .message import Message


def check_attestation(msg: Message) -> str | None:
    """Step 7: verify ticket-bound attestation token. Stub — always passes at Phase 0.

    Production implementation (Phase 5): validate a JWT attestation token issued
    by meshlink-backend asserting that msg.sender_key belongs to a ticket holder.
    A Sybil attacker must purchase one ticket per identity to pass this check.
    """
    return None
