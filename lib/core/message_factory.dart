import 'dart:typed_data';

import 'package:blake3_dart/blake3_dart.dart';
import 'package:cryptography/cryptography.dart';

import '../identity/device_identity.dart';
import 'message.dart';

/// Message type enum values from docs/message-format.md §4.
const int msgTypeText = 0x01;

/// Location beacon (phone → node, every 120 s while sharing is active).
/// Reuses the pre-existing LOCATION type — no new beacon type.
const int msgTypeLocation = 0x02;

/// Attestation-presentation message (Phase 5): payload is the organiser JWT
/// (ASCII). Must stay identical across the Python core, node, and Dart app.
const int msgTypeAttestation = 0x06;

/// Friendship + node-served location (Phase 5 extension). Wire constants
/// shared with meshlink-core pipeline/message.py MessageType — never
/// renumber.
const int msgTypeFriendRequest = 0x07;
const int msgTypeFriendAccept = 0x08;
const int msgTypeFriendDecline = 0x09;
const int msgTypeLocationQuery = 0x0A;
const int msgTypeLocationResponse = 0x0B;
const int msgTypeLocationRevoke = 0x0C;

/// Derive the 16-byte content-addressable msg_id per docs/message-format.md
/// §3: BLAKE3(sender_key ‖ timestamp_be4 ‖ msg_type_byte ‖ payload)[0:16].
/// Must match the Python core byte-for-byte (blake3 package there,
/// blake3_dart here — both verified against the official BLAKE3 vectors).
Uint8List deriveMsgId({
  required Uint8List senderKey,
  required int timestamp,
  required int msgType,
  required Uint8List payload,
}) {
  final preimage = BytesBuilder()
    ..add(senderKey)
    ..add((ByteData(4)..setUint32(0, timestamp)).buffer.asUint8List())
    ..addByte(msgType)
    ..add(payload);
  return blake3(preimage.takeBytes(), 16);
}

/// Serialize header + payload (everything except the trailing signature).
Uint8List _packHeaderAndPayload({
  required Uint8List msgId,
  required Uint8List senderKey,
  required Uint8List ephemId,
  required int timestamp,
  required int ttl,
  required int sprayL,
  required int zoneId,
  required int msgType,
  required Uint8List payload,
}) {
  assert(msgId.length == 16 && senderKey.length == 32 && ephemId.length == 16);
  final out = Uint8List(headerSize + payload.length);
  final bd = ByteData.sublistView(out);
  out.setRange(0, 16, msgId);
  out.setRange(16, 48, senderKey);
  out.setRange(48, 64, ephemId);
  bd.setUint32(64, timestamp);
  bd.setUint8(68, ttl);
  bd.setUint8(69, sprayL);
  bd.setUint16(70, zoneId);
  bd.setUint8(72, msgType);
  bd.setUint16(73, payload.length);
  out.setRange(headerSize, headerSize + payload.length, payload);
  return out;
}

/// Build and sign a complete packet with the device identity.
/// Sign step of the send path: sign → pipeline checks → transport send.
/// The signature covers [signedRegion] (all bytes except ttl/spray_L, which
/// relays rewrite hop-by-hop).
Future<Uint8List> buildSignedPacket({
  required DeviceIdentity identity,
  required Uint8List ephemId,
  required Uint8List payload,
  int ttl = 5,
  int sprayL = 8,
  int zoneId = 3,
  int msgType = msgTypeText,
  int? timestamp,
}) async {
  if (payload.length > maxPayload) {
    throw ArgumentError('payload ${payload.length} bytes exceeds max $maxPayload');
  }
  final ts = timestamp ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final msgId = deriveMsgId(
    senderKey: identity.publicKey,
    timestamp: ts,
    msgType: msgType,
    payload: payload,
  );
  final headerAndPayload = _packHeaderAndPayload(
    msgId: msgId,
    senderKey: identity.publicKey,
    ephemId: ephemId,
    timestamp: ts,
    ttl: ttl,
    sprayL: sprayL,
    zoneId: zoneId,
    msgType: msgType,
    payload: payload,
  );
  final signature = await Ed25519().sign(
    signedRegion(headerAndPayload, payload.length),
    keyPair: identity.keyPair,
  );
  final packet = Uint8List(headerAndPayload.length + signatureSize);
  packet.setRange(0, headerAndPayload.length, headerAndPayload);
  packet.setRange(headerAndPayload.length, packet.length, signature.bytes);
  return packet;
}
