# Online mode — app half

Added 2026-07. The app now runs every friendship feature over the hosted
backend whenever it has internet, with the mesh as the seamless fallback —
one unified UI, automatic switching, a visible indicator. Backend half:
`Meshlink-backend/docs/online-mode.md`.

## What "online" means

`OnlineService` (`lib/online/online_service.dart`) keeps a WebSocket to the
backend (`/online/ws`, authed with the account access JWT, reconnect with
exponential backoff). **The socket being up IS the mode switch** — venue
WiFi with no internet counts as offline, LTE counts as online. No
connectivity plugin; the thing that matters is measured directly. While
connected, a 45 s fallback poll drains the message inbox and re-syncs friend
requests; pushes only shorten latency (delivery guarantees live in the
polling endpoints + explicit ack).

The indicator: the wordmark status line reads `Online · via <node> · N
peers` vs `Mesh only · …` / `Direct radio only`, and each DM bubble carries
a small cloud icon when it travelled through the backend (no icon = mesh).

## How each flow routes (online primary → mesh fallback)

| Flow | Online path | Fallback |
|---|---|---|
| Friend request | `POST /online/friend-requests`; server holds it until the friend polls (fix #1 — works across the planet, no BLE contact needed) | Sprayed FRIEND_REQUEST, re-sent until answered |
| Request seen / answered | Poll + WS events drive the same `friend_state` machine (`recvRequest`/`recvAccept`/`recvDecline`); keys pinned from the directory (TOFU) | Sealed mesh payloads carry the keys |
| DM | Sealed body relayed via backend (`DmVia.online`), deleted server-side on ack | Spray-and-wait (`DmVia.mesh`) |
| Location share | Every beacon tick uploads one sealed blob per sharing-enabled friend (latest-only server-side); toggling off re-uploads without them (empty set = revoke all) | 120 s signed beacon to the node + capability token |
| Location view | `GET /online/location/{friend}` — blob existence is the consent; age derives from the server's `updated_at`; feeds the same freshest-wins cache | LOCATION_QUERY spray with their token |
| Capability token delivery | The sealed FRIEND_ACCEPT payload rides the online relay too, so a token granted while apart still enables the mesh path later | FRIEND_ACCEPT spray |

`FriendService` stays the single orchestrator (it implements
`OnlineHandler`); mesh-only tests are untouched because the online channel
attaches post-construction like `presentAttestation`.

## Security invariants, online edition

1. **Server never reads content** — DMs and coordinates are sealed to the
   recipient's X25519 key before upload; the backend stores/relays bytes.
2. **TOFU pinning unchanged** — online-arriving keys (directory resolve,
   sealed accept payloads) never overwrite pinned keys; mismatch = drop.
3. **Mutual consent gates everything** — server enforces FRIENDS state for
   relay; the phone re-checks on receipt (a non-friend's DM is dropped even
   if the server misbehaves).
4. **Latest coordinate only** — the blob is one sealed 24-byte struct; the
   server table has one row per (owner, friend), no history.
5. **Uniform refusals** — "not sharing", "unknown user", and "no blob" are
   one identical 404 / "Location not available".
6. **Sender authenticity online is the account session** (server-attested
   `from_user`), weaker than the mesh's Ed25519 envelope; accepted
   deliberately — the account IS the identity authority online.

## Mesh-only semantics kept honest

- `FriendEntry.requestSentOnline` distinguishes "the server had my request
  and it vanished from pending" (a real answer — accept or decline) from "I
  only ever sprayed it" (never misread as declined; re-POSTed online on the
  next retry cycle).
- Online-delivered requests are not re-sprayed; mesh-pending ones are, and
  both paths converge on the same state machine, so a request can go out
  offline and be answered online or vice versa.

## Tests

`test/friend_service_online_test.dart` — two phones over a fake online
backend: request/accept/decline, ciphertext-only relay (asserts the server
never sees plaintext), mesh fallback on relay failure, blob
upload/open/revoke, token-via-relay, and the mesh-only-request
not-misread-as-declined edge.
