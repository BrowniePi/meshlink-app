# iOS background BLE configuration

What was configured for Phase 1 and how to verify it manually.

## Configured

- **Info.plist**
  - `UIBackgroundModes`: `bluetooth-central`, `bluetooth-peripheral`
  - `NSBluetoothAlwaysUsageDescription` (required for any CoreBluetooth use)
- **`Runner/BleManager.swift`** — native peripheral (GATT server): publishes
  the MeshLink service, advertises it, receives packet writes from remote
  centrals, and notifies outbound packets to subscribers. Created with
  `CBPeripheralManagerOptionRestoreIdentifierKey` (`meshlink.peripheral`) and
  implements `willRestoreState`, so iOS can relaunch the app to handle BLE
  events after it is killed. Bridged to Dart over the
  `meshlink/ble_peripheral` method channel.
- **Central role** — lives in Dart (flutter_blue_plus). The transport enables
  the plugin's state restoration (`FlutterBluePlus.setOptions(restoreState:
  true)`), which sets `CBCentralManagerOptionRestoreIdentifierKey` on the
  plugin's `CBCentralManager`.

## Manual verification (real device only)

Background BLE does not work on the simulator — it has no Bluetooth stack.

1. Run the app on a real iPhone; confirm the Bluetooth permission prompt
   appears and advertising starts (verify with a scanner app such as
   LightBlue on a second device: look for the service UUID
   `4D455348-4C49-4E4B-0001-000000000001`).
2. Background the app: advertising continues (iOS moves it to the overflow
   area — the service UUID no longer appears in the advertisement but the
   device remains connectable by apps scanning for that UUID).
3. Kill the app (swipe up in the app switcher — note: after a *manual* kill
   iOS does not relaunch; test restoration by letting iOS jetsam the app
   instead, e.g. open several heavy apps), then trigger a BLE event from the
   second device and confirm iOS relaunches the app (`willRestoreState`
   fires; the `onRestored` event reaches the Dart layer).

**Status: not yet performed — requires physical iPhone hardware.**
