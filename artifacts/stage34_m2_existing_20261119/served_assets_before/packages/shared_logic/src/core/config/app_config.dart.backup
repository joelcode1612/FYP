/// Compile-time application configuration.
///
/// Values arrive from `--dart-define` (or `--dart-define-from-file`) so no
/// key is ever committed. Anything left unset stays empty and the feature it
/// configures reports itself as unavailable rather than pretending to work.
abstract final class AppConfig {
  static const String appName = 'Sitewise';
  static const String tagline = 'F&B Location Intelligence Platform';

  /// Base URL for the future API layer. Empty = demo-data mode.
  ///
  /// Deliberately NOT read from the environment: the demo property/assessment
  /// screens branch on [usesDemoData], and flipping that flag by accident
  /// would make them request data the mobile app never fetches. Clients that
  /// talk to the live backend declare their own base URL instead.
  static const String apiBaseUrl = '';

  /// Supabase project URL and publishable (public client) key.
  ///
  /// Only the publishable/anon key may ever reach a client build — it is the
  /// value the backend also publishes for browser sign-in. The secret key and
  /// the service-role key belong to the server and must never be defined
  /// here, in a Dart file, or in an asset bundle.
  static const String supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const String supabaseAnonKey = String.fromEnvironment(
    'SUPABASE_PUBLISHABLE_KEY',
  );

  /// True when this build carries usable Supabase credentials.
  static bool get hasSupabase =>
      supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty;

  static bool get usesDemoData => apiBaseUrl.isEmpty;
}
