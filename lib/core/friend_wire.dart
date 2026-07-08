import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'capability_token.dart';
import 'sealed.dart';

/// Payload codecs for the friendship + location message types — Dart mirror
/// of meshlink-core friends/wire.py and location/wire.py (byte-exact; see
/// test/friendship_parity_test.dart).
///
/// The envelope has no destination field, so recipient-addressed payloads
/// start with an 8-byte plaintext `recipient_hint` = BLAKE3(recipient
/// Ed25519 pub)[0:8]; the rest is sealed to the recipient's X25519 key.
/// Nothing here touches BLE advertising (invariant 2) — hints ride inside
/// signed envelopes on established connections.
const int recipientHintSize = 8;
const int maxUsernameBytes = 32;

class FriendRequestPayload {
  FriendRequestPayload(this.username, this.curve25519Pub, this.ed25519Pub);
  final String username;
  final Uint8List curve25519Pub;
  final Uint8List ed25519Pub;
}

class FriendAcceptPayload {
  FriendAcceptPayload(this.username, this.curve25519Pub, this.ed25519Pub,
      [this.capabilityToken]);
  final String username;
  final Uint8List curve25519Pub;
  final Uint8List ed25519Pub;

  /// Present when the acceptor also enabled location sharing at accept time.
  final Uint8List? capabilityToken;
}

class LocationResponsePayload {
  LocationResponsePayload({
    required this.latMicrodeg,
    required this.lonMicrodeg,
    required this.accuracyM,
    required this.beaconAgeS,
    required this.zoneId,
  });
  final int latMicrodeg;
  final int lonMicrodeg;
  final int accuracyM;

  /// How stale the node's coordinate is — surfaced as "updated Xs ago".
  final int beaconAgeS;
  final int zoneId;
}

Uint8List recipientHintOf(Uint8List payload) {
  if (payload.length < recipientHintSize) {
    throw const FormatException('payload shorter than recipient hint');
  }
  return payload.sublist(0, recipientHintSize);
}

Uint8List _packIdentity(String username, Uint8List curvePub, Uint8List edPub) {
  final name = utf8.encode(username);
  if (name.isEmpty || name.length > maxUsernameBytes) {
    throw ArgumentError('username must be 1-$maxUsernameBytes UTF-8 bytes');
  }
  if (curvePub.length != 32 || edPub.length != 32) {
    throw ArgumentError('public keys must be 32 bytes');
  }
  return Uint8List.fromList([name.length, ...name, ...curvePub, ...edPub]);
}

(String, Uint8List, Uint8List, Uint8List) _unpackIdentity(Uint8List data) {
  if (data.isEmpty) throw const FormatException('identity block truncated');
  final nameLen = data[0];
  if (nameLen < 1 || nameLen > maxUsernameBytes || data.length < 1 + nameLen + 64) {
    throw const FormatException('identity block malformed');
  }
  final name = utf8.decode(data.sublist(1, 1 + nameLen));
  final curvePub = data.sublist(1 + nameLen, 1 + nameLen + 32);
  final edPub = data.sublist(1 + nameLen + 32, 1 + nameLen + 64);
  return (name, curvePub, edPub, data.sublist(1 + nameLen + 64));
}

Future<Uint8List> encodeFriendRequest(FriendRequestPayload payload,
    Uint8List recipientHint, Uint8List recipientCurvePub) async {
  final body =
      _packIdentity(payload.username, payload.curve25519Pub, payload.ed25519Pub);
  return Uint8List.fromList(
      [...recipientHint, ...await seal(body, recipientCurvePub)]);
}

Future<FriendRequestPayload> decodeFriendRequest(
    Uint8List raw, SimpleKeyPair recipientCurveKeyPair) async {
  final body =
      await unseal(raw.sublist(recipientHintSize), recipientCurveKeyPair);
  final (name, curvePub, edPub, rest) = _unpackIdentity(body);
  if (rest.isNotEmpty) {
    throw const FormatException('trailing bytes in FRIEND_REQUEST payload');
  }
  return FriendRequestPayload(name, curvePub, edPub);
}

