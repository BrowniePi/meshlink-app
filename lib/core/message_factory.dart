import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'message.dart';
import 'test_identity.dart';

/// Message type enum values from docs/message-format.md §4.
const int msgTypeText = 0x01;

/// Derive the 16-byte content-addressable msg_id.
///
/// TODO(spec divergence): docs/message-format.md §3 specifies
/// BLAKE3(sender_key ‖ timestamp ‖ msg_type ‖ payload)[0:16]; there is no
/// vetted pure-Dart BLAKE3 implementation, so Phase 1 uses SHA-256 truncated
/// to 16 bytes. Nothing recomputes msg_id at Phase 1 (it is only a dedup
/// key), but this must be reconciled with the spec before any second
/// implementation needs to verify msg_ids.
Future<Uint8List> deriveMsgId({
  required Uint8List senderKey,
  required int timestamp,
  required int msgType,
  required Uint8List payload,
}) async {
  final preimage = BytesBuilder()
    ..add(senderKey)
    ..add((ByteData(4)..setUint32(0, timestamp)).buffer.asUint8List())
    ..addByte(msgType)
    ..add(payload);
  final hash = await Sha256().hash(preimage.takeBytes());
  return Uint8List.fromList(hash.bytes.sublist(0, 16));
}

/// Serialize header + payload (the signed region, raw[0 : 75 + payloadLen]).
Uint8List _packSignedRegion({
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

/// Build and sign a complete packet with the Phase 1 test identity.
/// Sign step of the send path: sign → pipeline checks → transport send.
Future<Uint8List> buildSignedPacket({
  required TestIdentity identity,
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
  final msgId = await deriveMsgId(
    senderKey: identity.publicKey,
    timestamp: ts,
    msgType: msgType,
    payload: payload,
  );
  final signedRegion = _packSignedRegion(
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
  final signature = await Ed25519().sign(signedRegion, keyPair: identity.keyPair);
  final packet = Uint8List(signedRegion.length + signatureSize);
  packet.setRange(0, signedRegion.length, signedRegion);
  packet.setRange(signedRegion.length, packet.length, signature.bytes);
  return packet;
}
