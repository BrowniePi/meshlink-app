# Phase 4 Implementation Decisions (not specified in Notion)

## Dart port (meshlink-app) — decisions made 2026-07-04

The Dart implementation in `lib/` follows every wire-affecting choice below.
Where the Dart ecosystem differs from Python, these are the app-side calls:

- **Crypto library: `package:cryptography` 2.9 (kept), not sodium_libs.**
  RFC 8032 Ed25519, pure Dart, already a dependency, wire-compatible with
  PyNaCl output. libsodium only becomes necessary for the
  Ed25519→Curve25519 conversion when DM encryption arrives — migrate then.
- **BLAKE3: `blake3_dart` 1.0.0** (pure Dart, zero deps). Pinned against the
  official BLAKE3 test vectors in `test/msg_id_test.dart` and cross-checked
  against the `blake3` PyPI package the core uses — msg_ids match
  byte-for-byte. This replaces the Phase 1 truncated-SHA-256 divergence.
- **Secure key store: hand-written platform channels**
  (`ios/Runner/KeychainBridge.swift`, `android/.../KeystoreBridge.kt` behind
  `lib/identity/secure_storage.dart`), not flutter_secure_storage — explicit
  control over the Keychain access class
  (AfterFirstUnlockThisDeviceOnly, so background relaying works on a locked
  phone) and StrongBox-with-TEE-fallback on Android. Android wraps the seed
  in AES-256-GCM under a non-exportable Keystore key (Keystore cannot hold
  arbitrary secrets directly). Reinstall ⇒ new identity, by design.
- **Bloom filter: hand-rolled in `lib/core/dedup_check.dart`** (standard
  m/k sizing, double hashing over BLAKE3(msg_id)); device-local state, so
  bit-for-bit parity with pybloom-live is explicitly not required.
- **Rate-limit drop reasons differ textually from Python** (`rate limited:
  …`); drop reasons are device-local log/UI strings, not wire data. The
  shared parity fixtures (`test/fixtures/parity_vectors.json`) never
  exercise step 5, so cross-language parity tests are unaffected.

Choices made during the Python (meshlink-core) implementation that the Notion
docs leave open. **The Dart port must make the same choices** so both
implementations are wire- and behaviour-compatible.

## Identity / keygen

- **Key type: Ed25519, not raw Curve25519.** Notion says "Curve25519 keypair"
  for identity but also requires Ed25519 signatures from "the keypair whose
  public half is `sender_key`" (message-format.md §3). These are only
  simultaneously satisfiable if the long-term keypair is an Ed25519
  (crypto_sign) keypair: its public key is birationally equivalent to a
  Curve25519 key and libsodium converts it (`crypto_sign_ed25519_pk_to_curve25519`)
  for X25519 DH when DM encryption arrives. So: **generate Ed25519; the wire
  `sender_key` is the 32-byte Ed25519 public key.** Dart: use a libsodium
  binding (e.g. `sodium_libs`), same construction.
- **Library: PyNaCl 1.6.2** (libsodium bindings) — vetted, maintained, the
  canonical libsodium binding for Python. Not hand-rolled.
- **Placeholder key store:** plaintext JSON file (`private_seed` + `public_key`
  as hex) created with `0600` permissions, generated exactly once
  (fails-closed on race via `O_EXCL`). This is explicitly temporary; secure
  storage (Keychain/Keystore) is the app-side Phase 4 task.

## Pipeline checks

- **Rate limit N = 10 messages per 10 s window** (confirmed with project owner
  2026-07-04). Notion gives the window (10 s) and the ban rule (60 s ban after
  3 violations in a row, Tech Ref §8.3) but never fixes N.
- **Rate-limit semantics:** over-limit messages are dropped and do NOT consume
  window budget; a message that passes resets the consecutive-violation
  streak; while banned, messages are dropped without touching the window; the
  streak restarts at zero after a ban expires. Boundary: a message exactly
  `WINDOW_SECONDS` old still counts inside the window (evict when age
  strictly > window).
- **Rate-limiter memory bound:** per-sender state is pruned opportunistically
  (every 1,000 checks, drop senders idle > 10 min and not banned) so the
  sender map can't grow unbounded at event scale.
