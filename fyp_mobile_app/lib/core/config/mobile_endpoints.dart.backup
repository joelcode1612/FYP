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
///
/// ## Host selection (development)
///
/// `.\run-sitewise.cmd` starts ONE FastAPI process on **:8090** that serves
/// both the compiled Jaspr frontend and `/api/v1/*` (see `run-sitewise.ps1`
/// and `backend/src/sitewise/main.py`). The former `:8000` default belonged to
/// the retired two-server launcher (`run-sitewise-unified.ps1`) and is dead:
/// nothing listens on :8000 when the unified launcher is used.
///
///   * `API_BASE_URL` (explicit define) always wins — use it for a LAN origin
///     or a production HTTPS endpoint.
///   * default / `API_HOST_MODE=emulator` → `http://10.0.2.2:8090`, the
///     Android emulator's alias for the development machine.
///   * `API_HOST_MODE=adb-reverse` → `http://127.0.0.1:8090` **as seen from
///     the device**, after `adb reverse tcp:8090 tcp:8090`. This is the right
///     setting for a USB-connected physical device: it needs no LAN IP, no
///     `0.0.0.0` bind and no firewall change.
///
/// No LAN IP is baked into source. Release builds must supply an HTTPS
/// `API_BASE_URL`; `MobileConfig` refuses cleartext in release mode.
abstract final class MobileEndpoints {
  static const String _apiOverride = String.fromEnvironment('API_BASE_URL');
  static const String _webOverride = String.fromEnvironment('WEB_BASE_URL');
  static const String _hostMode = String.fromEnvironment(
    'API_HOST_MODE',
    defaultValue: 'emulator',
  );

  static const String _emulatorOrigin = 'http://10.0.2.2:8090';
  static const String _adbReverseOrigin = 'http://127.0.0.1:8090';
  static const String _defaultOrigin =
      _hostMode == 'adb-reverse' ? _adbReverseOrigin : _emulatorOrigin;

  /// Compile-time so every consumer stays const-friendly.
  ///
  /// `String.isNotEmpty` is NOT a constant expression in Dart, so an explicit
  /// define is detected with `== ''` instead. An empty define is treated as
  /// "not supplied" rather than producing an invalid URI.
  static const String apiBaseUrl =
      _apiOverride == '' ? _defaultOrigin : _apiOverride;

  /// Public origin used to build the password-recovery / confirmation
  /// redirect. The reset completes in the web portal (mobile has no OAuth
  /// link handler), so this must be an origin the user can actually open.
  static const String webBaseUrl =
      _webOverride == '' ? apiBaseUrl : _webOverride;

  /// Development host-selection mode actually compiled into this build.
  /// Safe to log: one of a fixed set of names, never a key or an address.
  static String get hostMode => _hostMode;

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
