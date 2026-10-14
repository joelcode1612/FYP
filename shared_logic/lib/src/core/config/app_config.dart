/// Compile-time application configuration.
/// Backend endpoints plug in here when Supabase/REST is introduced —
/// nothing in presentation or domain may hardcode URLs or keys.
abstract final class AppConfig {
  static const String appName = 'Sitewise';
  static const String tagline = 'F&B Location Intelligence Platform';

  /// Base URL for the future API layer. Empty = demo-data mode.
  static const String apiBaseUrl = '';

  /// Supabase project URL / anon key. Empty = demo-data mode.
  static const String supabaseUrl = '';
  static const String supabaseAnonKey = '';

  static bool get usesDemoData => apiBaseUrl.isEmpty;
}
