/// Backend + event configuration.
///
/// The backend is a Supabase project (or a venue-local service speaking the
/// same Supabase-shaped REST — meshlink-backend venue/). Compile-time
/// overridable so a build can target a different backend without code
/// changes:
///   flutter run --dart-define=MESHLINK_BACKEND_URL=https://abc123.supabase.co \
///               --dart-define=MESHLINK_SUPABASE_ANON_KEY=eyJ... \
///               --dart-define=MESHLINK_EVENT_ID=summerfest-2026
///
/// Defaults point at the hosted Supabase project, so a plain `flutter run`
/// on any device talks to the same backend.
class BackendConfig {
  const BackendConfig({
    required this.baseUrl,
    required this.eventId,
    this.anonKey = _defaultAnonKey,
  });

  /// Base URL of the Supabase project (or venue service), no trailing slash.
  final String baseUrl;

  /// Event id the ticket/token are bound to (must match the node's config).
  final String eventId;

  /// Supabase anon/publishable key — sent as the `apikey` header (and as the
  /// bearer for unauthenticated calls). Safe to embed: RLS is the gate.
  final String anonKey;

  static const String _defaultAnonKey = String.fromEnvironment(
    'MESHLINK_SUPABASE_ANON_KEY',
    // The hosted project's anon key (safe to embed: RLS is the gate).
    defaultValue:
        'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im5jZW1yd21qbGNiY2lhbWRwc213Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODM5MTMyODUsImV4cCI6MjA5OTQ4OTI4NX0.bO_0QPs4Ohz4Qy4GFRouE_E9w3_NtsZQzHnAa8J0rPA',
  );

  static const BackendConfig fromEnvironment = BackendConfig(
    baseUrl: String.fromEnvironment(
      'MESHLINK_BACKEND_URL',
      defaultValue: 'https://ncemrwmjlcbciamdpsmw.supabase.co',
    ),
    eventId: String.fromEnvironment(
      'MESHLINK_EVENT_ID',
      defaultValue: 'meshlink-demo',
    ),
  );
}
