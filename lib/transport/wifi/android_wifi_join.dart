import 'package:flutter/services.dart';

import '../../debug/debug_log.dart' as dbg;
import 'wifi_join.dart';

/// Android WiFi join via WifiNetworkSpecifier (API 29+), bridged to
/// android/.../WifiMeshManager.kt.
///
/// WifiNetworkSpecifier scopes the connection to this app's own network
/// requests instead of making it the phone's default route — the one
/// mechanism that both avoids the repeat-permission prompt (the OS
/// remembers the approved specifier) and stops Android from treating the
/// internet-less mesh as a broken network that should displace cellular
/// (WiFi Mesh Add-On §3.2). Other apps' traffic stays on cellular.
///
/// While joined, the native side binds this app's process to the mesh
/// network so plain Dart sockets reach the node at 10.78.0.x; leave()
/// unbinds, restoring default routing.
class AndroidWifiJoin implements WifiJoin {
  static const MethodChannel _channel = MethodChannel('meshlink/wifi_mesh');

  void Function()? _onLost;

  AndroidWifiJoin() {
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
      wifiCallingActive: state?['wifiCallingActive'] as bool?,
    );
  }

  @override
  Future<void> join(String ssid, String passphrase) async {
    dbg.DebugLog.instance.log('wifi', 'requesting mesh network "$ssid"');
    try {
      await _channel.invokeMethod<void>('join', {
        'ssid': ssid,
        'passphrase': passphrase,
      });
    } on PlatformException catch (e) {
      dbg.DebugLog.instance.log(
          'wifi', 'join "$ssid" failed: ${e.code} ${e.message}',
          level: dbg.LogLevel.error);
      throw WifiJoinException(e.message ?? 'WiFi join failed (${e.code})');
    }
    dbg.DebugLog.instance.log('wifi', 'mesh network "$ssid" available');
  }

  @override
  Future<void> leave() async {
    dbg.DebugLog.instance.log('wifi', 'leaving mesh network');
    await _channel.invokeMethod<void>('leave');
  }

  @override
  void onLost(void Function() callback) {
    _onLost = callback;
  }
}
