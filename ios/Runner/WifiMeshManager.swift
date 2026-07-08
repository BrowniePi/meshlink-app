import Flutter
import Foundation
import NetworkExtension
import SystemConfiguration.CaptiveNetwork

/// Phase 6 WiFi mesh join — iOS side of the `meshlink/wifi_mesh` channel
/// (lib/transport/wifi/ios_wifi_join.dart).
///
/// NEHotspotConfiguration is the app-mediated join API: the first apply()
/// for an SSID always shows a one-time system dialog (an Apple privacy
/// boundary — cannot be suppressed), after which the configuration is
/// stored and rejoins are silent. Requires the Hotspot Configuration
/// entitlement (Runner.entitlements). Unlike Android there is no process
/// binding: iOS routes local-subnet traffic over the associated WiFi
/// automatically.
///
/// WiFi Calling state has no public iOS API, so currentState reports it as
/// unknown; the current SSID is fetched via NEHotspotNetwork on iOS 14+.
final class WifiMeshManager: NSObject {
  static let shared = WifiMeshManager()
  private var channel: FlutterMethodChannel?
  private var joinedSsid: String?

  func attach(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "meshlink/wifi_mesh", binaryMessenger: messenger)
    self.channel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      switch call.method {
      case "currentState":
        self.currentState(result: result)
      case "join":
        guard let args = call.arguments as? [String: Any],
              let ssid = args["ssid"] as? String,
              let passphrase = args["passphrase"] as? String else {
          result(FlutterError(code: "bad_args", message: "missing ssid/passphrase",
                              details: nil))
          return
        }
        self.join(ssid: ssid, passphrase: passphrase, result: result)
      case "leave":
        self.leave(result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func currentState(result: @escaping FlutterResult) {
    if #available(iOS 14.0, *) {
      NEHotspotNetwork.fetchCurrent { network in
        DispatchQueue.main.async {
          result(["currentSsid": network?.ssid, "wifiCallingActive": nil])
        }
      }
    } else {
      result(["currentSsid": nil, "wifiCallingActive": nil])
    }
  }

  private func join(ssid: String, passphrase: String, result: @escaping FlutterResult) {
    let config = NEHotspotConfiguration(ssid: ssid, passphrase: passphrase, isWEP: false)
    // Persist across app restarts: rejoining a stored SSID never re-prompts.
    config.joinOnce = false
    NEHotspotConfigurationManager.shared.apply(config) { [weak self] error in
      DispatchQueue.main.async {
        if let error = error as NSError? {
          // "already associated" is success, not failure.
          if error.domain == NEHotspotConfigurationErrorDomain,
             error.code == NEHotspotConfigurationError.alreadyAssociated.rawValue {
            self?.joinedSsid = ssid
            result(nil)
            return
          }
          result(FlutterError(code: "join_failed", message: error.localizedDescription,
                              details: nil))
          return
        }
        self?.joinedSsid = ssid
        result(nil)
      }
    }
  }

  private func leave(result: @escaping FlutterResult) {
    if let ssid = joinedSsid {
      NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
      joinedSsid = nil
    }
    result(nil)
  }
}
