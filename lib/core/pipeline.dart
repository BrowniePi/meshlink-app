import 'dart:typed_data';

import 'attestation_check.dart';
import 'dedup_check.dart';
import 'message.dart';
import 'rate_limit_check.dart';
import 'signature_check.dart';
import 'size_check.dart';
import 'spray_and_wait.dart';
import 'timestamp_check.dart';
import 'ttl_check.dart';

/// ttl / spray_L byte offsets in the fixed header (docs/message-format.md
/// §2). Both sit outside the signed region, so a relay may rewrite them.
const int _ttlOffset = 68;
const int _sprayOffset = 69;

enum Outcome {
  deliver('deliver'),
  relay('relay'),
  drop('drop');

  const Outcome(this.value);
  final String value;
}

class PipelineResult {
  PipelineResult(this.outcome, {this.dropReason, this.message, this.forward});

  final Outcome outcome;
  final String? dropReason;
  final Message? message;

  /// The onward copy of an accepted packet: ttl decremented, spray_L
  /// binary-split to the peer's share (Spray-and-Wait). Null when the hop
  /// budget or the copy budget is exhausted — deliver locally, spray no
  /// further. A broadcast packet is both delivered AND forwarded, which the
  /// single-valued outcome enum cannot express; hence a separate field.
  final Uint8List? forward;
}

int _wallClockSeconds() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

/// Ordered relay pipeline for MeshLink messages — Dart port of
/// meshlink-core/pipeline/pipeline.py against docs/message-format.md.
///
/// Steps run cheapest-first: a flood attacker sending forged packets hits the
/// rate-limit (step 5) before any Ed25519 work is done. Violating this order
/// opens a CPU and battery exhaustion vector on mobile relays.
///
/// [now] is injectable for deterministic tests. [verifySignatures] exists
/// because Phase 1 turns on real Ed25519 verification (step 6) on the app
/// side while the Python reference still stubs it; parity tests disable it
/// to replay Python-generated vectors unchanged.
class RelayPipeline {
  RelayPipeline({int Function()? now, this.verifySignatures = true})
      : _now = now ?? _wallClockSeconds {
    _dedup = DedupCache(clock: _now);
    _rateLimiter = RateLimiter(clock: _now);
  }

  final int Function() _now;
  final bool verifySignatures;
  late final DedupCache _dedup;
  late final RateLimiter _rateLimiter;
  final SprayBudgetTracker _sprayBudget = SprayBudgetTracker();

  Future<PipelineResult> process(Uint8List raw) async {
    // Step 1 — size (pre-parse, one comparison)
    final sizeReason = checkSize(raw);
    if (sizeReason != null) {
      return PipelineResult(Outcome.drop, dropReason: sizeReason);
    }

    // Parse header; drop if structurally malformed (e.g. payload_len mismatch)
    final Message msg;
    try {
      msg = parsePacket(raw);
    } on MalformedPacket catch (exc) {
      return PipelineResult(Outcome.drop, dropReason: 'malformed: $exc');
    }

    // Step 2 — TTL
    final ttlReason = checkTtl(msg);
    if (ttlReason != null) {
      return PipelineResult(Outcome.drop, dropReason: ttlReason);
    }

    // Step 3 — timestamp (replay prevention, before dedup state is written)
    final tsReason = checkTimestamp(msg, _now());
    if (tsReason != null) {
      return PipelineResult(Outcome.drop, dropReason: tsReason);
    }

    // Step 4 — dedup (Bloom filter / LRU in production)
    final dedupReason = _dedup.check(msg);
    if (dedupReason != null) {
      return PipelineResult(Outcome.drop, dropReason: dedupReason);
    }

    // Step 5 — rate limit (sliding window per ephem_id, before crypto)
    final rateReason = _rateLimiter.check(msg);
    if (rateReason != null) {
      return PipelineResult(Outcome.drop, dropReason: rateReason);
    }

    // Step 6 — Ed25519 signature (real at Phase 1 on the app side)
    if (verifySignatures) {
      final sigReason = await checkSignature(msg);
      if (sigReason != null) {
        return PipelineResult(Outcome.drop, dropReason: sigReason);
      }
    }

    // Step 7 — attestation token (stub; real in Phase 5)
    final attReason = checkAttestation(msg);
    if (attReason != null) {
      return PipelineResult(Outcome.drop, dropReason: attReason);
    }

    // Step 8 — deliver, and compute the onward Spray-and-Wait copy.
    // Budget contract first: a relay must never present a spray_L higher
    // than this device first observed for the msg_id (backstops dedup
    // eviction against budget inflation).
    final budgetReason = _sprayBudget.check(msg.msgId, msg.sprayL);
    if (budgetReason != null) {
      return PipelineResult(Outcome.drop, dropReason: budgetReason);
    }
    return PipelineResult(Outcome.deliver,
        message: msg, forward: _onwardCopy(raw, msg));
  }
}

/// The packet to hand peers: ttl-1, spray_L = the peer's binary-split share.
/// Null once either budget is spent — the message enters the Wait phase
/// (deliver only, no further spraying). Rewriting these two bytes is
/// signature-safe: both sit outside signedRegion.
Uint8List? _onwardCopy(Uint8List raw, Message msg) {
  final nextTtl = msg.ttl - 1;
  final forwardL = splitCopies(msg.sprayL).forward;
  if (nextTtl <= 0 || forwardL == 0) return null;
  final out = Uint8List.fromList(raw);
  out[_ttlOffset] = nextTtl;
  out[_sprayOffset] = forwardL;
  return out;
}
