import 'package:flutter/services.dart';

import '../../debug/debug_log.dart' as dbg;
import 'wifi_join.dart';

/// iOS WiFi join via NEHotspotConfiguration, bridged to
/// ios/Runner/WifiMeshManager.swift.
///
/// NEHotspotConfiguration is the app-mediated equivalent of Android's
/// WifiNetworkSpecifier. iOS always shows a one-time system dialog on the
/// first join — an Apple privacy boundary that cannot be suppressed, not a
/// bug (WiFi Mesh Add-On drawbacks table). Later joins to the stored SSID
/// are silent. iOS routes local-subnet traffic over the associated WiFi
/// automatically, so no process binding is needed.
///
/// WiFi Calling state is not exposed by any public iOS API, so
/// [currentState] reports it as unknown (null) — callers show the generic
/// warning copy instead of the call-specific escalation.
class IosWifiJoin implements WifiJoin {
  static const MethodChannel _channel = MethodChannel('meshlink/wifi_mesh');

  void Function()? _onLost;

  IosWifiJoin() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onLost') {
        dbg.DebugLog.instance.log('wifi', 'mesh network lost (OS callback)');
        _onLost?.call();
      }
      return null;
    });
  }

  @override
  Future<WifiState> currentState() async {
    final state =
        await _channel.invokeMapMethod<String, dynamic>('currentState');
    return WifiState(
      currentSsid: state?['currentSsid'] as String?,
      // Never present on iOS; kept for parity with the Android bridge.
      wifiCallingActive: state?['wifiCallingActive'] as bool?,
    );
  }

  @override
  Future<void> join(String ssid, String passphrase) async {
    dbg.DebugLog.instance.log('wifi', 'applying hotspot config "$ssid"');
    try {
      await _channel.invokeMethod<void>('join', {
        'ssid': ssid,
        'passphrase': passphrase,
      });
    } on PlatformException catch (e) {
      throw WifiJoinException(e.message ?? 'WiFi join failed (${e.code})');
    }
    dbg.DebugLog.instance.log('wifi', 'joined "$ssid"');
  }

  @override
  Future<void> leave() async {
    dbg.DebugLog.instance.log('wifi', 'removing hotspot config');
    await _channel.invokeMethod<void>('leave');
  }

  @override
  void onLost(void Function() callback) {
    _onLost = callback;
  }
}
