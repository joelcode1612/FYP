
/// Shared application configuration.
/// Flutter may supply runtime values from its JSON asset.
/// Other clients can continue using Dart defines.
abstract final class AppConfig {
  static const String appName = 'Sitewise';
  static const String tagline = 'F&B Location Intelligence Platform';

  // Preserve existing demo-mode behavior.
  static const String apiBaseUrl = '';

  static String? _mobileSupabaseUrl;
  static String? _mobilePublishableKey;

  static void configureSupabase({
    required String url,
    required String publishableKey,
  }) {
    _mobileSupabaseUrl = url.trim();
    _mobilePublishableKey = publishableKey.trim();
  }

  static String get supabaseUrl =>
      _mobileSupabaseUrl ??
          const String.fromEnvironment('SUPABASE_URL');

  static String get supabaseAnonKey =>
      _mobilePublishableKey ??
          const String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY');

  static bool get hasSupabase =>
      supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty;

  static bool get usesDemoData => apiBaseUrl.isEmpty;
}
