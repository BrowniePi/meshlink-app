import 'dart:convert';

import 'message.dart';

/// Step 4: drop messages whose msg_id has already been seen.
///
/// Phase 1 port of meshlink-core/pipeline/dedup_check.py — an in-memory set
/// with no TTL eviction. Production implementation uses a Bloom filter backed
/// by an LRU cache with 10-min TTL.
class DedupCache {
  final Set<String> _seen = <String>{};

  String? check(Message msg) {
    final key = base64.encode(msg.msgId);
    if (_seen.contains(key)) {
      return 'duplicate: msg_id already seen';
    }
    _seen.add(key);
    return null;
  }
}
