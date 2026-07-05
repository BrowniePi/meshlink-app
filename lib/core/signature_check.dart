import 'package:cryptography/cryptography.dart';

import 'message.dart';

/// Step 6: verify the Ed25519 signature over [signedRegion] (all bytes
/// except ttl/spray_L, which relays rewrite hop-by-hop) using senderKey as
/// the public key (per docs/message-format.md §3, the signing key is "the
/// keypair whose public half is sender_key").
///
/// It runs last among the security checks so cheap structural and
/// rate-limit checks short-circuit before the expensive crypto (~2–5 ms on a
/// mid-range phone).
Future<String?> checkSignature(Message msg) async {
  final valid = await Ed25519().verify(
    signedRegion(msg.raw, msg.payloadLen),
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
