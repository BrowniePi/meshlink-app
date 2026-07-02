import 'dart:typed_data';

import 'attestation_check.dart';
import 'dedup_check.dart';
import 'message.dart';
import 'rate_limit_check.dart';
import 'signature_check.dart';
import 'size_check.dart';
import 'timestamp_check.dart';
import 'ttl_check.dart';

enum Outcome {
  deliver('deliver'),
  relay('relay'),
  drop('drop');

  const Outcome(this.value);
  final String value;
}

class PipelineResult {
  PipelineResult(this.outcome, {this.dropReason, this.message});

  final Outcome outcome;
  final String? dropReason;
  final Message? message;
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
      : _now = now ?? _wallClockSeconds;

  final int Function() _now;
  final bool verifySignatures;
  final DedupCache _dedup = DedupCache();

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

    // Step 5 — rate limit (stub)
    final rateReason = checkRateLimit(msg);
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

    // Step 8 — deliver or relay (stub: always deliver at Phase 1)
    return PipelineResult(Outcome.deliver, message: msg);
  }
}
