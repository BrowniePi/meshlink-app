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

  /// Pi node listener — 10.78.0.1 of its own AP subnet (see class doc).
  static const String piNodeHost = String.fromEnvironment(
    'MESHLINK_WIFI_NODE_HOST',
    defaultValue: '10.78.0.1',
  );

  /// Mac node listener — the Apple Silicon VM host address used when
  /// bench-testing against a Mac-hosted node instead of a Pi.
  static const String macNodeHost = String.fromEnvironment(
    'MESHLINK_WIFI_MAC_NODE_HOST',
    defaultValue: '192.168.64.1',
  );

  static const int _nodePort = int.fromEnvironment(
    'MESHLINK_WIFI_NODE_PORT',
    defaultValue: 7800,
  );

  static const WifiConfig fromEnvironment = WifiConfig(
    ssid: String.fromEnvironment(
      'MESHLINK_WIFI_SSID',
      defaultValue: 'MeshLink-Network',
    ),
    passphrase: String.fromEnvironment(
      'MESHLINK_WIFI_PASSPHRASE',
      defaultValue: 'venue-secret-2026',
    ),
    nodeHost: piNodeHost,
    nodePort: _nodePort,
  );

  /// Which node this config targets, from its host address.
  WifiNodeType get nodeType =>
      nodeHost == macNodeHost ? WifiNodeType.mac : WifiNodeType.pi;

  /// Config for [type], keeping ssid/passphrase and swapping only the node
  /// host. Both hosts come from the static deployment constants (not from
  /// this instance's host), so it is reversible and idempotent: switching
  /// Mac→Pi always restores the Pi host, whatever the current target.
  WifiConfig forNodeType(WifiNodeType type) => WifiConfig(
        ssid: ssid,
        passphrase: passphrase,
        nodeHost: type == WifiNodeType.mac ? macNodeHost : piNodeHost,
        nodePort: nodePort,
      );
}

/// Which node the app is pointed at — selects nodeHost only, since
/// SSID/passphrase and port are shared by the venue's WiFi config either way.
enum WifiNodeType { pi, mac }
