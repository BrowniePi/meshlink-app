from .message import Message


def check_ttl(msg: Message) -> str | None:
    """Step 2: drop messages whose TTL has reached zero."""
    if msg.ttl == 0:
        return "ttl exhausted"
    return None
