# meshlink-app

Flutter shell for MeshLink Phase 1 — the same relay protocol logic proven in
`meshlink-core` (Phase 0), now running over real BLE between two real phones.

> **Repo layout note:** the Master Task Tracker calls for `meshlink-app` to be
> its own repository. Per project direction it currently lives as a
> subdirectory of `meshlink-core` on the `Phase1` branch; extracting it into a
> standalone repo later is a pure history-copy move — nothing in here imports
> from the Python packages by path.

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
