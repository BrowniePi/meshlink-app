from .message import Message


def check_rate_limit(msg: Message) -> str | None:
    """Step 5: rate-limit per sender. Stub — always passes at Phase 0.

    Production implementation: sliding window counter keyed on ephem_id;
    drop if sender exceeds N messages per 10-second window. Must run before
    signature verification (step 6) so a flood attacker cannot force Ed25519
    work before being throttled.
    """
    return None
