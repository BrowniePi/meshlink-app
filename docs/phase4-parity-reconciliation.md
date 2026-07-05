# Phase 4 parity reconciliation — meshlink-core (Python) ↔ meshlink-app (Dart)

Written for whoever implements Phase 4 in the Python core (canonical
`meshlink-core` repo, vendored into `meshlink-node` as
`vendor/meshlink-core`). This document says what
`test/fixtures/parity_vectors.json` needs from the Python rewrite to stay
valid, and what does *not* need to match.

## Status (updated after the meshlink-node Phase 4 landing)

`meshlink-node`'s `vendor/meshlink-core` submodule was bumped to Phase 4 tip
(`78c6785` → `24c8fae`: real Ed25519 signing/verification, dedup, rate
limit, keygen) and its `tests/fixtures/parity_vectors.json` was regenerated
against that core with real signatures. That fixture has been copied into
this repo's `test/fixtures/parity_vectors.json`, and
`test/core_parity_test.dart` has been flipped to verify signatures for
real (the `verifySignatures: false` override is removed — `true` is the
default). All Dart tests pass against it, confirming:

- `signed_region()` in the vendored core (`raw[:68] + raw[70:75+payload_len]`)
  matches Dart's `signedRegion()` exactly — real cross-language signatures
  verify correctly.
- Dedup/rate-limit parameter values match (10,000 capacity / 1% FPR / 10-min
  TTL Bloom+LRU; 10 msgs/10s window) — confirmed by code inspection of
  `vendor/meshlink-core/pipeline/{dedup_check,rate_limit_check}.py`, though
  no shared vector currently exercises rate-limiting (see below, this is
  intentional).
- `"duplicate: msg_id already seen"` matches exactly, as it did before.

**Open item — signature drop-reason string mismatch:** the vendored core's
`signature_check.py` returns `"signature invalid: Ed25519 verification
failed"`; Dart's `signature_check.dart` returns `"invalid signature"`. These
don't match. It's not currently blocking anything because no shared vector
in the regenerated fixture exercises a rejected signature (`valid_text_deliver`
and `duplicate_msg_id` are the only signed vectors, and both verify). If a
`forged_signature` vector is added later (recommended below), one side needs
to change its string first — flag this for a decision before adding that
vector, don't let it land as a silent mismatch.

## Must match exactly (wire/verification-affecting)

1. **`signed_region()`** — the important one. Must exclude `ttl` (offset
   68) and `spray_L` (offset 69):
   `raw[0:68] ‖ raw[70 : 75 + payload_len]`.
   Confirmed with the project owner 2026-07-04 (see `PHASE4_CHANGES.md`).
   Those two bytes are rewritten by every relay hop (ttl decremented,
   spray_L binary-split), and only the originating sender holds the
   private key — so signing over the literal spec range would make
   verification succeed only for direct (1-hop) delivery. If Python signs
   over the old literal range while Dart excludes ttl/spray_L (or vice
   versa), a Python node relaying for a Dart node — or the reverse — will
   fail signature verification at hop 2+. This is exactly the bug
   `PHASE4_CHANGES.md` describes being caught by the socket-based sim
   harness, not by unit tests, because no unit test modeled a genuine
   multi-hop relay path with real signatures. Implement Dart's
   `signedRegion()` (`lib/core/message.dart`) as the reference.

2. **Rate-limit and dedup parameters** — confirmed values, not free
   choices:
   - Rate limit: N = 10 messages per 10 s window; 3 consecutive violations
     → 60 s ban; banned messages don't touch the window; a pass resets the
     violation streak; a message exactly `WINDOW_SECONDS` old still counts
     inside the window (evict when age strictly `>` window).
   - Dedup: Bloom filter + LRU, ~1% FPR, 10,000 capacity, 10-min TTL,
     rebuild the Bloom filter after 1,000 evictions accumulate (10% of
     capacity), filter sized `capacity + 2 × rebuild_threshold`. An entry
     exactly at the 10-min TTL is still a duplicate (evict when age
     strictly `>` TTL).

