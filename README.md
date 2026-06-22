# meshlink-core
A pure implementation of the relay pipeline, message format, and Spray-and-Wait logic, running entirely as a simulated network — multiple processes on one laptop talking over local sockets standing in for BLE. No phones, no Pi, no radios at all.

## Relay pipeline

Every received message runs through an ordered sequence of checks before being delivered or forwarded. The order is not arbitrary — it is the primary defence against CPU and battery exhaustion attacks on mobile relay devices.

```
Step 1  size check        raw bytes outside [131, 460]      — one comparison, pre-parse
Step 2  TTL check         ttl == 0                          — one field read
Step 3  timestamp check   > 5 min old or > 30 s in future  — two comparisons, replay prevention
Step 4  dedup             msg_id already seen               — Bloom filter lookup
Step 5  rate limit        sender exceeds N/10 s             — sliding window counter  [stub]
Step 6  signature verify  Ed25519 invalid                   — libsodium, ~50 µs/Pi    [stub]
Step 7  attestation       no valid ticket token             — JWT verify               [stub]
Step 8  deliver or relay  —
```

**Why this order matters:** Ed25519 verification (step 6) costs ~50 µs on a Pi 4 and ~2–5 ms on a mid-range phone. An attacker flooding the network with forged packets would force that cost on every relay device if signature verification ran early. By placing cheap structural checks (steps 1–4) and rate limiting (step 5) first, a flood is stopped before any cryptographic work is done. Steps marked `[stub]` always pass at Phase 0 and are replaced with real implementations in later phases (rate-limit in Phase 0, signature in Phase 4, attestation in Phase 5).

## Running tests

```
pip install pytest
pytest
```
