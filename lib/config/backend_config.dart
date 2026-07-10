/// Backend + event configuration for the Phase 5 attestation flow.
///
/// Both are compile-time overridable so a build can target a different
/// backend without code changes:
///   flutter run --dart-define=MESHLINK_BACKEND_URL=http://192.168.1.20:8000 \
///               --dart-define=MESHLINK_EVENT_ID=summerfest-2026
///
/// Defaults point at the hosted meshlink-backend
/// (https://meshlink-backend-0l2d.onrender.com), so a plain `flutter run`
/// works out of the box on both emulators/simulators and physical devices.
/// Pass `--dart-define=MESHLINK_BACKEND_URL=http://<lan-ip>:8000` to target a
/// backend running locally for dev instead.
class BackendConfig {
  const BackendConfig({required this.baseUrl, required this.eventId});

  /// Base URL of the meshlink-backend service, no trailing slash.
  final String baseUrl;

  /// Event id the ticket/token are bound to (must match the node's config).
  final String eventId;

  static const BackendConfig fromEnvironment = BackendConfig(
    baseUrl: String.fromEnvironment(
      'MESHLINK_BACKEND_URL',
      defaultValue: 'https://meshlink-backend-0l2d.onrender.com',
    ),
    eventId: String.fromEnvironment(
      'MESHLINK_EVENT_ID',
      defaultValue: 'meshlink-demo',
    ),
  );
}
