import 'message.dart';

/// Step 6: verify Ed25519 signature. Stub — always passes, matching
/// meshlink-core/pipeline/signature_check.py at Phase 0/1.
///
/// The test-keypair task replaces this with a real Ed25519 verify of
/// msg.signature over msg.raw[0 : 75 + payloadLen] using msg.senderKey.
/// It runs last among the security checks so cheap structural and rate-limit
/// checks can short-circuit before the expensive crypto (~2–5 ms on a
/// mid-range phone).
Future<String?> checkSignature(Message msg) async {
  return null;
}
