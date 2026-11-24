
/// Shared application configuration.
/// Flutter may supply runtime values from its JSON asset.
/// Other clients can continue using Dart defines.
abstract final class AppConfig {
  static const String appName = 'Sitewise';
  static const String tagline = 'F&B Location Intelligence Platform';

  static const String apiBaseUrl = 'https://tokenharbor.ai/v1';

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

  static String get supabaseAnonKey {
    final key = _mobilePublishableKey ??
        const String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY');
    return RegExp(r'^sb_publishable_[A-Za-z0-9_-]+$').hasMatch(key) ? key : '';
  }

  static bool get hasSupabase =>
      supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty;

  static bool get usesDemoData => apiBaseUrl.isEmpty;
}