3. **`"duplicate: msg_id already seen"`** — the dedup drop-reason string.
   Dart already uses this exact string and the existing `duplicate_msg_id`
   vector already asserts it. Keep it verbatim through the Bloom/LRU
   rewrite.

4. **`"invalid signature"`** — recommended exact string for the
   forged-signature drop reason, so a shared vector can assert it
   character-for-character. Dart's `signature_check.dart` already returns
   this.

## Does NOT need to match

- **msg_id realism.** Neither pipeline verifies msg_id derivation — it's
  an opaque dedup key on both sides (documented in both `message.dart` and
  `message.py`). The generator can keep hardcoding arbitrary `msg_id`
  bytes for pipeline-parity vectors; no need to route it through BLAKE3.

- **Rate-limit drop-reason wording.** Dart's text (`"rate limited: …"`) is
  local log/UI text, not wire data — see `PHASE4_CHANGES.md`. Recommend
  **not** adding a rate-limit vector to the shared fixture at all; test
  that check's wording independently in each language's own unit tests.

- **No shared key material.** Ed25519 verification is self-contained per
  packet: signature + sender_key (embedded in the packet) + signed bytes.
  The generator can sign with its own freshly generated, never-committed
  Ed25519 keypair — Dart doesn't need that private key or even need to
  know it exists. Nothing needs to be coordinated across repos here.

## Steps for the Python-side rewrite

1. Add `signed_region(raw, payload_len)` to `pipeline/message.py` with the
   exact byte range above.
2. Implement real `signature_check.py` (PyNaCl), `dedup_check.py`
   (pybloom-live + LRU), `rate_limit_check.py` per the confirmed
   parameters above.
3. Update `tests/helpers.build_packet` (or the generator directly) to
   actually sign packets: generate an ephemeral test keypair at generation
   time, sign over `signed_region()`, embed the real public key as
   `sender_key`.
4. Regenerate `test/fixtures/parity_vectors.json`
   (`python tool/gen_parity_vectors.py > test/fixtures/parity_vectors.json`).
   The existing malformed-packet cases (`too_small`, `too_large`,
   `length_mismatch`) don't need real signatures — they're rejected
   pre-signature-check regardless.
5. Optionally add:
   - `forged_signature` — sign honestly, then corrupt one byte; assert
     `outcome: "drop"`, `drop_reason: "invalid signature"`.
   - `relay_ttl_spray_rewrite` — sign, then flip the `ttl`/`spray_L` bytes
     in the fixture entry before recording it; assert `outcome: "deliver"`.
     This is the multi-hop case the signed-region bug hid from unit tests,
     so it's worth locking in as a regression vector.

## Remaining follow-ups

1. **Decide the signature drop-reason string** (see "Open item" above)
   before a `forged_signature` vector is added to the shared fixture.
2. **`relay_ttl_spray_rewrite` vector** — still not present. Worth adding:
   sign a packet, flip the `ttl`/`spray_L` bytes as a relay hop would,
   assert `outcome: "deliver"`. This is the multi-hop case the old
   signed-region bug hid from unit tests, so it's the highest-value vector
   left to add.
3. **Resolved — this repo's stale merged-in Python core snapshot was
   deleted.** `pipeline/`, `routing/`, `sim/`, `tests/`, `tool/`, the
   root-level `transport/` (Python), and `pyproject.toml` were a separate
   copy of meshlink-core merged in during "Merge meshlink-core Phase1 into
   meshlink-app," still stuck at Phase 0/1 (no `signed_region()`, stub
   signature/dedup/rate-limit) and disconnected from the canonical
   `meshlink-core` repo meshlink-node vendors. `tool/gen_parity_vectors.py`
   specifically was confirmed broken (`ModuleNotFoundError` on run, `sys.path`
   math pointed one directory too high) rather than merely stale. All of it
   has been removed via `git rm`; this app repo now has no local Python
   pipeline implementation at all — `test/fixtures/parity_vectors.json` is
   the only artifact shared with meshlink-core, produced externally and
   copied in (see "Status" above). `README.md` updated to match.
