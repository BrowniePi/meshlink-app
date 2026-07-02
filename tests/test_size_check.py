from pipeline.size_check import check_size
from tests.helpers import build_packet


def test_valid_packet_passes():
    assert check_size(build_packet()) is None


def test_too_small_drops():
    assert check_size(build_packet(force_length=130)) is not None


def test_too_large_drops():
    assert check_size(build_packet(force_length=461)) is not None


def test_min_boundary_passes():
    assert check_size(build_packet(force_length=131)) is None


def test_max_boundary_passes():
    assert check_size(build_packet(force_length=460)) is None


def test_drop_reason_mentions_size():
    reason = check_size(build_packet(force_length=10))
    assert reason is not None
    assert "small" in reason
