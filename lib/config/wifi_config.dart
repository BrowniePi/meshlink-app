/// WiFi mesh (Phase 6) deployment configuration.
///
/// SSID/passphrase must match the values pushed to every node's
/// /etc/meshlink/wifi_deployment.conf (see meshlink-node
/// docs/wifi-ap-deployment.md) — compile-time overridable like
/// [BackendConfig], keeping the backend off the venue path:
///   flutter run --dart-define=MESHLINK_WIFI_SSID=MeshLink-Network \
///               --dart-define=MESHLINK_WIFI_PASSPHRASE=venue-secret-2026
///
/// The node host/port is where every node's WiFi listener lives — the
/// node is always the AP's own address, so 10.78.0.1 holds venue-wide
/// (each node is 10.78.0.1 *of its own AP subnet*).
class WifiConfig {
  const WifiConfig({
    required this.ssid,
    required this.passphrase,
    required this.nodeHost,
    required this.nodePort,
  });

  final String ssid;
  final String passphrase;

  /// Node WiFi listener address — must match the node's MESHLINK_WIFI_LISTEN.
  final String nodeHost;
  final int nodePort;

  static const WifiConfig fromEnvironment = WifiConfig(
    ssid: String.fromEnvironment(
      'MESHLINK_WIFI_SSID',
      defaultValue: 'MeshLink-Network',
    ),
    passphrase: String.fromEnvironment(
      'MESHLINK_WIFI_PASSPHRASE',
      defaultValue: 'meshlink-dev-passphrase',
    ),
    nodeHost: String.fromEnvironment(
      'MESHLINK_WIFI_NODE_HOST',
      defaultValue: '10.78.0.1',
    ),
    nodePort: int.fromEnvironment(
      'MESHLINK_WIFI_NODE_PORT',
      defaultValue: 7800,
    ),
  );
}
