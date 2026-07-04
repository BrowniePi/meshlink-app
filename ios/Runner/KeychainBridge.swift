import Flutter
import Foundation
import Security

/// Native half of the `meshlink/secure_storage` platform channel on iOS.
/// Stores opaque string values (the identity private seed) as generic-
/// password items in the app's Keychain.
///
/// Access class is kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly:
/// readable after the first unlock following boot (the BLE relay runs in
/// the background, so kSecAttrAccessibleWhenUnlocked would break relaying
/// on a locked phone), never migrated to another device via backup — a
/// reinstall or new device therefore yields a fresh identity, which is the
/// intended storage model.
final class KeychainBridge: NSObject {
  static let shared = KeychainBridge()
  private static let service = "com.meshlink.identity"

  func attach(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "meshlink/secure_storage", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      guard let args = call.arguments as? [String: Any],
            let key = args["key"] as? String else {
        result(FlutterError(code: "bad_args", message: "missing key", details: nil))
        return
      }
      switch call.method {
      case "read":
        result(self.read(key: key))
      case "write":
        guard let value = args["value"] as? String else {
          result(FlutterError(code: "bad_args", message: "missing value", details: nil))
          return
        }
        if let status = self.write(key: key, value: value) {
          result(FlutterError(code: "keychain_error",
                              message: "SecItem write failed: \(status)", details: nil))
        } else {
          result(nil)
        }
      case "delete":
        self.delete(key: key)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func baseQuery(key: String) -> [String: Any] {
    return [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Self.service,
      kSecAttrAccount as String: key,
    ]
  }

  private func read(key: String) -> String? {
    var query = baseQuery(key: key)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    guard status == errSecSuccess, let data = item as? Data else { return nil }
    return String(data: data, encoding: .utf8)
  }

  /// Returns nil on success, or the failing OSStatus.
  private func write(key: String, value: String) -> OSStatus? {
    let data = Data(value.utf8)
    var attrs = baseQuery(key: key)
    attrs[kSecValueData as String] = data
    attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    var status = SecItemAdd(attrs as CFDictionary, nil)
    if status == errSecDuplicateItem {
      let update: [String: Any] = [kSecValueData as String: data]
      status = SecItemUpdate(baseQuery(key: key) as CFDictionary, update as CFDictionary)
    }
    return status == errSecSuccess ? nil : status
  }

  private func delete(key: String) {
    SecItemDelete(baseQuery(key: key) as CFDictionary)
  }
}
