# Friendship & node-served location — app changes (Friendship branch)

App side of the capability-token hybrid design (Notion Phase 5 → Friends /
Mutual Consent / Node-Served Location). Counterpart notes:
`MeshLink-core/docs/friendship-and-location.md` (protocol),
`MeshLink-Node/docs/node-served-location.md` (node),
`Meshlink-backend/docs/friendship-directory.md` (directory).

## The four flows

1. **Create account** — `onboarding/account_screen.dart`, inserted after
   attestation onboarding and before the WiFi step. Registers a username plus
   both device public keys (`POST /account`); username-taken retries inline.
2. **Friend request / accept** — `ui/friends_screen.dart`. Requests are
   surfaced for an explicit Accept/Decline, never auto-accepted; the accept
   dialog asks the location question separately ("Accept" vs "Accept + share
   location").
3. **Share / stop sharing** — per-friend switch on the friends screen. On
   mints a 24 h capability token signed with our long-term Ed25519 key and
   delivers it via a FRIEND_ACCEPT follow-up; off sends LOCATION_REVOKE.
   Tokens auto-refresh hourly within 2 h of expiry while the switch is on.
4. **See a friend on the map** — `ui/friend_map_screen.dart`. Polls
   `LOCATION_QUERY` at most every 60 s, draws the pin on an offline venue
   grid (a tile map needs internet the event doesn't have), and shows
   `beacon_age_s` as "updated Ns ago". Any refusal — never granted, revoked,
   expired, rate-limited, unknown user — renders identically as
   "Location not available".

## New library code

| File | What |
| --- | --- |
| `lib/core/capability_token.dart` | 98-byte token mint/parse/verify — byte-identical to core `capability/token.py` (parity-tested) |
| `lib/core/sealed.dart` | Sealed envelope (ephemeral X25519 → BLAKE3 KDF → ChaCha20-Poly1305); byte-compatible with core `crypto/sealed.py` |
| `lib/core/friend_wire.dart` | FRIEND_REQUEST/ACCEPT/DECLINE, LOCATION_QUERY/RESPONSE/REVOKE, beacon codecs + 8-byte recipient hints |
| `lib/friends/friend_state.dart` | Pure state machine mirroring core `friends/state.py` (same transition table, replayed in tests) |
| `lib/friends/friend_service.dart` | Orchestration: demux from the chat pipeline, beacon loop, token refresh, backend mirror |
| `lib/friends/friend_store.dart` | Friend/consent persistence — one JSON blob in the existing Keychain/Keystore storage |
| `lib/identity/encryption_identity.dart` | X25519 encryption keypair beside the Ed25519 signing identity |

## Security invariants, as they land in the app

1. **Node never fabricates consent** — the only thing that makes a
   LOCATION_QUERY answerable is a token signed by the *target's* long-term
   key; the app mints it (`issueToken`) exclusively from the local switch.
2. **Stable identity never touches the BLE air interface** — nothing here
   changed advertising; friend payloads ride *inside* signed envelopes as
   sealed ciphertext, and the on-air identifier remains the rotating
   `ephemeral_id`.
3. **Latest coordinate only** — the beacon carries one coordinate; the
   LOCATION_RESPONSE body is a fixed 16-byte struct with physically no room
   for history (asserted in `friend_wire_test.dart`).
4. **Responses encrypted to the requester** — `decodeLocationResponse` can
   only be opened with our X25519 private key (invariant-4 tests in
   `sealed_test.dart` / `friend_wire_test.dart`).
5. **Consent revocable and expiring** — 24 h default expiry, hourly
   auto-refresh while sharing is on, LOCATION_REVOKE on off; a revoke from
   the friend clears our stored grant so the map stops asking.

## Decisions

- **Separate X25519 keypair** rather than converting the Ed25519 key:
  package:cryptography has no birational conversion, so both public keys are
  registered at `POST /account`. Same secure storage, no second key store.
- **Custom sealed envelope** rather than libsodium `crypto_box_seal`:
  XSalsa20 isn't available in pure Dart; construction mirrors it with
  ChaCha20-Poly1305 (parity-tested against the Python side).
- **Token refresh rides FRIEND_ACCEPT** — `recvAccept` while already friends
  is an explicit idempotent edge in both state machines.
- **One pipeline instance app-wide** (`main.dart`): chat and friend service
  share dedup/rate-limit state so our own echoed packets are dropped once.
- **TOFU key pinning**: keys are pinned at first resolve (outbound request)
  or first inbound request; a FRIEND_ACCEPT with different keys is dropped
  as impersonation, never treated as a key update.
- **Beacon only while sharing**: the 120 s signed LOCATION beacon runs only
  while ≥1 friend-share is active. The separate unsigned MLPP1 telemetry
  pong (Phase 7, aggregated ops crowd map) is untouched and deliberately
  distinct.
- **Offline venue-grid map**: no tile dependency; an honest stand-in given
  the event has no internet. Swappable for real tiles later.

## Tests

- `friend_state_test.dart` — full legal-edge table + exhaustive illegal-edge
  complement (mirrors the Python table).
- `capability_token_test.dart` — round-trip, per-byte tamper, expiry window,
  stolen-token/wrong-grantee, forged issuer, wrong scope.
- `sealed_test.dart`, `friend_wire_test.dart` — codecs, invariants 3/4,
  §2 payload-size bounds for every new message type.
- `friend_service_test.dart` — two phones over a loopback mesh (full
  pipeline in between): all four flows end-to-end, rate limiting, restart
  persistence.
- `friendship_parity_test.dart` — replays
  `test/fixtures/friendship_parity_vectors.json` from
  `tool/gen_friendship_vectors.py` (Python reference): byte-identical token
  minting, Python-sealed envelopes opened in Dart.
- `friends_flow_widget_test.dart` — widget tests for the four flows.

## Out of scope (per spec)

Group location, DMs, location history, any password system, and the
node-blind "Model B" (future high-privacy mode — would move matching into
sealed blobs so even the node can't see who asks about whom).
