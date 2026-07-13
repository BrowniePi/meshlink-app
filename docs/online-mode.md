# Online mode — app half

Added 2026-07. The app now runs every friendship feature over the hosted
backend whenever it has internet — one unified UI, automatic switching, a
visible indicator. Since the online-messaging rework, friend requests and
DMs go out on the backend AND the mesh **simultaneously** (the receiving
device may be mesh-reachable but offline, or the reverse); the receiver
drops the second copy by ciphertext hash. Location reads stay
online-primary with the mesh as fallback. Backend half:
`Meshlink-backend/docs/online-mode.md`; notifications:
`docs/notifications.md`.

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

## How each flow routes

Messaging flows (requests, DMs) use BOTH paths at once; location flows are
online-primary with the mesh as fallback.

| Flow | Online path | Mesh path |
|---|---|---|
| Friend request | `POST /online/friend-requests`; server holds it until the friend polls (fix #1 — works across the planet, no BLE contact needed) | Sprayed FRIEND_REQUEST simultaneously, re-sent until answered; the duplicate recvRequest is a no-op |
| Request seen / answered | Poll + WS events drive the same `friend_state` machine (`recvRequest`/`recvAccept`/`recvDecline`); keys pinned from the directory (TOFU) | Sealed mesh payloads carry the keys |
| DM | The sealed body is encoded ONCE and handed to both transports: backend relay (deleted server-side on ack) and spray-and-wait — `DmVia.both` when both took it. The receiver dedups on the ciphertext SHA-256 (`FriendEntry.markDmSeen`, persisted), so the copy arriving second is dropped | Same send; `DmVia.mesh` when only the spray took it |
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
- Unanswered requests keep re-spraying over the mesh even when the server
  already holds them (the server only reaches a friend who comes online;
  the spray reaches one in radio range), and both paths converge on the
  same state machine, so a request can go out offline and be answered
  online or vice versa.

## Tests

`test/friend_service_online_test.dart` — two phones over a fake online
backend: request/accept/decline, ciphertext-only relay (asserts the server
never sees plaintext), mesh-only send when the relay rejects, simultaneous
dual-transport delivery landing exactly once (both arrival orders, plus
across an app relaunch — the dedup keys persist), blob upload/open/revoke,
token-via-relay, and the mesh-only-request not-misread-as-declined edge.
