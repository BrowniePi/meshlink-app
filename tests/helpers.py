"""Test helpers for constructing well-formed MeshLink packets."""
import struct
import time

_HEADER_FORMAT = ">16s32s16sIBBHBH"
_SIGNATURE_SIZE = 64

DEFAULT_MSG_ID = b"\x00" * 16
DEFAULT_SENDER_KEY = b"\x01" * 32
DEFAULT_EPHEM_ID = b"\x02" * 16
DEFAULT_PAYLOAD = b"hello"


def build_packet(
    *,
    msg_id: bytes = DEFAULT_MSG_ID,
    sender_key: bytes = DEFAULT_SENDER_KEY,
    ephem_id: bytes = DEFAULT_EPHEM_ID,
    timestamp: int | None = None,
    ttl: int = 5,
    spray_l: int = 8,
    zone_id: int = 3,
    msg_type: int = 1,
    payload: bytes = DEFAULT_PAYLOAD,
    signature: bytes | None = None,
    force_length: int | None = None,
) -> bytes:
    """Build a structurally valid packet. Use force_length to test size checks."""
    if timestamp is None:
        timestamp = int(time.time())
    if signature is None:
        signature = b"\x00" * _SIGNATURE_SIZE

    header = struct.pack(
        _HEADER_FORMAT,
        msg_id, sender_key, ephem_id,
        timestamp, ttl, spray_l, zone_id, msg_type, len(payload),
    )
    packet = header + payload + signature

    if force_length is not None:
        if force_length < len(packet):
            packet = packet[:force_length]
        else:
            packet = packet + b"\x00" * (force_length - len(packet))

    return packet
