from pipeline.ttl_check import check_ttl
from pipeline.message import parse_packet
from tests.helpers import build_packet


def test_positive_ttl_passes():
    assert check_ttl(parse_packet(build_packet(ttl=5))) is None


def test_ttl_one_passes():
    assert check_ttl(parse_packet(build_packet(ttl=1))) is None


def test_ttl_zero_drops():
    assert check_ttl(parse_packet(build_packet(ttl=0))) is not None


def test_drop_reason_mentions_ttl():
    reason = check_ttl(parse_packet(build_packet(ttl=0)))
    assert reason is not None
    assert "ttl" in reason.lower()
