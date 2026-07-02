import time

from .message import Message

_MAX_AGE_SECONDS = 300   # 5 minutes — replay attack window
_MAX_FUTURE_SECONDS = 30  # clock-skew tolerance


def check_timestamp(msg: Message) -> str | None:
    """Step 3: drop messages too old or too far in the future (replay prevention)."""
    now = int(time.time())
    age = now - msg.timestamp
    if age > _MAX_AGE_SECONDS:
        return f"timestamp too old: {age}s ago (max {_MAX_AGE_SECONDS}s)"
    if age < -_MAX_FUTURE_SECONDS:
        return f"timestamp too far in future: {-age}s ahead (max {_MAX_FUTURE_SECONDS}s)"
    return None
