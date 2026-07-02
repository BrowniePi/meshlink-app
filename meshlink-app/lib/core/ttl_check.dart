import 'message.dart';

/// Step 2: drop messages whose TTL has reached zero.
/// Mirrors meshlink-core/pipeline/ttl_check.py.
String? checkTtl(Message msg) {
  if (msg.ttl == 0) {
    return 'ttl exhausted';
  }
  return null;
}
