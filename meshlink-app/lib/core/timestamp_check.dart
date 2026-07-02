import 'message.dart';

const int _maxAgeSeconds = 300; // 5 minutes — replay attack window
const int _maxFutureSeconds = 30; // clock-skew tolerance

/// Step 3: drop messages too old or too far in the future (replay prevention).
/// Mirrors meshlink-core/pipeline/timestamp_check.py. [now] is injected so
/// the pipeline can be driven deterministically in parity tests.
String? checkTimestamp(Message msg, int now) {
  final age = now - msg.timestamp;
  if (age > _maxAgeSeconds) {
    return 'timestamp too old: ${age}s ago (max ${_maxAgeSeconds}s)';
  }
  if (age < -_maxFutureSeconds) {
    return 'timestamp too far in future: ${-age}s ahead (max ${_maxFutureSeconds}s)';
  }
  return null;
}
