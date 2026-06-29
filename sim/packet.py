"""Minimal packet builder for the simulation harness.

Kept separate from tests/helpers.py so production-adjacent sim/ code doesn't
depend on the tests/ package.
"""
import struct

from pipeline.message import HEADER_FORMAT, SIGNATURE_SIZE


def build_packet(
    *,
    msg_id: bytes,
    sender_key: bytes,
    ephem_id: bytes,
    timestamp: int,
    ttl: int,
    spray_l: int,
    zone_id: int,
    msg_type: int,
    payload: bytes,
    signature: bytes = b"\x00" * SIGNATURE_SIZE,
) -> bytes:
    """Serialize a well-formed packet. ttl/spray_l are header fields, so
    relaying with a decremented ttl or reduced spray_l means re-serializing —
    signature is a stub at Phase 0, so this is safe."""
    header = struct.pack(
        HEADER_FORMAT,
        msg_id, sender_key, ephem_id,
        timestamp, ttl, spray_l, zone_id, msg_type, len(payload),
    )
    return header + payload + signature
