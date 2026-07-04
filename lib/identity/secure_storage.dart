import 'package:flutter/services.dart';

/// Dart handle for platform secure key storage — iOS Keychain
/// (ios/Runner/KeychainBridge.swift) and Android Keystore
/// (android/.../KeystoreBridge.kt), bridged via platform channel.
///
/// Values are opaque strings (the identity layer stores the private seed as
/// hex). On iOS entries live in the app's Keychain with
/// kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly; on Android they are
/// encrypted with an AES-GCM key held in the Android Keystore (StrongBox
/// where the device supports it, TEE fallback otherwise) — the Keystore key
/// never leaves secure hardware.
class SecureStorage {
  static const MethodChannel _channel = MethodChannel('meshlink/secure_storage');

  /// Returns the stored value for [key], or null if absent.
  Future<String?> read(String key) async {
    return _channel.invokeMethod<String>('read', {'key': key});
  }

  /// Stores [value] under [key], overwriting any existing entry.
  Future<void> write(String key, String value) async {
    await _channel.invokeMethod<void>('write', {'key': key, 'value': value});
  }

  /// Removes the entry for [key]; no-op if absent.
  Future<void> delete(String key) async {
    await _channel.invokeMethod<void>('delete', {'key': key});
  }
}
