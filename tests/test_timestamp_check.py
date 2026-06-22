import time

from pipeline.timestamp_check import check_timestamp
from pipeline.message import parse_packet
from tests.helpers import build_packet


def test_current_timestamp_passes():
    msg = parse_packet(build_packet(timestamp=int(time.time())))
    assert check_timestamp(msg) is None


def test_recent_timestamp_passes():
    msg = parse_packet(build_packet(timestamp=int(time.time()) - 240))
    assert check_timestamp(msg) is None


def test_old_timestamp_drops():
    msg = parse_packet(build_packet(timestamp=int(time.time()) - 361))
    assert check_timestamp(msg) is not None


def test_future_timestamp_drops():
    msg = parse_packet(build_packet(timestamp=int(time.time()) + 31))
    assert check_timestamp(msg) is not None


def test_drop_reason_mentions_timestamp():
    msg = parse_packet(build_packet(timestamp=int(time.time()) - 400))
    reason = check_timestamp(msg)
    assert reason is not None
    assert "old" in reason.lower() or "timestamp" in reason.lower()
