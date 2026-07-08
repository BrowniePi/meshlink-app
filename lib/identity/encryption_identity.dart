import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'secure_storage.dart';

/// Storage key for the 32-byte X25519 private key, hex-encoded.
const String _x25519StorageKey = 'meshlink_encryption_seed_v1';

/// The account's long-term *encryption* identity: an X25519 keypair, distinct
/// from the Ed25519 signing identity ([DeviceIdentity]). Kept separate
/// because package:cryptography cannot do libsodium's Ed25519→Curve25519
/// birational conversion — so both public keys are registered at
/// POST /account and travel in friend payloads. Same Keychain/Keystore
/// storage as the signing seed; no second key store.
class EncryptionIdentity {
  EncryptionIdentity._(this.keyPair, this.publicKey);

  final SimpleKeyPair keyPair;

  /// 32-byte X25519 public key — the account's `curve25519_pub`.
  final Uint8List publicKey;

  static Future<EncryptionIdentity> fromSeed(Uint8List seed) async {
    final keyPair = await X25519().newKeyPairFromSeed(seed);
    final publicKey =
        Uint8List.fromList((await keyPair.extractPublicKey()).bytes);
    return EncryptionIdentity._(keyPair, publicKey);
  }

  /// Load from secure storage, generating and persisting on first use —
  /// mirrors [DeviceIdentity.loadOrGenerate].
  static Future<EncryptionIdentity> loadOrGenerate(SecureStorage storage) async {
    final stored = await storage.read(_x25519StorageKey);
    if (stored != null) return fromSeed(_fromHex(stored));
    final rng = Random.secure();
    final seed = Uint8List.fromList(List.generate(32, (_) => rng.nextInt(256)));
    await storage.write(_x25519StorageKey, _toHex(seed));
    return fromSeed(seed);
  }
}

String _toHex(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Uint8List _fromHex(String hex) {
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}
