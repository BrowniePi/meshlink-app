# Phase 1 milestone demo — two-phone BLE messaging

**Status: NOT YET RUN on physical hardware.** Everything below the runbook
line is what has been verified so far; the two-phone demo itself requires two
real phones (the simulator/emulator has no BLE stack) and must be performed
by a person with the devices in hand. Do not check the tracker's demo task
off until the runbook has been executed and evidence is committed here.

## Verified so far (software, no radio)

- Full test suite green: cross-language parity vectors (Dart pipeline ==
  Python reference, byte-for-byte), sign → deliver round trip, tampered
  message rejected with `invalid signature`, replay rejected with
  `duplicate: msg_id already seen`, chat-screen widget tests over a fake
  transport (`flutter test`, 8 tests).
- App builds and launches on the iOS simulator; chat UI renders
  (`phase1-ios-simulator-launch.png`). Android build not yet attempted — no
  Android SDK on the build machine.

## Runbook (requires two real phones)

Ideally one iPhone + one Android phone; two of one platform also proves the
milestone.

1. `flutter run --release` on both phones. Accept the Bluetooth (and on
   Android, Nearby Devices + notification) prompts.
2. Wait ≤ 30 s for the scan/advertise loops to link the phones (each phone
   runs both BLE roles; either can initiate).
3. Phone A: type a message, send. **Expect:** it appears on Phone B within a
   few seconds, correct content, no corruption.
4. Phone B → Phone A: same in reverse.
5. Forged-message check (software-verified already, now over radio): from a
   debug hook or test build, send a packet with a flipped payload byte.
   **Expect:** receiver's "last dropped" line shows `invalid signature`; the
   message never renders.
6. Replay check: resend an already-delivered packet. **Expect:** `duplicate:
   msg_id already seen`.
7. Background Phone B (do not kill): Android must keep the relay notification
   visible and continue receiving; iOS must continue receiving under the
   bluetooth background modes.
8. Capture a screen recording or photos of both phones for steps 3–6 and
   commit them to this folder; update this file's status line.
9. Log any issues found as new tracker tasks — do not work around them
   silently.

## Evidence

| Item | File |
|------|------|
| iOS simulator launch (app shell + chat UI render) | `phase1-ios-simulator-launch.png` |
| Two-phone exchange recording | _pending hardware run_ |
| Forged/replay rejection capture | _pending hardware run_ |
