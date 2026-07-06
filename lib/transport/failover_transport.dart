import 'package:flutter/foundation.dart';

import '../debug/debug_log.dart' as dbg;
import 'transport.dart';
import 'wifi_transport.dart';

/// BLE always-on + WiFi opt-in, presented to the relay pipeline as the one
/// `Transport` it has always spoken to (zero meshlink-core changes — the
/// Phase 0 abstraction test).
///
/// Selection follows the WiFi Mesh Add-On's fallback design rule:
/// [listPeers] returns the WiFi node while that connection is healthy and
/// BLE peers otherwise, so new sends prefer WiFi and fall back to BLE
/// transparently. Receives are accepted from both at all times, and
/// [send] routes by peer id ("wifi:…" → WiFi), so in-flight messages
/// complete over whichever transport they started on when the toggle flips
/// mid-session.
///
/// BLE runs underneath permanently; [enableWifi]/[disableWifi] only start
/// and stop the WiFi side. Disabling reverts to exactly the BLE-only
/// behavior — same pipeline, same routing, no other side effects.
class FailoverTransport implements Transport {
  FailoverTransport({required this.ble, required this.wifi});

  final Transport ble;
  final WifiTransport wifi;

  /// Whether the WiFi mesh side is enabled (the onboarding/chat toggle).
  /// UI-observable so the "No Internet (by design)" indicator can follow it.
  final ValueNotifier<bool> wifiEnabled = ValueNotifier(false);

  @override
  Future<void> start() => ble.start(); // WiFi only ever starts via the toggle

  @override
  Future<void> stop() async {
    await disableWifi();
    await ble.stop();
  }

  Future<void> enableWifi() async {
    if (wifiEnabled.value) return;
    await wifi.start(); // throws WifiJoinException if the join fails
    wifiEnabled.value = true;
    dbg.DebugLog.instance.log('wifi', 'WiFi mesh enabled (preferred transport)');
  }

  Future<void> disableWifi() async {
    if (!wifiEnabled.value) return;
    await wifi.stop();
    wifiEnabled.value = false;
    dbg.DebugLog.instance.log('wifi', 'WiFi mesh disabled — BLE-only');
  }

  @override
  Future<void> send(String peerId, Uint8List data) =>
      peerId.startsWith('wifi:') ? wifi.send(peerId, data) : ble.send(peerId, data);

  @override
  void onReceive(ReceiveCallback callback) {
    ble.onReceive(callback);
    wifi.onReceive(callback);
  }

  @override
  List<String> listPeers() {
    if (wifiEnabled.value && wifi.connected) return wifi.listPeers();
    return ble.listPeers();
  }
}
