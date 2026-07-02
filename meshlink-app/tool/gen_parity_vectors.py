"""Generate cross-language parity vectors from the Python reference pipeline.

Runs each packet through meshlink-core's RelayPipeline with time.time()
frozen, and records the exact outcome / drop reason / parsed fields so the
Dart port can assert byte-for-byte and string-for-string parity.

Usage (from meshlink-app/):
    python tool/gen_parity_vectors.py > test/fixtures/parity_vectors.json
"""
import json
import sys
from pathlib import Path
from unittest.mock import patch

# meshlink-core repo root, so `pipeline` and `tests` import as packages
sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from pipeline.pipeline import RelayPipeline  # noqa: E402
from tests.helpers import build_packet  # noqa: E402

FIXED_NOW = 1751400010
TS = FIXED_NOW - 10

SENDER_KEY = bytes(range(32))
EPHEM_ID = bytes(range(16))
MSG_ID = bytes.fromhex("3f4a5b6c7d8e9fa0b1c2d3e4f5061728")
PAYLOAD = "Meet at south gate".encode()

valid = build_packet(
    msg_id=MSG_ID, sender_key=SENDER_KEY, ephem_id=EPHEM_ID,
    timestamp=TS, ttl=5, spray_l=8, zone_id=3, msg_type=1, payload=PAYLOAD,
)

cases = [
    ("valid_text_deliver", valid),
    ("duplicate_msg_id", valid),  # second pass through same pipeline
    ("ttl_exhausted", build_packet(msg_id=b"\x11" * 16, sender_key=SENDER_KEY,
                                   ephem_id=EPHEM_ID, timestamp=TS, ttl=0,
                                   payload=PAYLOAD)),
    ("too_small", b"\xab" * 100),
    ("too_large", b"\xab" * 500),
    ("length_mismatch", build_packet(msg_id=b"\x22" * 16, sender_key=SENDER_KEY,
                                     ephem_id=EPHEM_ID, timestamp=TS,
                                     payload=PAYLOAD, force_length=150)),
    ("timestamp_too_old", build_packet(msg_id=b"\x33" * 16, sender_key=SENDER_KEY,
                                       ephem_id=EPHEM_ID,
                                       timestamp=FIXED_NOW - 400, payload=PAYLOAD)),
    ("timestamp_future", build_packet(msg_id=b"\x44" * 16, sender_key=SENDER_KEY,
                                      ephem_id=EPHEM_ID,
                                      timestamp=FIXED_NOW + 60, payload=PAYLOAD)),
]

pipeline = RelayPipeline()
vectors = []
with patch("pipeline.timestamp_check.time") as mock_time:
    mock_time.time.return_value = FIXED_NOW
    for name, raw in cases:
        result = pipeline.process(raw)
        entry = {
            "name": name,
            "raw_hex": raw.hex(),
            "fixed_now": FIXED_NOW,
            "outcome": result.outcome.value,
            "drop_reason": result.drop_reason,
        }
        if result.message is not None:
            m = result.message
            entry["parsed"] = {
                "msg_id_hex": m.msg_id.hex(),
                "sender_key_hex": m.sender_key.hex(),
                "ephem_id_hex": m.ephem_id.hex(),
                "timestamp": m.timestamp,
                "ttl": m.ttl,
                "spray_l": m.spray_l,
                "zone_id": m.zone_id,
                "msg_type": m.msg_type,
                "payload_len": m.payload_len,
                "payload_hex": m.payload.hex(),
                "signature_hex": m.signature.hex(),
            }
        vectors.append(entry)

out = {"generator": "meshlink-core @ Phase1 (python reference)", "vectors": vectors}
print(json.dumps(out, indent=2))
