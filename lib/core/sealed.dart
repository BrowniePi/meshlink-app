import 'dart:typed_data';

import 'package:blake3_dart/blake3_dart.dart';
import 'package:cryptography/cryptography.dart';

/// Anonymous sealed envelope to an X25519 public key — Dart mirror of
/// meshlink-core/crypto/sealed.py; both must produce interchangeable bytes
/// (asserted by test/friendship_parity_test.dart):
///
///   ephemeral X25519 keypair (fresh per message)
///   shared  = X25519(ephemeral_priv, recipient_pub)
///   key     = BLAKE3(shared ‖ ephemeral_pub ‖ recipient_pub)[0:32]
///   nonce   = 12 zero bytes (key is unique per message)
///   wire    = ephemeral_pub(32) ‖ ciphertext ‖ tag(16)   (ChaCha20-Poly1305)
///
/// Used for friend request/accept payloads and to open the node's
/// LOCATION_RESPONSE (invariant 4: replies are unreadable to a passive
/// sniffer). Sender authenticity comes from the envelope Ed25519 signature,
/// never from this layer.
const int sealOverhead = 48; // 32 ephemeral pub + 16 tag

final _x25519 = X25519();
final _aead = Chacha20.poly1305Aead();
final _zeroNonce = List<int>.filled(12, 0);

class SealedEnvelopeError implements Exception {
  SealedEnvelopeError(this.message);
  final String message;
  @override
  String toString() => message;
}

Future<Uint8List> _deriveKey(
    SecretKey shared, List<int> ephemeralPub, List<int> recipientPub) async {
  final sharedBytes = await shared.extractBytes();
  final preimage = BytesBuilder()
    ..add(sharedBytes)
    ..add(ephemeralPub)
    ..add(recipientPub);
  return blake3(preimage.takeBytes(), 32);
}

/// Encrypt [plaintext] so only the holder of the recipient's X25519 private
/// key can read it. Fresh ephemeral keypair per call.
Future<Uint8List> seal(Uint8List plaintext, Uint8List recipientPub) async {
  if (recipientPub.length != 32) {
    throw ArgumentError('recipient public key must be 32 bytes');
  }
  final ephemeral = await _x25519.newKeyPair();
  final ephemeralPub = (await ephemeral.extractPublicKey()).bytes;
  final shared = await _x25519.sharedSecretKey(
    keyPair: ephemeral,
    remotePublicKey: SimplePublicKey(recipientPub, type: KeyPairType.x25519),
  );
  final key = await _deriveKey(shared, ephemeralPub, recipientPub);
  final box = await _aead.encrypt(plaintext,
      secretKey: SecretKey(key), nonce: _zeroNonce);
  final out = BytesBuilder()
    ..add(ephemeralPub)
    ..add(box.cipherText)
    ..add(box.mac.bytes);
  return out.takeBytes();
}

/// Decrypt a sealed envelope with our X25519 keypair. Throws
/// [SealedEnvelopeError] on tampering or a wrong key — callers treat that as
/// a silent drop.
Future<Uint8List> unseal(Uint8List sealed, SimpleKeyPair recipientKeyPair) async {
  if (sealed.length < sealOverhead) {
    throw SealedEnvelopeError('sealed envelope too short');
  }
  final ephemeralPub = sealed.sublist(0, 32);
  final cipherText = sealed.sublist(32, sealed.length - 16);
  final mac = Mac(sealed.sublist(sealed.length - 16));
  final recipientPub = (await recipientKeyPair.extractPublicKey()).bytes;
  final shared = await _x25519.sharedSecretKey(
    keyPair: recipientKeyPair,
    remotePublicKey: SimplePublicKey(ephemeralPub, type: KeyPairType.x25519),
  );
  final key = await _deriveKey(shared, ephemeralPub, recipientPub);
  try {
    final clear = await _aead.decrypt(
      SecretBox(cipherText, nonce: _zeroNonce, mac: mac),
      secretKey: SecretKey(key),
    );
    return Uint8List.fromList(clear);
  } on SecretBoxAuthenticationError {
    throw SealedEnvelopeError('sealed envelope failed to open');
  }
}
