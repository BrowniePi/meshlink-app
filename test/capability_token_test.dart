import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshlink_app/core/capability_token.dart';

Future<(SimpleKeyPair, Uint8List)> _keypair() async {
  final kp = await Ed25519().newKeyPair();
  return (kp, Uint8List.fromList((await kp.extractPublicKey()).bytes));
}

void main() {
  const now = 1751400000;

  late SimpleKeyPair targetKp;
  late Uint8List targetPub; // the person whose location is shared (issuer)
  late Uint8List granteePub; // the friend allowed to ask

  Future<Uint8List> issue({int? issuedAt, Duration? expiry}) => issueToken(
        issuerKeyPair: targetKp,
        issuerPub: targetPub,
        granteeEd25519Pub: granteePub,
        issuedAt: issuedAt ?? now,
        expiry: expiry ?? defaultTokenExpiry,
      );

  setUpAll(() async {
    final (kp, pub) = await _keypair();
    targetKp = kp;
    targetPub = pub;
    final (_, gPub) = await _keypair();
    granteePub = gPub;
  });

  test('a freshly issued token is exactly 98 bytes and verifies', () async {
    final raw = await issue();
    expect(raw.length, tokenSize);
    expect(await verifyToken(raw, targetPub, granteePub, now + 60), isTrue);
  });

  test('parse round-trips every field', () async {
    final raw = await issue();
    final token = parseToken(raw);
    expect(token.version, tokenVersion);
    expect(token.issuerPubkeyId, pubkeyId(targetPub));
    expect(token.granteePubkeyId, pubkeyId(granteePub));
    expect(token.issuedAt, now);
    expect(token.expiresAt, now + defaultTokenExpiry.inSeconds);
    expect(token.scope, scopeLocation);
  });

  test('every single flipped byte invalidates the token', () async {
    // Invariant 1: the node never fabricates consent — any bit of a token it
    // could forge or splice must fail verification.
    final raw = await issue();
    for (var i = 0; i < raw.length; i++) {
      final tampered = Uint8List.fromList(raw);
      tampered[i] ^= 0xff;
      expect(
        await verifyToken(tampered, targetPub, granteePub, now + 60),
        isFalse,
        reason: 'byte $i flipped but token still verified',
      );
    }
  });

  test('expired and not-yet-valid tokens are refused', () async {
    final raw = await issue();
    expect(
      await verifyToken(raw, targetPub, granteePub,
          now + defaultTokenExpiry.inSeconds),
      isFalse,
      reason: 'consent expires (invariant 5) — expiry second is exclusive',
    );
    expect(await verifyToken(raw, targetPub, granteePub, now - 1), isFalse);
  });

  test('the wrong grantee cannot use a stolen token', () async {
    final raw = await issue();
    final (_, strangerPub) = await _keypair();
    expect(await verifyToken(raw, targetPub, strangerPub, now + 60), isFalse);
  });

  test('a token signed by someone else than the target is refused', () async {
    final (forgerKp, forgerPub) = await _keypair();
    final forged = await issueToken(
      issuerKeyPair: forgerKp,
      issuerPub: forgerPub,
      granteeEd25519Pub: granteePub,
      issuedAt: now,
    );
    // Verifier binds the token to the *expected* target's key.
    expect(await verifyToken(forged, targetPub, granteePub, now + 60), isFalse);
  });

  test('wrong scope is refused', () async {
    final raw = await issue();
    expect(
      await verifyToken(raw, targetPub, granteePub, now + 60, scope: 0x02),
      isFalse,
    );
  });
}
