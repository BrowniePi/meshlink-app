# meshlink-app

Flutter shell for MeshLink Phase 1 — the same relay protocol logic proven in
`meshlink-core` (Phase 0), now running over real BLE between two real phones.

## Layout

```
lib/
  core/       Dart implementation of the relay pipeline + message format
              (implements docs/message-format.md, the shared spec)
  transport/  Transport interface + BLE transport adapter
  ble_poc/    Throwaway BLE plugin proof-of-concept screen
  ui/         Minimal chat UI
android/      Foreground service scaffold for background BLE relay
ios/          Background BLE modes + CoreBluetooth state restoration
```

The Python reference implementation (relay pipeline, sim harness, routing)
lives in the standalone `meshlink-core` repo, not in this one — see
`docs/phase4-parity-reconciliation.md` for how the two stay in sync via
`test/fixtures/parity_vectors.json`.

## Setup

- Flutter 3.44.4 (stable) / Dart 3.12 — see `pubspec.yaml` for constraints.
- `flutter pub get`

> **If this checkout lives in an iCloud-synced folder** (e.g. Desktop with
> Desktop & Documents sync on), iOS builds fail with codesign "detritus not
> allowed" errors: the file provider tags build products with FinderInfo
> xattrs. Point the build dir at a non-synced location:
> `ln -s ~/Library/Caches/meshlink_app_build build`

### Run on iOS

```
open -a Simulator            # or plug in a real device
flutter run -d ios
```

Real BLE requires a physical device — the iOS simulator has no Bluetooth
stack. Background BLE behavior (state restoration) can only be validated on
hardware.

### Run on Android

```
flutter run -d android
```

Android 12+ prompts for Nearby Devices (BLUETOOTH_SCAN/CONNECT) permissions at
first scan. Emulators generally have no usable BLE stack; use a real device.

### Pointing at a backend (Phase 5)

Onboarding needs to reach a running `meshlink-backend` to fetch an attestation
token. `localhost`/`127.0.0.1` refers to the phone itself, not your dev
machine, so on a physical device pass the backend's LAN IP explicitly:
To get IP use
```
ipconfig getifaddr en0 || ipconfig getifaddr en1
```
And to run use
```
flutter run \
  --dart-define=MESHLINK_BACKEND_URL=http://192.168.1.14:8000 \
  --dart-define=MESHLINK_EVENT_ID=meshlink-demo
```

The phone and the machine running the backend must be on the same network.
`event_id` must match what the backend and node are configured for. See
`lib/config/backend_config.dart` for defaults (Android emulator: `10.0.2.2`;
iOS simulator: `localhost` works as-is).

### Friends & location sharing (Friendship branch)

The same two `--dart-define`s also feed the friendship directory — no extra
config. After attestation, onboarding asks for a username (`POST /account`
registers it with both device public keys), and "Add friend" resolves
usernames via `GET /directory/{username}`. So the full demo run is exactly
the command above, against the same backend and the same event id the nodes
were started with.

From the chat screen's people icon: friend request/accept (mutual consent —
accepting asks the location question separately), a per-friend "Share my
location" switch (mints/revokes a 24 h capability token; the 120 s location
beacon runs only while at least one share is on), and a friend map that polls
the node at most every 60 s and shows "updated Ns ago". Any refusal renders
as "Location not available", deliberately without saying why. Friendship
state lives on the phone (Keychain/Keystore) and mirrors to the backend
best-effort — the mesh works with the backend down. Details and invariants:
`docs/friendship-and-location.md`.

## BLE plugin

`flutter_blue_plus 2.3.10` (tested via `flutter analyze`/`flutter test` only —
**not yet exercised on physical devices**; simulators/emulators have no usable
BLE stack, so the PoC screen in `lib/ble_poc/` still needs a real-device pass
on both platforms). Known platform quirks to expect:

- Android 12+: `BLUETOOTH_SCAN` is declared `neverForLocation`; the plugin
  requests Nearby Devices permission at first scan.
- Android ≤ 11: scanning requires Location permission (legacy manifest
  entries included).
- iOS: the system Bluetooth prompt appears on first CoreBluetooth use;
  `NSBluetoothAlwaysUsageDescription` is set in Info.plist.

## Tests

```
flutter test
```

Includes cross-language parity tests that replay reference vectors generated
by the Python pipeline in `meshlink-core` (see `test/fixtures/`).

## Relay pipeline (Python reference implementation)

A pure implementation of the relay pipeline, message format, and
Spray-and-Wait logic, running entirely as a simulated network — multiple
processes on one laptop talking over local sockets standing in for BLE. No
phones, no Pi, no radios at all.

Every received message runs through an ordered sequence of checks before
being delivered or forwarded. The order is not arbitrary — it is the primary
defence against CPU and battery exhaustion attacks on mobile relay devices.

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

### Running Python tests

```
pip install pytest
pytest
```
