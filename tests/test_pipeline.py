"""Integration tests: verify the full pipeline processes messages end-to-end."""
import time

from pipeline.pipeline import RelayPipeline, Outcome
from tests.helpers import build_packet


def test_valid_message_reaches_deliver():
    pipeline = RelayPipeline()
    result = pipeline.process(build_packet())
    assert result.outcome == Outcome.DELIVER
    assert result.drop_reason is None
    assert result.message is not None


def test_message_fields_preserved_through_pipeline():
    pipeline = RelayPipeline()
    raw = build_packet(ttl=3, zone_id=7, payload=b"test payload")
    result = pipeline.process(raw)
    assert result.outcome == Outcome.DELIVER
    assert result.message.ttl == 3
    assert result.message.zone_id == 7
    assert result.message.payload == b"test payload"


def test_too_small_drops():
    pipeline = RelayPipeline()
    result = pipeline.process(build_packet(force_length=100))
    assert result.outcome == Outcome.DROP


def test_zero_ttl_drops():
    pipeline = RelayPipeline()
    result = pipeline.process(build_packet(ttl=0))
    assert result.outcome == Outcome.DROP


def test_old_timestamp_drops():
    pipeline = RelayPipeline()
    result = pipeline.process(build_packet(timestamp=int(time.time()) - 400))
    assert result.outcome == Outcome.DROP


def test_duplicate_drops_on_second_call():
    pipeline = RelayPipeline()
    raw = build_packet()
    first = pipeline.process(raw)
    second = pipeline.process(raw)
    assert first.outcome == Outcome.DELIVER
    assert second.outcome == Outcome.DROP


def test_ttl_check_fires_before_timestamp():
    # Both TTL=0 and old timestamp — drop reason should be TTL (step 2 before step 3)
    pipeline = RelayPipeline()
    raw = build_packet(ttl=0, timestamp=int(time.time()) - 400)
    result = pipeline.process(raw)
    assert result.outcome == Outcome.DROP
    assert "ttl" in result.drop_reason.lower()


def test_size_check_fires_before_ttl():
    # A truncated packet with TTL=0 should fail at size (step 1), not TTL (step 2)
    pipeline = RelayPipeline()
    raw = build_packet(ttl=0, force_length=10)
    result = pipeline.process(raw)
    assert result.outcome == Outcome.DROP
    assert "small" in result.drop_reason.lower()
