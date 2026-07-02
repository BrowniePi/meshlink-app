// ============================================================================
// PHASE 1 SCAFFOLDING — INSECURE BY DESIGN. TODO Phase 4: replace with real
// per-device key generation and secure storage (Keychain / Keystore).
//
// This is a single hardcoded Ed25519 keypair baked into every install so the
// relay pipeline's signature check has something real to verify against.
// It provides NO security: the private seed is public in source control.
// Internal/debug use only — nothing user-facing may present this as an
// identity or imply messages are authenticated.
// ============================================================================
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Fixed 32-byte Ed25519 seed. Publicly known — see the warning above.
final Uint8List testSeed = Uint8List.fromList(const [
  0x4d, 0x45, 0x53, 0x48, 0x4c, 0x49, 0x4e, 0x4b, // "MESHLINK"
  0x2d, 0x50, 0x48, 0x41, 0x53, 0x45, 0x31, 0x2d, // "-PHASE1-"
  0x54, 0x45, 0x53, 0x54, 0x2d, 0x4b, 0x45, 0x59, // "TEST-KEY"
  0x2d, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x31, // "-0000001"
]);

/// The shared test identity: Ed25519 keypair derived from [testSeed].
///
/// The public half goes in the packet's sender_key field; per the message
/// format spec the signing key is "the keypair whose public half is
/// sender_key".
class TestIdentity {
  TestIdentity._(this.keyPair, this.publicKey);

  final SimpleKeyPair keyPair;
  final Uint8List publicKey; // 32 bytes

  static Future<TestIdentity> load() async {
    final keyPair = await Ed25519().newKeyPairFromSeed(testSeed);
    final publicKey = Uint8List.fromList((await keyPair.extractPublicKey()).bytes);
    return TestIdentity._(keyPair, publicKey);
  }
}
