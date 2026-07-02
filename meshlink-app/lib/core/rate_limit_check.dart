import 'message.dart';

/// Step 5: rate-limit per sender. Stub — always passes at Phase 1, exactly
/// like meshlink-core/pipeline/rate_limit_check.py.
///
/// Production implementation: sliding window counter keyed on ephem_id;
/// drop if sender exceeds N messages per 10-second window. Must run before
/// signature verification (step 6) so a flood attacker cannot force Ed25519
/// work before being throttled.
String? checkRateLimit(Message msg) {
  return null;
}
