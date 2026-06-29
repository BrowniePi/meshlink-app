# meshlink-app

Flutter app shell for MeshLink — the phone-side client of the MeshLink offline
mesh communications system. This is the Phase 1 scaffold: a blank Flutter app
with the folder structure later phases (BLE plugin, native transport modules,
`meshlink-core` integration) will build on. No app logic yet.

## Requirements

- Flutter 3.32.7 (stable channel)
- Xcode (for iOS) with an iOS simulator or device
- Android Studio / Android SDK (for Android) with an emulator or device

## Project structure

```
lib/
  ui/         # screens and widgets (placeholder)
  transport/  # BLE / platform-channel transport adapters (placeholder)
  core/       # meshlink-core integration glue (placeholder)
  main.dart   # app entrypoint
```

## Running

Install dependencies:

```
flutter pub get
```

Run on an iOS simulator:

```
open -a Simulator
flutter run -d ios
```

Run on an Android emulator:

```
flutter emulators --launch <emulator_id>   # or start one from Android Studio
flutter run -d android
```

List available devices/simulators/emulators:

```
flutter devices
```
