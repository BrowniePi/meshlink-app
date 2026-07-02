import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'message.dart';

/// Step 6: verify the Ed25519 signature over raw[0 : 75 + payloadLen] using
/// senderKey as the public key (per docs/message-format.md §3, the signing
/// key is "the keypair whose public half is sender_key").
///
/// The Python reference stubs this until Phase 4; Phase 1 enables it on the
/// app side so the demo can show forged messages being rejected (the
/// pipeline's verifySignatures flag preserves stub semantics for parity
/// tests). It runs last among the security checks so cheap structural and
/// rate-limit checks short-circuit before the expensive crypto (~2–5 ms on a
/// mid-range phone).
Future<String?> checkSignature(Message msg) async {
  final signedRegion =
      Uint8List.sublistView(msg.raw, 0, headerSize + msg.payloadLen);
  final valid = await Ed25519().verify(
    signedRegion,
    signature: Signature(
      msg.signature,
      publicKey: SimplePublicKey(msg.senderKey, type: KeyPairType.ed25519),
    ),
  );
  if (!valid) {
    return 'invalid signature';
  }
  return null;
}
