import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshlink_app/core/sealed.dart';

void main() {
  test('seal/unseal round-trips', () async {
    final recipient = await X25519().newKeyPair();
    final recipientPub =
        Uint8List.fromList((await recipient.extractPublicKey()).bytes);
    final plaintext = Uint8List.fromList(utf8.encode('meet at south gate'));

    final sealed = await seal(plaintext, recipientPub);
    expect(sealed.length, plaintext.length + sealOverhead);
    expect(await unseal(sealed, recipient), plaintext);
  });

  test('only the intended recipient can open it (invariant 4)', () async {
    final recipient = await X25519().newKeyPair();
    final recipientPub =
        Uint8List.fromList((await recipient.extractPublicKey()).bytes);
    final sealed = await seal(Uint8List.fromList([1, 2, 3]), recipientPub);

    final stranger = await X25519().newKeyPair();
    expect(() => unseal(sealed, stranger),
        throwsA(isA<SealedEnvelopeError>()));
  });

  test('any tampered byte fails authentication', () async {
    final recipient = await X25519().newKeyPair();
    final recipientPub =
        Uint8List.fromList((await recipient.extractPublicKey()).bytes);
    final sealed =
        await seal(Uint8List.fromList(utf8.encode('secret')), recipientPub);

    // Flipping the ephemeral pub, the ciphertext, or the tag must all fail.
    for (final i in [0, 32, sealed.length - 1]) {
      final tampered = Uint8List.fromList(sealed);
      tampered[i] ^= 0xff;
      expect(() => unseal(tampered, recipient),
          throwsA(isA<SealedEnvelopeError>()),
          reason: 'byte $i flipped but unseal succeeded');
    }
  });

  test('too-short input is rejected, not crashed on', () async {
    final recipient = await X25519().newKeyPair();
    expect(() => unseal(Uint8List(sealOverhead - 1), recipient),
        throwsA(isA<SealedEnvelopeError>()));
  });
}
