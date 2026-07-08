import 'dart:io';

import 'android_wifi_join.dart';
import 'ios_wifi_join.dart';

/// Pre-join WiFi state, used by the onboarding toggle to surface the
/// single-WiFi-client tradeoff at the moment of choice (WiFi Mesh Add-On
/// §4.2/4.3): the network the user would be disconnected from, and whether
/// WiFi Calling is active (null where the platform doesn't expose it).
class WifiState {
  const WifiState({this.currentSsid, this.wifiCallingActive});

  final String? currentSsid;
  final bool? wifiCallingActive;
}

/// Platform-mediated join to the mesh SSID. Both implementations go through
/// the OS's app-scoped network APIs (WifiNetworkSpecifier /
/// NEHotspotConfiguration) — never a manual Settings join — which is what
/// keeps the connection scoped to this app's sockets, suppresses the OS's
/// generic broken-internet handling, and makes rejoins silent after the
/// one-time approval.
abstract class WifiJoin {
  /// Platform-appropriate implementation.
  factory WifiJoin.forPlatform() =>
      Platform.isIOS ? IosWifiJoin() : AndroidWifiJoin();

  /// Current WiFi state, queried before showing the toggle warning copy.
  Future<WifiState> currentState();

  /// Join [ssid]. Completes when the network is usable; throws
  /// [WifiJoinException] on refusal/failure (user declined the OS prompt,
  /// network not found, …).
  Future<void> join(String ssid, String passphrase);

  /// Leave the mesh network and undo any app scoping. Must restore the
  /// phone's networking exactly as it was (Phase 6 is strictly additive).
  Future<void> leave();

  /// Invoked if the OS drops the mesh network (out of range, radio off).
  void onLost(void Function() callback);
}

class WifiJoinException implements Exception {
  WifiJoinException(this.message);
  final String message;

  @override
  String toString() => 'WifiJoinException: $message';
}
