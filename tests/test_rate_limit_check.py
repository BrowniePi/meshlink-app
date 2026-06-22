from pipeline.rate_limit_check import check_rate_limit
from pipeline.message import parse_packet
from tests.helpers import build_packet


def test_always_passes():
    # Rate limit is a stub at Phase 0
    msg = parse_packet(build_packet())
    assert check_rate_limit(msg) is None


def test_repeated_calls_always_pass():
    msg = parse_packet(build_packet())
    for _ in range(20):
        assert check_rate_limit(msg) is None
