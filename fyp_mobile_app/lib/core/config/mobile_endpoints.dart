import 'package:shared_logic/shared_logic.dart';

/// Where this mobile build sends its authenticated requests.
///
/// Separate from [AppConfig.apiBaseUrl] on purpose: that flag also decides
/// whether the property screens use demo data, and it must not flip just
/// because real sign-in was configured. Supabase credentials themselves come
/// from [AppConfig] (`--dart-define SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY`)
/// and only ever the publishable key.
///
/// Nothing here is secret — these are the same addresses the web app uses.
abstract final class MobileEndpoints {
  /// Unified SiteWise backend (FastAPI on :8090).
  ///
  /// `10.0.2.2` is the host loopback as seen from the Android emulator. A
  /// physical device on the same network needs
  /// `--dart-define=API_BASE_URL=http://LAN-IP:8090`.
  static const String apiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://10.0.2.2:8090',
  );

  /// Public origin used to build the password-recovery redirect. The reset
  /// itself completes in the web portal (mobile has no OAuth link handler),
  /// so this must be an address the user can actually open.
  static const String webBaseUrl = String.fromEnvironment(
    'WEB_BASE_URL',
    defaultValue: apiBaseUrl,
  );

  static Uri get profileUri => Uri.parse('$apiBaseUrl/api/v1/auth/me');

  /// Confirmation-link target for new registrations. Supabase opens this in
  /// the browser, the web auth bridge exchanges the code there, and the user
  /// comes back to the app to sign in normally.
  static Uri get emailConfirmationRedirect =>
      Uri.parse('$webBaseUrl/auth/callback');

  /// `…/auth/callback?next=/reset-password` — the route the web auth bridge
  /// exchanges the Supabase code on, then hands to the reset screen.
  static Uri get passwordRecoveryRedirect =>
      Uri.parse('$webBaseUrl/auth/callback').replace(
        queryParameters: const {'next': '/reset-password'},
      );

  /// Shown to Admin / Agent accounts, whose workspaces are web-only.
  static String get staffPortalHint => webBaseUrl;
}
