from pipeline.dedup_check import DedupCache
from pipeline.message import parse_packet
from tests.helpers import build_packet


def test_first_message_passes():
    cache = DedupCache()
    msg = parse_packet(build_packet())
    assert cache.check(msg) is None


def test_duplicate_drops():
    cache = DedupCache()
    raw = build_packet()
    msg = parse_packet(raw)
    cache.check(msg)
    assert cache.check(msg) is not None


def test_different_msg_ids_both_pass():
    cache = DedupCache()
    msg1 = parse_packet(build_packet(msg_id=b"\x01" * 16))
    msg2 = parse_packet(build_packet(msg_id=b"\x02" * 16))
    assert cache.check(msg1) is None
    assert cache.check(msg2) is None


def test_drop_reason_mentions_duplicate():
    cache = DedupCache()
    msg = parse_packet(build_packet())
    cache.check(msg)
    reason = cache.check(msg)
    assert reason is not None
    assert "duplicate" in reason.lower()
