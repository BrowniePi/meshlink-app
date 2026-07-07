import 'dart:async';

import 'package:flutter/foundation.dart';

import '../debug/debug_log.dart' as dbg;
import '../power/battery_tier_manager.dart';
import '../telemetry/phone_ping_responder.dart';
import 'ble_transport.dart';
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
  FailoverTransport({required this.ble, required this.wifi, this.phonePing});

  final Transport ble;
  final WifiTransport wifi;

  /// Phase 7 telemetry: answers the node's `MLPP1` ping frames. Optional so
  /// plain-transport tests are unaffected; when absent, telemetry frames are
  /// still demuxed away from the pipeline (they aren't signed packets) and
  /// dropped.
  final PhonePingResponder? phonePing;

  /// True while Ticket-only tier has both radios down (see [applyTier]).
  bool _suspended = false;

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
    // Ticket-only tier: all messaging is disabled, so the toggle can't
    // bring a radio back up. Cleared automatically when battery recovers.
    if (_suspended) return;
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
    // Demux rule (phone-ping spec §2): a reassembled frame starting with
    // `MLPP1` is a telemetry control frame and must never reach the mesh
    // pipeline. Answering via [send] routes by peer id, so the pong leaves
    // on the same transport (BLE or WiFi) the ping arrived on.
    void demuxed(String peerId, Uint8List data) {
      if (isTelemetryFrame(data)) {
        final responder = phonePing;
        if (responder != null) {
          unawaited(responder.handle(peerId, data, send));
        }
        return;
      }
      callback(peerId, data);
    }

    ble.onReceive(demuxed);
    wifi.onReceive(demuxed);
  }

  @override
  List<String> listPeers() {
    if (wifiEnabled.value && wifi.connected) return wifi.listPeers();
    return ble.listPeers();
  }

  /// Enforce a battery tier (Technical Reference §6) on the radios.
  ///
  /// The table's BLE duty cycles map onto the knobs this stack has:
  ///  - Active relay (100 ms/900 ms) — full scan cadence, advertising on.
  ///  - Passive relay (50 ms/1,950 ms) — scan time quartered per period,
  ///    advertising on. (Spray-copy suppression belongs to relay_forward,
  ///    which the app pipeline stubs — step 8 always delivers today.)
  ///  - Leaf — no P2P relay: advertising/GATT server off, sparse scanning
  ///    only to keep finding the node for the phone's own messages.
  ///  - Ticket-only — everything off. WiFi's user toggle is remembered so
  ///    a recharge restores exactly the setup the user chose.
  Future<void> applyTier(BatteryTier tier) async {
    dbg.DebugLog.instance.log('battery', 'applying ${tier.label} to radios');
    if (tier == BatteryTier.ticketOnly) {
      if (_suspended) return;
      _suspended = true;
      await ble.stop();
      if (wifiEnabled.value) await wifi.stop(); // toggle state preserved
      return;
    }
    if (_suspended) {
      _suspended = false;
      await ble.start();
      if (wifiEnabled.value) await wifi.start();
    }
    if (ble is! DutyCycleControl) return; // test doubles
    final bleControl = ble as DutyCycleControl;
    switch (tier) {
      case BatteryTier.activeRelay:
        bleControl.setDutyCycle(
          scanEvery: const Duration(seconds: 20),
          scanTimeout: const Duration(seconds: 10),
          advertise: true,
        );
      case BatteryTier.passiveRelay:
        bleControl.setDutyCycle(
          scanEvery: const Duration(seconds: 60),
          scanTimeout: const Duration(seconds: 8),
          advertise: true,
        );
      case BatteryTier.leaf:
        bleControl.setDutyCycle(
          scanEvery: const Duration(seconds: 120),
          scanTimeout: const Duration(seconds: 5),
          advertise: false,
        );
      case BatteryTier.ticketOnly:
        break; // handled above
    }
  }
}
