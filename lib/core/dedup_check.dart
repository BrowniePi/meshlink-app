import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:blake3_dart/blake3_dart.dart';

import 'message.dart';

int _wallClockSeconds() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

/// Fixed-parameter Bloom filter. Device-local state, never on the wire, so
/// it need not match the Python core (pybloom-live) bit-for-bit — only the
/// capacity/error-rate semantics (Tech Ref: ~1% FPR at 10,000 entries).
class BloomFilter {
  BloomFilter({required int capacity, required double errorRate})
      : _mBits = _bitsFor(capacity, errorRate),
        _k = _hashesFor(capacity, _bitsFor(capacity, errorRate)) {
    _bits = Uint8List((_mBits + 7) ~/ 8);
  }

  final int _mBits;
  final int _k;
  late final Uint8List _bits;

  // m = -n·ln(p) / (ln 2)², k = (m/n)·ln 2 — standard optimal sizing.
  static int _bitsFor(int n, double p) =>
      (-n * math.log(p) / (_ln2 * _ln2)).ceil();
  static int _hashesFor(int n, int m) {
    final k = (m / n * _ln2).round();
    return k < 1 ? 1 : k;
  }

  static const double _ln2 = 0.6931471805599453;

  void add(Uint8List key) {
    for (final i in _indices(key)) {
      _bits[i >> 3] |= 1 << (i & 7);
    }
  }

  bool mightContain(Uint8List key) {
    for (final i in _indices(key)) {
      if (_bits[i >> 3] & (1 << (i & 7)) == 0) return false;
    }
    return true;
  }

  /// k bit indices via double hashing over BLAKE3(key): index_i = h1 + i·h2.
  Iterable<int> _indices(Uint8List key) sync* {
    final h = blake3(key, 16);
    final bd = ByteData.sublistView(h);
    // Mask to 63 bits so the modulo below stays non-negative.
    final h1 = bd.getUint64(0) & 0x7fffffffffffffff;
    final h2 = (bd.getUint64(8) & 0x7fffffffffffffff) | 1; // odd, never 0
    for (var i = 0; i < _k; i++) {
      yield ((h1 + i * h2) & 0x7fffffffffffffff) % _mBits;
    }
  }
}

/// Step 4: drop messages whose msg_id has already been seen.
///
/// Phase 4 port of meshlink-core/pipeline/dedup_check.py: a Bloom filter
/// answers membership (a ~1% false positive drops a valid message once —
/// spec'd as acceptable); an LRU map (msg_id → seen_at) is the source of
/// truth for what is live. Bloom filters can't delete, so the filter is
/// rebuilt from live LRU entries once [_rebuildThreshold] evictions
/// accumulate (10% of capacity); it is sized capacity + 2×threshold so
/// lingering evicted entries never overflow it between rebuilds.
///
/// Boundary: an entry exactly at the 10-min TTL is still a duplicate
/// (evict when age strictly > TTL). [clock] is injectable for tests.
class DedupCache {
  DedupCache({
    this.capacity = 10000,
    this.errorRate = 0.01,
    this.ttlSeconds = 600,
    int Function()? clock,
  })  : _clock = clock ?? _wallClockSeconds,
        _rebuildThreshold = capacity ~/ 10 {
    _bloom = _newBloom();
  }

  final int capacity;
  final double errorRate;
  final int ttlSeconds;
  final int Function() _clock;
  final int _rebuildThreshold;

  late BloomFilter _bloom;
  // msg_id hex → seen_at, insertion-ordered (oldest first) = LRU by insert.
  final LinkedHashMap<String, int> _live = LinkedHashMap<String, int>();
  int _evictionsSinceRebuild = 0;

  BloomFilter _newBloom() => BloomFilter(
        capacity: capacity + 2 * _rebuildThreshold,
        errorRate: errorRate,
      );

  String? check(Message msg) {
    final now = _clock();
    _evictExpired(now);

    if (_bloom.mightContain(msg.msgId)) {
      return 'duplicate: msg_id already seen';
    }

    _live[_hex(msg.msgId)] = now;
    _bloom.add(msg.msgId);
    if (_live.length > capacity) {
      _live.remove(_live.keys.first);
      _evictionsSinceRebuild++;
    }
    _maybeRebuild();
    return null;
  }

  void _evictExpired(int now) {
    // Insertion order == timestamp order, so stop at the first live entry.
    while (_live.isNotEmpty) {
      final oldest = _live.keys.first;
      if (now - _live[oldest]! > ttlSeconds) {
        _live.remove(oldest);
        _evictionsSinceRebuild++;
      } else {
        break;
      }
    }
    _maybeRebuild();
  }

  void _maybeRebuild() {
    if (_evictionsSinceRebuild < _rebuildThreshold) return;
    _bloom = _newBloom();
    for (final key in _live.keys) {
      _bloom.add(_unhex(key));
    }
    _evictionsSinceRebuild = 0;
  }
}

String _hex(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Uint8List _unhex(String hex) {
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}
