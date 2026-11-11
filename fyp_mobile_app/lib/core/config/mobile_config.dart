import 'package:flutter/foundation.dart';
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
/// [supabaseInitialized] and [initializationError] are written once by
/// `core/bootstrap/app_bootstrap.dart`; all other values come from
/// compile-time defines and are therefore constant for the lifetime of the
/// process.
abstract final class MobileConfig {
  /// Set to true only after `Supabase.initialize()` returned successfully.
  static bool supabaseInitialized = false;

  /// Test-only live-mode override (null = derive from the build config).
  /// Widget tests flip this so the real repository fakes are exercised
  /// through the same code path a live build takes, without needing
  /// compile-time defines.
  static bool? overrideUsesLiveApi;

  /// A safe, human-readable reason when initialisation failed. Never contains
  /// an exception message that might echo credentials.
  static String? initializationError;

  static bool get hasSupabaseUrl => AppConfig.supabaseUrl.trim().isNotEmpty;

  static bool get hasPublishableKey =>
      AppConfig.supabaseAnonKey.trim().isNotEmpty;

  static bool get hasSupabaseCredentials => hasSupabaseUrl && hasPublishableKey;

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

  /// Only two development host modes exist. A typo must be reported instead
  /// of silently falling back to the emulator alias on a physical device.
  static bool get hasValidHostMode =>
      MobileEndpoints.hostMode == 'emulator' ||
      MobileEndpoints.hostMode == 'adb-reverse';

  /// Plain HTTP is acceptable for a local development API (the debug/profile
  /// Android manifests opt into cleartext). A release binary must not ship an
  /// http:// API origin, so that becomes a blocking build problem.
  static bool get usesCleartextApi =>
      (Uri.tryParse(MobileEndpoints.apiBaseUrl.trim())?.scheme ?? '') == 'http';

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

  static int get apiPort =>
      Uri.tryParse(MobileEndpoints.apiBaseUrl.trim())?.port ?? 0;

  /// A host:port pair is a public address, never key material. Showing it in
  /// an error notice lets the developer see exactly which component failed.
  static String get apiEndpoint => '$apiHost:$apiPort';

  /// Which development host-selection mode this build was compiled with.
  static String get hostMode => MobileEndpoints.hostMode;

  /// True when this BUILD is configured for the live backend.
  ///
  /// Deliberately a compile-time property. The composition root builds its
  /// provider overrides before the asynchronous Supabase bootstrap finishes,
  /// so gating this on the runtime [supabaseInitialized] flag silently
  /// dropped the live Explore/saved repositories on every cold start once
  /// initialization stopped blocking `runApp`. Runtime readiness is tracked
  /// separately by [supabaseReady] / [problems] and enforced fail-closed by
  /// the auth repository, which is the correct authority for access.
  static bool get usesLiveApi =>
      overrideUsesLiveApi ??
      (hasValidApiBaseUrl &&
          hasSupabaseCredentials &&
          !hasUnsafeKey &&
          supabaseUrlLooksValid);

  /// Blocking problems. Empty means the build can attempt a real sign-in.
  static List<String> get problems => <String>[
    if (!hasSupabaseUrl) 'SUPABASE_URL is not set in this build.',
    if (!hasPublishableKey)
      'SUPABASE_PUBLISHABLE_KEY is not set in this build.',
    if (hasUnsafeKey)
      'A secret or service-role key was supplied as the publishable key. '
          'Use the publishable key only.',
    if (hasSupabaseUrl && !supabaseUrlLooksValid)
      'SUPABASE_URL must be an HTTPS URL.',
    if (!hasValidApiBaseUrl)
      'API_BASE_URL is not a valid http(s) URL with a port.',
    if (!hasValidHostMode) 'API_HOST_MODE must be "emulator" or "adb-reverse".',
    if (kReleaseMode && usesCleartextApi)
      'Release builds require an HTTPS API_BASE_URL.',
    if (hasSupabaseCredentials && !hasUnsafeKey && !supabaseInitialized)
      (initializationError ?? 'Supabase did not initialise successfully.'),
  ];

  /// Non-blocking guidance shown alongside the blocking problems.
  static List<String> get hints => <String>[
    if (MobileEndpoints.hostMode == 'adb-reverse')
      'API_HOST_MODE=adb-reverse needs `adb reverse tcp:$apiPort tcp:$apiPort`; '
          'start the backend with .\\run-sitewise.cmd -Mobile.',
    if (apiHost == '10.0.2.2')
      'API_BASE_URL uses 10.0.2.2, which only works on the Android emulator. '
          'A physical device needs a reachable LAN IP (with '
          '.\\run-sitewise.cmd -AllowLan) or adb reverse.',
    if (apiHost != '10.0.2.2' && apiHost != '127.0.0.1')
      'A LAN IP only works while the backend binds 0.0.0.0 and the phone is '
          'on the same subnet (.\\run-sitewise.cmd -AllowLan).',
    'Confirm SUPABASE_URL points at the SiteWise project used by backend/.env '
        '(host: $supabaseHost).',
    'Password recovery and email confirmation finish in the web portal at '
        '${MobileEndpoints.webBaseUrl}.',
  ];

  /// One-line status for safe console logging. Hosts and booleans only —
  /// never key material, tokens or passwords.
  static String get statusLine =>
      'SiteWise mobile config: credentials=${hasSupabaseCredentials ? 'present' : 'missing'}, '
      'supabaseReady=$supabaseReady, hostMode=${MobileEndpoints.hostMode}, '
      'apiEndpoint=$apiEndpoint, problems=${problems.length}';
}
