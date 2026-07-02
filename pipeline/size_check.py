from .message import MIN_PACKET, MAX_PACKET


def check_size(raw: bytes) -> str | None:
    """Step 1: drop packets outside [131, 460] bytes before any parsing."""
    n = len(raw)
    if n < MIN_PACKET:
        return f"packet too small: {n} bytes (min {MIN_PACKET})"
    if n > MAX_PACKET:
        return f"packet too large: {n} bytes (max {MAX_PACKET})"
    return None
