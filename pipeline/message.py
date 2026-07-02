import struct
from dataclasses import dataclass

# Wire format constants from docs/message-format.md
HEADER_FORMAT = ">16s32s16sIBBHBH"
HEADER_SIZE = 75      # fixed header bytes before payload
SIGNATURE_SIZE = 64   # Ed25519 signature appended after payload
MIN_PACKET = 131      # pre-parse size floor (catches truncated headers)
MAX_PACKET = 460      # pre-parse size ceiling (75 header + 321 payload + 64 sig)


@dataclass
class Message:
    raw: bytes
    msg_id: bytes       # 16 bytes — content-addressable dedup key
    sender_key: bytes   # 32 bytes — Curve25519 long-term identity
    ephem_id: bytes     # 16 bytes — rotating on-air identifier
    timestamp: int      # uint32 — Unix seconds at creation
    ttl: int            # uint8  — remaining relay hop budget
    spray_l: int        # uint8  — Spray-and-Wait copy budget
    zone_id: int        # uint16 — destination zone (0xFFFF = broadcast)
    msg_type: int       # uint8  — message type enum
    payload_len: int    # uint16 — byte length of payload field
    payload: bytes      # variable, 0–321 bytes
    signature: bytes    # 64 bytes — Ed25519 over bytes[0 : 75 + payload_len]


def parse_packet(raw: bytes) -> Message:
    """Parse raw bytes into a Message. Raises ValueError if structurally invalid."""
    if len(raw) < HEADER_SIZE + SIGNATURE_SIZE:
        raise ValueError(f"packet too short to parse: {len(raw)} bytes")

    (msg_id, sender_key, ephem_id, timestamp, ttl, spray_l,
     zone_id, msg_type, payload_len) = struct.unpack_from(HEADER_FORMAT, raw)

    expected_len = HEADER_SIZE + payload_len + SIGNATURE_SIZE
    if len(raw) != expected_len:
        raise ValueError(
            f"packet length {len(raw)} != expected {expected_len} "
            f"(payload_len={payload_len})"
        )

    payload = raw[HEADER_SIZE:HEADER_SIZE + payload_len]
    signature = raw[HEADER_SIZE + payload_len:]

    return Message(
        raw=raw,
        msg_id=msg_id,
        sender_key=sender_key,
        ephem_id=ephem_id,
        timestamp=timestamp,
        ttl=ttl,
        spray_l=spray_l,
        zone_id=zone_id,
        msg_type=msg_type,
        payload_len=payload_len,
        payload=payload,
        signature=signature,
    )