- **Dedup Bloom/LRU wiring:** the Bloom filter answers membership (a ~1% false
  positive drops a valid message once — spec'd as acceptable); the LRU
  (OrderedDict msg_id → seen_at) is the source of truth for what is live.
  Because Bloom filters can't delete, the filter is **rebuilt from live LRU
  entries after 1,000 evictions accumulate** (threshold = 10% of capacity).
  The filter is sized `capacity + 2 × rebuild_threshold` so lingering evicted
  entries never overflow its hard capacity between rebuilds. Boundary: an
  entry exactly at the 10-min TTL is still a duplicate (evict when age
  strictly > TTL).
- **Bloom library (Python): pybloom-live 4.0.0** — named in the Tech Ref.
  Dart: any Bloom implementation with the same capacity/error-rate semantics
  works; the filter is device-local state, never on the wire, so
  implementations don't need to match bit-for-bit.
- **Clock injection:** `DedupCache` and `RateLimiter` take a `clock` callable
  (default `time.time`) so tests control time. Mirror this in Dart.

## Signing / verification

- **Signed region excludes `ttl` and `spray_L` (offsets 68–69).** Confirmed
  with project owner 2026-07-04. message-format.md originally defined
  `signed_region = bytes[0 : 75 + payload_len]`, which includes `ttl`/
  `spray_L` — but those two bytes are rewritten by every relay hop (ttl
  decremented, spray_L binary-split) per the routing spec, and only the
  originating sender holds the private key. Under the literal signed region,
  any relay's hop mutation would invalidate the original signature, so
  verification could only ever succeed for direct (1-hop) delivery — a
  multi-hop relay would always fail signature verification at hop 2+. This
  was caught by actually running the socket-based sim harness end-to-end
  after wiring up real verification (`sim/harness.py`, 3-node line topology),
  not by any unit test, since the unit tests never modeled a genuine
  multi-hop relay path with real signatures.
  Fix: `signed_region = bytes[0:68] ‖ bytes[70:75+payload_len]` — every field
  except `ttl`, `spray_L`, and `signature` itself. A relay now only
  overwrites those two bytes (`sim/packet.py:rewrite_ttl_and_spray`) and
  forwards the packet with the original signature unchanged; it never
  re-signs, since it isn't the originating sender. **This is a deviation from
  the literal wire spec as originally written in message-format.md** (now
  updated in this repo) — the Dart port must implement the same excluded
  signed region, or Python/Dart nodes relaying for each other will disagree
  on signature validity past the first hop.
  See `pipeline/message.py:signed_region()` (single implementation used by
  both signing and verification).
- **msg_id hashing: `blake3` PyPI package 1.x** (official Rust-backed
  binding). Dart: any BLAKE3 implementation; output must match byte-for-byte
  (`BLAKE3(sender_key ‖ timestamp_be4 ‖ msg_type_byte ‖ payload)[0:16]`).
- **No hardcoded test keypair anywhere:** the test helpers generate a fresh
  `TEST_IDENTITY` at import time and sign every built packet with it. Do the
  same in the Dart test suite — never commit key material, even test keys.
- **Pipeline does not verify msg_id derivation.** Recomputing the BLAKE3
  msg_id at relays is possible per spec ("any relay can recompute") but is not
  one of the 8 documented pipeline steps, so it is deliberately not checked.

## Adversarial test script

- **Target is an in-process `RelayPipeline`, not a socket-connected node.**
  The task says "a running node or app instance"; in meshlink-core the
  pipeline IS the node's message processing, so the script injects raw
  packets straight into a fresh pipeline per attack (with an honest control
  message first to prove rejections are real). When the node/app repos
  consume meshlink-core, the same attack builders can be pointed at a
  transport.
- **Replay vs duplicate mapping:** a replay within the 5-min freshness window
  is caught at step 4 (dedup) because the timestamp is still valid; a replay
  older than 5 min is the stale-timestamp attack at step 3. Both are covered;
  "duplicate" (benign double-send) and "replay" (attacker re-injection) are
  mechanically identical at step 4.
- **A second, socket-based adversarial demo exists at `sim/adversarial_demo.py`**
  (added when testing over real sockets, not part of the Notion task card).
  It runs the same 5 attacks against a live 3-node `sim.harness` mesh
  (`SocketTransport` + `RelayPipeline` per device, real TCP connections) from
  an attacker transport that is not a registered neighbor, and asserts
  outcomes by capturing `sim.device`'s log events rather than calling
  `RelayPipeline.process()` directly. This is what actually exercises
  multi-hop relay with real signatures and is how the `ttl`/`spray_L` signed-
  region bug above was found.
