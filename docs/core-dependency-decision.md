# Decision: how meshlink-app consumes meshlink-core

**Status:** decided — re-implementation against the shared spec, not a direct
import.

## Decision

`meshlink-core` is Python; `meshlink-app` is Dart/Flutter. A direct package
import is not possible across that language boundary, so per the task's
explicit cross-language provision, `meshlink-app` **re-implements the relay
pipeline in Dart against the single shared spec**
(`meshlink-core/docs/message-format.md`), and parity with the Python
reference implementation is enforced by test vectors generated from the
Python pipeline itself.

Alternatives considered:

- **Embed Python on-device** (e.g. Chaquopy/Python-Apple-support): heavy,
  platform-fragile, and still needs a Dart bridge for every call — rejected.
- **FFI to a compiled core** (rewrite core in Rust/C): right long-term answer
  if drift becomes a problem, but far beyond Phase 1 scope — rejected for now.

## How parity is enforced (the "import" equivalent)

1. `tool/gen_parity_vectors.py` runs packets through the **Python**
   `RelayPipeline` with a frozen clock and records raw bytes, outcome,
   exact drop-reason string, and every parsed field.
2. `test/fixtures/parity_vectors.json` is the committed output, pinned to the
   meshlink-core commit noted below.
3. `test/core_parity_test.dart` replays those vectors through the **Dart**
   pipeline and asserts identical results, string-for-string.

Regenerate vectors whenever the Python pipeline changes:

```
cd meshlink-app
python tool/gen_parity_vectors.py > test/fixtures/parity_vectors.json
```

**Pinned reference:** meshlink-core @ `78c6785` (Phase 0 complete).

## Cross-reference checklist — Phase 0 pipeline steps

| # | Python (meshlink-core/pipeline/) | Dart (lib/core/) | Parity vector |
|---|----------------------------------|------------------|---------------|
| 1 | `size_check.py` | `size_check.dart` | `too_small`, `too_large` |
| — | `message.py` `parse_packet` | `message.dart` `parsePacket` | `valid_text_deliver`, `length_mismatch` |
| 2 | `ttl_check.py` | `ttl_check.dart` | `ttl_exhausted` |
| 3 | `timestamp_check.py` | `timestamp_check.dart` | `timestamp_too_old`, `timestamp_future` |
| 4 | `dedup_check.py` | `dedup_check.dart` | `duplicate_msg_id` |
| 5 | `rate_limit_check.py` (stub) | `rate_limit_check.dart` (stub) | n/a (always passes) |
| 6 | `signature_check.py` (stub) | `signature_check.dart` | vectors run with verification off; Phase 1 enables real Ed25519 on the app side (see test-keypair task) |
| 7 | `attestation_check.py` (stub) | `attestation_check.dart` (stub) | n/a (always passes) |
| 8 | deliver/relay (always deliver) | `pipeline.dart` step 8 | `valid_text_deliver` |

The `Transport` contract (`meshlink-core/transport/base.py`) is mirrored in
`lib/transport/transport.dart`; the BLE adapter task implements it.

## Known intentional divergence

- **Step 6:** Phase 1's demo criteria require rejecting forged messages, so
  the Dart pipeline performs real Ed25519 verification while the Python
  reference still stubs it (Python gets real crypto in Phase 4). The
  `verifySignatures` flag preserves stub semantics for parity testing.
- **msg_id derivation:** the spec (§3) calls for BLAKE3[0:16]; the app uses
  SHA-256[0:16] pending a vetted Dart BLAKE3 implementation (see the TODO in
  `lib/core/message_factory.dart`). Harmless at Phase 1 — msg_id is only a
  dedup key and nothing recomputes it — but must be reconciled before any
  implementation starts verifying msg_ids.
