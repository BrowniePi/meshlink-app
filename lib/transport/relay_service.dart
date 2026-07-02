import 'dart:io';

import 'package:flutter/services.dart';

/// Dart handle for the Android foreground service that keeps the BLE relay
/// alive while the app is backgrounded (android/.../MeshRelayService.kt).
/// No-ops on iOS, where background BLE uses bluetooth-central /
/// bluetooth-peripheral background modes instead of a service.
class RelayService {
  static const MethodChannel _channel = MethodChannel('meshlink/relay_service');

  static Future<void> start() async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod<void>('start');
  }

  static Future<void> stop() async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod<void>('stop');
  }

  static Future<bool> isRunning() async {
    if (!Platform.isAndroid) return false;
    return await _channel.invokeMethod<bool>('isRunning') ?? false;
  }
}
