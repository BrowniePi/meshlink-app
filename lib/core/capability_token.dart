import 'dart:math';
import 'dart:typed_data';

import 'package:blake3_dart/blake3_dart.dart';
import 'package:cryptography/cryptography.dart';

/// Capability token for node-served location — Dart mirror of
/// meshlink-core/capability/token.py (byte-exact; see
/// test/friendship_parity_test.dart).
///
/// Security invariant 1: the node never fabricates consent. Access to a
/// coordinate is gated on this token, signed by the TARGET's own long-term
/// Ed25519 key — the key that never leaves this phone's Keychain/Keystore.
/// A compromised node cannot forge it.
///
/// Compact binary (98 bytes, big-endian, fixed order):
///   version(1) ‖ issuer_pubkey_id(8) ‖ grantee_pubkey_id(8) ‖
///   issued_at(4) ‖ expires_at(4) ‖ scope(1) ‖ nonce(8) ‖ signature(64)
const int tokenVersion = 1;
const int scopeLocation = 0x01;
const int tokenBodySize = 34;
const int tokenSize = 98;

/// Short expiry bounds a leaked token's usefulness (invariant 5). The app
/// auto-refreshes while sharing stays enabled.
const Duration defaultTokenExpiry = Duration(hours: 24);

final _ed25519 = Ed25519();

/// 8-byte truncated BLAKE3 of a long-term Ed25519 public key.
Uint8List pubkeyId(Uint8List ed25519Pub) {
  if (ed25519Pub.length != 32) {
    throw ArgumentError('ed25519 public key must be 32 bytes');
  }
  return blake3(ed25519Pub, 8);
}

class CapabilityToken {
  CapabilityToken({
    required this.version,
    required this.issuerPubkeyId,
    required this.granteePubkeyId,
    required this.issuedAt,
    required this.expiresAt,
    required this.scope,
    required this.nonce,
    required this.signature,
  });

  final int version;
  final Uint8List issuerPubkeyId;
  final Uint8List granteePubkeyId;
  final int issuedAt;
  final int expiresAt;
  final int scope;
  final Uint8List nonce;
  final Uint8List signature;

  Uint8List get body {
    final out = Uint8List(tokenBodySize);
    final bd = ByteData.sublistView(out);
    bd.setUint8(0, version);
    out.setRange(1, 9, issuerPubkeyId);
    out.setRange(9, 17, granteePubkeyId);
    bd.setUint32(17, issuedAt);
    bd.setUint32(21, expiresAt);
    bd.setUint8(25, scope);
    out.setRange(26, 34, nonce);
    return out;
  }

  Uint8List get raw => Uint8List.fromList([...body, ...signature]);

  /// (issuer, grantee, issued_at, nonce) — what a LOCATION_REVOKE names.
  /// Kept as the four fields; see friend_wire.encodeLocationRevoke.
}

/// Decode a token. Throws [FormatException] if structurally invalid.
CapabilityToken parseToken(Uint8List raw) {
  if (raw.length != tokenSize) {
    throw FormatException('capability token must be $tokenSize bytes, got ${raw.length}');
  }
  final bd = ByteData.sublistView(raw);
  return CapabilityToken(
    version: bd.getUint8(0),
    issuerPubkeyId: raw.sublist(1, 9),
    granteePubkeyId: raw.sublist(9, 17),
    issuedAt: bd.getUint32(17),
    expiresAt: bd.getUint32(21),
    scope: bd.getUint8(25),
    nonce: raw.sublist(26, 34),
    signature: raw.sublist(34),
  );
}

/// Mint a token signed with OUR long-term Ed25519 key — only ever called by
/// the person whose location is being shared (the target/grantor).
Future<Uint8List> issueToken({
  required SimpleKeyPair issuerKeyPair,
  required Uint8List issuerPub,
  required Uint8List granteeEd25519Pub,
  int scope = scopeLocation,
  int? issuedAt,
  Duration expiry = defaultTokenExpiry,
  Uint8List? nonce,
}) async {
  final at = issuedAt ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final rng = Random.secure();
  final n = nonce ?? Uint8List.fromList(List.generate(8, (_) => rng.nextInt(256)));
  final token = CapabilityToken(
    version: tokenVersion,
    issuerPubkeyId: pubkeyId(issuerPub),
    granteePubkeyId: pubkeyId(granteeEd25519Pub),
    issuedAt: at,
    expiresAt: at + expiry.inSeconds,
    scope: scope,
    nonce: n,
    signature: Uint8List(0),
  );
  final signature = await _ed25519.sign(token.body, keyPair: issuerKeyPair);
  return Uint8List.fromList([...token.body, ...signature.bytes]);
}

/// Pure verification, mirroring core `capability.verify`: issuer binding to
/// the expected target key, grantee binding, scope bit, time window, and the
/// target's Ed25519 signature.
Future<bool> verifyToken(
  Uint8List raw,
  Uint8List expectedTargetEd25519Pub,
  Uint8List granteePubkey,
  int now, {
  int scope = scopeLocation,
}) async {
  final CapabilityToken token;
  try {
    token = parseToken(raw);
  } on FormatException {
    return false;
  }
  if (token.version != tokenVersion) return false;
  if (!_bytesEqual(token.issuerPubkeyId, pubkeyId(expectedTargetEd25519Pub))) {
    return false;
  }
  if (!_bytesEqual(token.granteePubkeyId, pubkeyId(granteePubkey))) return false;
  if (token.scope & scope == 0) return false;
  if (!(token.issuedAt <= now && now < token.expiresAt)) return false;
  return _ed25519.verify(
    token.body,
    signature: Signature(
      token.signature,
      publicKey: SimplePublicKey(expectedTargetEd25519Pub,
          type: KeyPairType.ed25519),
    ),
  );
}

bool _bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
