import 'dart:typed_data';

/// Wire format constants from meshlink-core/docs/message-format.md (v0.1).
/// This file is the Dart mirror of meshlink-core/pipeline/message.py — both
/// implement the same spec; the spec is the single source of truth.
const int headerSize = 75; // fixed header bytes before payload
const int signatureSize = 64; // Ed25519 signature appended after payload
const int minPacket = 131; // pre-parse size floor (catches truncated headers)
const int maxPacket = 460; // 75 header + 321 payload + 64 sig
const int maxPayload = 321;
const int broadcastZone = 0xFFFF; // zone_id value meaning "all zones / mesh-wide"

/// Thrown by [parsePacket] when a packet is structurally invalid.
/// Mirrors the ValueError raised by the Python reference implementation;
/// [message] matches the Python error string byte-for-byte so drop reasons
/// stay identical across languages.
class MalformedPacket implements Exception {
  MalformedPacket(this.message);
  final String message;

  @override
  String toString() => message;
}

class Message {
  Message({
    required this.raw,
    required this.msgId,
    required this.senderKey,
    required this.ephemId,
    required this.timestamp,
    required this.ttl,
    required this.sprayL,
    required this.zoneId,
    required this.msgType,
    required this.payloadLen,
    required this.payload,
    required this.signature,
  });

  final Uint8List raw;
  final Uint8List msgId; // 16 bytes — content-addressable dedup key
  final Uint8List senderKey; // 32 bytes — long-term identity public key
  final Uint8List ephemId; // 16 bytes — rotating on-air identifier
  final int timestamp; // uint32 — Unix seconds at creation
  final int ttl; // uint8  — remaining relay hop budget
  final int sprayL; // uint8  — Spray-and-Wait copy budget
  final int zoneId; // uint16 — destination zone (0xFFFF = broadcast)
  final int msgType; // uint8  — message type enum
  final int payloadLen; // uint16 — byte length of payload field
  final Uint8List payload; // variable, 0–321 bytes
  final Uint8List signature; // 64 bytes — Ed25519 over signedRegion(raw)
}

/// The bytes covered by the Ed25519 signature: every field except `ttl`
/// (offset 68), `spray_L` (offset 69), and the signature itself —
/// `raw[0:68] ‖ raw[70 : 75 + payloadLen]`.
///
/// Those two bytes are rewritten at every relay hop (ttl decremented,
/// spray_L binary-split), so including them would invalidate the origin
/// signature past the first hop. Deviation from the original wire spec,
/// confirmed 2026-07-04 — see PHASE4_CHANGES.md §Signing. Single
/// implementation used by both signing and verification, mirroring
/// pipeline/message.py:signed_region().
Uint8List signedRegion(Uint8List raw, int payloadLen) {
  final out = Uint8List(headerSize - 2 + payloadLen);
  out.setRange(0, 68, raw);
  out.setRange(68, out.length, raw, 70);
  return out;
}

/// Parse raw bytes into a [Message]. Throws [MalformedPacket] if structurally
/// invalid. Field offsets and error strings mirror pipeline/message.py.
Message parsePacket(Uint8List raw) {
  if (raw.length < headerSize + signatureSize) {
    throw MalformedPacket('packet too short to parse: ${raw.length} bytes');
  }

  final bd = ByteData.sublistView(raw);
  final msgId = Uint8List.sublistView(raw, 0, 16);
  final senderKey = Uint8List.sublistView(raw, 16, 48);
  final ephemId = Uint8List.sublistView(raw, 48, 64);
  final timestamp = bd.getUint32(64); // big-endian, as in ">16s32s16sIBBHBH"
  final ttl = bd.getUint8(68);
  final sprayL = bd.getUint8(69);
  final zoneId = bd.getUint16(70);
  final msgType = bd.getUint8(72);
  final payloadLen = bd.getUint16(73);

  final expectedLen = headerSize + payloadLen + signatureSize;
  if (raw.length != expectedLen) {
    throw MalformedPacket(
      'packet length ${raw.length} != expected $expectedLen '
      '(payload_len=$payloadLen)',
    );
  }

  final payload = Uint8List.sublistView(raw, headerSize, headerSize + payloadLen);
  final signature = Uint8List.sublistView(raw, headerSize + payloadLen);

  return Message(
    raw: raw,
    msgId: msgId,
    senderKey: senderKey,
    ephemId: ephemId,
    timestamp: timestamp,
    ttl: ttl,
    sprayL: sprayL,
    zoneId: zoneId,
    msgType: msgType,
    payloadLen: payloadLen,
    payload: payload,
    signature: signature,
  );
}