Future<Uint8List> encodeFriendAccept(FriendAcceptPayload payload,
    Uint8List recipientHint, Uint8List recipientCurvePub) async {
  var body =
      _packIdentity(payload.username, payload.curve25519Pub, payload.ed25519Pub);
  final token = payload.capabilityToken;
  if (token == null) {
    body = Uint8List.fromList([...body, 0]);
  } else {
    if (token.length != tokenSize) {
      throw ArgumentError('capability token has wrong size');
    }
    body = Uint8List.fromList([...body, 1, ...token]);
  }
  return Uint8List.fromList(
      [...recipientHint, ...await seal(body, recipientCurvePub)]);
}

Future<FriendAcceptPayload> decodeFriendAccept(
    Uint8List raw, SimpleKeyPair recipientCurveKeyPair) async {
  final body =
      await unseal(raw.sublist(recipientHintSize), recipientCurveKeyPair);
  final (name, curvePub, edPub, rest) = _unpackIdentity(body);
  if (rest.isEmpty) throw const FormatException('FRIEND_ACCEPT payload truncated');
  final hasToken = rest[0] != 0;
  final tail = rest.sublist(1);
  Uint8List? token;
  if (hasToken) {
    if (tail.length != tokenSize) {
      throw const FormatException('FRIEND_ACCEPT token block malformed');
    }
    token = tail;
  } else if (tail.isNotEmpty) {
    throw const FormatException('trailing bytes in FRIEND_ACCEPT payload');
  }
  return FriendAcceptPayload(name, curvePub, edPub, token);
}

/// FRIEND_DECLINE: minimal by design — hint + declined request's msg_id.
Uint8List encodeFriendDecline(Uint8List requestMsgId, Uint8List recipientHint) {
  if (requestMsgId.length != 16) throw ArgumentError('msg_id must be 16 bytes');
  return Uint8List.fromList([...recipientHint, ...requestMsgId]);
}

Uint8List decodeFriendDecline(Uint8List raw) {
  if (raw.length != recipientHintSize + 16) {
    throw const FormatException('FRIEND_DECLINE payload malformed');
  }
  return raw.sublist(recipientHintSize);
}

/// LOCATION_QUERY payload is exactly the capability token.
Uint8List encodeLocationQuery(Uint8List capabilityToken) {
  if (capabilityToken.length != tokenSize) {
    throw ArgumentError('capability token has wrong size');
  }
  return capabilityToken;
}

Future<LocationResponsePayload> decodeLocationResponse(
    Uint8List raw, SimpleKeyPair requesterCurveKeyPair) async {
  final body =
      await unseal(raw.sublist(recipientHintSize), requesterCurveKeyPair);
  if (body.length != 16) {
    throw const FormatException('LOCATION_RESPONSE payload malformed');
  }
  final bd = ByteData.sublistView(body);
  return LocationResponsePayload(
    latMicrodeg: bd.getInt32(0),
    lonMicrodeg: bd.getInt32(4),
    accuracyM: bd.getUint16(8),
    beaconAgeS: bd.getUint32(10),
    zoneId: bd.getUint16(14),
  );
}

/// LOCATION_REVOKE payload: the revocation key of a previously issued grant.
Uint8List encodeLocationRevoke({
  required Uint8List issuerPubkeyId,
  required Uint8List granteePubkeyId,
  required int issuedAt,
  required Uint8List nonce,
}) {
  final out = Uint8List(28);
  final bd = ByteData.sublistView(out);
  out.setRange(0, 8, issuerPubkeyId);
  out.setRange(8, 16, granteePubkeyId);
  bd.setUint32(16, issuedAt);
  out.setRange(20, 28, nonce);
  return out;
}

/// LOCATION (0x02) beacon payload — pre-existing 10-byte format from
/// docs/message-format.md §4: lat/lon in signed microdegrees + accuracy_m.
Uint8List encodeLocationBeacon(int latMicrodeg, int lonMicrodeg, int accuracyM) {
  final out = Uint8List(10);
  final bd = ByteData.sublistView(out);
  bd.setInt32(0, latMicrodeg);
  bd.setInt32(4, lonMicrodeg);
  bd.setUint16(8, accuracyM);
  return out;
}
