/// Backend + event configuration for the Phase 5 attestation flow.
///
/// Both are compile-time overridable so a build can target a real organiser
/// backend without code changes:
///   flutter run --dart-define=MESHLINK_BACKEND_URL=http://192.168.1.20:8000 \
///               --dart-define=MESHLINK_EVENT_ID=summerfest-2026
///
/// Defaults suit local development: the Android emulator reaches the host
/// machine at 10.0.2.2. On a physical phone you must pass the organiser
/// machine's LAN IP via --dart-define; localhost/10.0.2.2 won't resolve.
class BackendConfig {
  const BackendConfig({required this.baseUrl, required this.eventId});

  /// Base URL of the meshlink-backend service, no trailing slash.
  final String baseUrl;

  /// Event id the ticket/token are bound to (must match the node's config).
  final String eventId;

  static const BackendConfig fromEnvironment = BackendConfig(
    baseUrl: String.fromEnvironment(
      'MESHLINK_BACKEND_URL',
      defaultValue: 'http://10.0.2.2:8000',
    ),
    eventId: String.fromEnvironment(
      'MESHLINK_EVENT_ID',
      defaultValue: 'meshlink-demo',
    ),
  );
}
