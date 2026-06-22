from .message import Message


class DedupCache:
    """Step 4: drop messages whose msg_id has already been seen.

    Phase 0 stub: in-memory set with no TTL eviction. Production implementation
    uses a Bloom filter (pybloom-live) backed by an LRU cache with 10-min TTL —
    the ~1% Bloom false-positive rate is acceptable given Spray-and-Wait redundancy.
    """

    def __init__(self) -> None:
        self._seen: set[bytes] = set()

    def check(self, msg: Message) -> str | None:
        if msg.msg_id in self._seen:
            return "duplicate: msg_id already seen"
        self._seen.add(msg.msg_id)
        return None
