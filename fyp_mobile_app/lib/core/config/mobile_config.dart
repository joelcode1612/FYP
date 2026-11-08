import 'package:shared_logic/shared_logic.dart';

import 'mobile_endpoints.dart';

/// A read-only, key-free view of this build's authentication configuration.
///
/// An unconfigured build used to fail silently: `main.dart` skipped
/// `Supabase.initialize()` and the user only discovered it after typing
/// credentials into a form that could never succeed. Everything here is a
/// boolean, a host name or a fixed message — **no key material is ever
/// returned, logged or displayed**.
///
/// [supabaseInitialized] and [initializationError] are written once by the
/// composition root (`main.dart`); all other values come from compile-time
/// defines and are therefore constant for the lifetime of the process.
abstract final class MobileConfig {
  /// Set to true only after `Supabase.initialize()` returned successfully.
  static bool supabaseInitialized = false;

  /// A safe, human-readable reason when initialisation failed. Never contains
  /// an exception message that might echo credentials.
  static String? initializationError;

  static bool get hasSupabaseUrl => AppConfig.supabaseUrl.trim().isNotEmpty;

  static bool get hasPublishableKey =>
      AppConfig.supabaseAnonKey.trim().isNotEmpty;

  static bool get hasSupabaseCredentials =>
      hasSupabaseUrl && hasPublishableKey;

  /// The publishable key is the only key allowed in a client build. A secret
  /// or service-role key must never be passed as `SUPABASE_PUBLISHABLE_KEY`,
  /// even by accident during local development.
  static bool get hasUnsafeKey {
    final key = AppConfig.supabaseAnonKey.trim().toLowerCase();
    return key.startsWith('sb_secret_') || key.contains('service_role');
  }

  static bool get supabaseUrlLooksValid {
    final uri = Uri.tryParse(AppConfig.supabaseUrl.trim());
    return uri != null && uri.isScheme('https') && uri.host.isNotEmpty;
  }

  static bool get hasValidApiBaseUrl {
    final uri = Uri.tryParse(MobileEndpoints.apiBaseUrl.trim());
    return uri != null &&
        (uri.isScheme('http') || uri.isScheme('https')) &&
        uri.host.isNotEmpty &&
        uri.hasPort;
  }

  static bool get supabaseReady =>
      hasSupabaseCredentials &&
      !hasUnsafeKey &&
      supabaseUrlLooksValid &&
      supabaseInitialized &&
      initializationError == null;

  /// Host only — safe to show or log. Never the key.
  static String get supabaseHost =>
      Uri.tryParse(AppConfig.supabaseUrl.trim())?.host ?? 'not set';

  static String get apiHost =>
      Uri.tryParse(MobileEndpoints.apiBaseUrl.trim())?.host ?? 'not set';

  /// Blocking problems. Empty means the build can attempt a real sign-in.
  static List<String> get problems => <String>[
    if (!hasSupabaseUrl)
      'SUPABASE_URL is not set in this build.',
    if (!hasPublishableKey)
      'SUPABASE_PUBLISHABLE_KEY is not set in this build.',
    if (hasUnsafeKey)
      'A secret or service-role key was supplied as the publishable key. '
          'Use the publishable key only.',
    if (hasSupabaseUrl && !supabaseUrlLooksValid)
      'SUPABASE_URL must be an HTTPS URL.',
    if (!hasValidApiBaseUrl)
      'API_BASE_URL is not a valid http(s) URL with a port.',
    if (hasSupabaseCredentials && !hasUnsafeKey && !supabaseInitialized)
      (initializationError ?? 'Supabase did not initialise successfully.'),
  ];

  /// Non-blocking guidance shown alongside the blocking problems.
  static List<String> get hints => <String>[
    if (apiHost == '10.0.2.2')
      'API_BASE_URL uses 10.0.2.2, which only works on the Android emulator. '
          'A physical device or iOS simulator needs this computer\'s LAN IP.',
    'Confirm SUPABASE_URL points at the SiteWise project used by backend/.env '
        '(host: $supabaseHost).',
    'Password recovery and email confirmation finish in the web portal at '
        '${MobileEndpoints.webBaseUrl}.',
  ];

  /// One-line status for safe console logging.
  static String get statusLine =>
      'SiteWise mobile config: credentials=${hasSupabaseCredentials ? 'present' : 'missing'}, '
      'supabaseReady=$supabaseReady, apiHost=$apiHost, '
      'problems=${problems.length}';
}
