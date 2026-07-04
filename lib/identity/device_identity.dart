import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'secure_storage.dart';

/// Storage key for the 32-byte Ed25519 private seed, hex-encoded.
const String _seedStorageKey = 'meshlink_identity_seed_v1';

/// The device's long-term identity: an Ed25519 keypair (not raw Curve25519 —
/// the wire needs Ed25519 signatures from the keypair whose public half is
/// sender_key, and an Ed25519 key converts to Curve25519 for future DM
/// encryption; see PHASE4_CHANGES.md §Identity). Generated once on first
/// launch and persisted via [SecureStorage] (Keychain/Keystore), replacing
/// the Phase 1 hardcoded test keypair.
///
/// Crypto library: package:cryptography ^2.9 (RFC 8032 Ed25519, pure Dart,
/// wire-compatible with the Python core's PyNaCl/libsodium output) — chosen
/// over a libsodium binding to avoid a native dependency the app doesn't
/// need until Ed25519→Curve25519 conversion arrives with DMs.
class DeviceIdentity {
  DeviceIdentity._(this.keyPair, this.publicKey);

  final SimpleKeyPair keyPair;

  /// 32-byte Ed25519 public key — goes in the packet's sender_key field.
  final Uint8List publicKey;

  /// Derive the identity from a 32-byte private seed.
  static Future<DeviceIdentity> fromSeed(Uint8List seed) async {
    final keyPair = await Ed25519().newKeyPairFromSeed(seed);
    final publicKey =
        Uint8List.fromList((await keyPair.extractPublicKey()).bytes);
    return DeviceIdentity._(keyPair, publicKey);
  }

  /// Generate a fresh identity from a CSPRNG seed (not persisted).
  static Future<DeviceIdentity> generate() async =>
      fromSeed(_randomSeed());

  /// Load the device identity from secure storage, generating and persisting
  /// it on first launch. Reinstalling the app wipes the Keychain/Keystore
  /// entry, so a reinstall produces a new identity — expected behavior for
  /// this storage model, not a bug.
  static Future<DeviceIdentity> loadOrGenerate(SecureStorage storage) async {
    final stored = await storage.read(_seedStorageKey);
    if (stored != null) {
      return fromSeed(_fromHex(stored));
    }
    final seed = _randomSeed();
    await storage.write(_seedStorageKey, _toHex(seed));
    return fromSeed(seed);
  }

  static Uint8List _randomSeed() {
    final rng = Random.secure();
    return Uint8List.fromList(List.generate(32, (_) => rng.nextInt(256)));
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
