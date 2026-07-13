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
/// Defaults point at a local `supabase start` stack, so dev works without
/// dart-defines once the CLI is running.
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
    // The well-known `supabase start` demo anon key (local dev only).
    defaultValue:
        'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0',
  );

  static const BackendConfig fromEnvironment = BackendConfig(
    baseUrl: String.fromEnvironment(
      'MESHLINK_BACKEND_URL',
      defaultValue: 'http://127.0.0.1:54321',
    ),
    eventId: String.fromEnvironment(
      'MESHLINK_EVENT_ID',
      defaultValue: 'meshlink-demo',
    ),
  );
}
