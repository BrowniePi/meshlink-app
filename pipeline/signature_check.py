from .message import Message


def check_signature(msg: Message) -> str | None:
    """Step 6: verify Ed25519 signature. Stub — always passes at Phase 0.

    Production implementation (Phase 4): libsodium Ed25519 verify of
    msg.signature over msg.raw[: 75 + msg.payload_len] using msg.sender_key.
    This is the most expensive per-packet operation (~50 µs on Pi 4, ~2–5 ms
    on a mid-range phone) — it runs last among the security checks precisely
    so cheap structural and rate-limit checks can short-circuit before it.
    """
    return None
