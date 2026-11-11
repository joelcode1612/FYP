import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:shared_logic/shared_logic.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/bootstrap/startup_trace.dart';
import '../../core/config/mobile_endpoints.dart';
import '../../core/config/mobile_runtime_config.dart';

/// Server-side identity lookup used to confirm what a local session claims.
///
/// Supabase proves *who* the token belongs to; only SiteWise knows *what* that
/// person may do. Split out so [SupabaseAuthRepository] can be exercised
/// against canned responses without a live backend.
abstract class IdentityProbe {
  /// Returns the decoded `/api/v1/auth/me` payload for [accessToken].
  ///
  /// Throws [SessionExpiredFailure] on 401, [AccountInactiveFailure] on 403,
  /// [AuthUnavailableFailure] on 5xx / an unreadable profile, [NetworkFailure]
  /// on a refused connection, [AuthTimeoutFailure] on a timeout and
  /// [AuthTlsFailure] on a TLS handshake failure. Each class maps to its own
  /// UI state, so a wrong port is never reported as a server outage.
  Future<Map<String, dynamic>> fetch(String accessToken);
}

class HttpIdentityProbe implements IdentityProbe {
  HttpIdentityProbe({http.Client? client, Uri? endpoint})
    : _client = client ?? http.Client(),
      _endpoint = endpoint ?? MobileEndpoints.profileUri;

  final http.Client _client;
  final Uri _endpoint;

  @override
  Future<Map<String, dynamic>> fetch(String accessToken) =>
      StartupTrace.measure('identity_verification', () => _fetch(accessToken));

  /// The verification logic is deliberately kept out of the timing wrapper:
  /// exception mapping and the fail-closed status-code switch must stay
  /// byte-for-byte equivalent to the untimed implementation.
  Future<Map<String, dynamic>> _fetch(String accessToken) async {
    http.Response response;
    try {
      response = await _client
          .get(
            _endpoint,
            headers: {
              'authorization': 'Bearer $accessToken',
              'accept': 'application/json',
            },
          )
          .timeout(const Duration(seconds: 15));
    } on TimeoutException {
      throw const AuthTimeoutFailure();
    } on SocketException {
      // Connection refused, DNS failure, no route to host, or Android
      // blocking cleartext HTTP / lacking INTERNET. All are connectivity
      // problems — never "the backend returned an error".
      throw const NetworkFailure();
    } on HandshakeException {
      throw const AuthTlsFailure();
    } on TlsException {
      // Also covers CertificateException (a TlsException subtype), so there
      // is deliberately no separate `on CertificateException` clause.
      throw const AuthTlsFailure();
    } on http.ClientException {
      throw const NetworkFailure();
    }

    switch (response.statusCode) {
      case 200:
        final decoded = jsonDecode(response.body);
        if (decoded is! Map<String, dynamic>) {
          throw const AuthUnavailableFailure(
            'The server returned an unreadable profile.',
          );
        }
        return decoded;
      case 401:
        throw const SessionExpiredFailure();
      case 403:
        throw const AccountInactiveFailure(
          status: 'forbidden',
          message: 'This account is not allowed to use Sitewise.',
        );
      case 503:
        throw const AuthUnavailableFailure(
          'Sitewise could not verify your credentials right now.',
        );
      default:
        // Do not echo an HTTP status into the UI. The server-side log has the
        // detail; the client only needs to know the check did not complete.
        throw const AuthUnavailableFailure(
          'The identity service could not complete the check.',
        );
    }
  }
}

/// Production authentication for the mobile app: Supabase Auth for the
/// credentials, the SiteWise backend for the *authority*.
///
/// Every path that could end in "the user is signed in" goes through
/// [_authorize], which asks `GET /api/v1/auth/me` and takes the role and
/// account status from that answer only. Consequences:
///
///   * a token minted for another identity is rejected (server `user_id` vs
///     the session subject);
///   * no role is ever sent on registration — the backend provisions the
///     profile and this class re-reads whatever role it assigned;
///   * a suspended or still-pending profile throws instead of routing;
///   * if Supabase or the backend cannot be reached, nothing is granted.
///
/// The Supabase session itself is persisted through
/// `SecureSessionLocalStorage` (see `main.dart`), not in plaintext app storage.
class SupabaseAuthRepository implements AuthRepository {
  SupabaseAuthRepository({IdentityProbe? probe, GoTrueClient Function()? auth})
    : _probe = probe ?? HttpIdentityProbe(),
      _auth = auth ?? _defaultAuth;

  static GoTrueClient _defaultAuth() => Supabase.instance.client.auth;

  final IdentityProbe _probe;
  final GoTrueClient Function() _auth;

  // OAuth client IDs are public identifiers; the CLIENT SECRET must never
  // appear in the app or its dart-defines.
  static String get _googleWebClientId => MobileRuntimeConfig.value(
    'GOOGLE_WEB_CLIENT_ID', fallback: const String.fromEnvironment('GOOGLE_WEB_CLIENT_ID'));
  static String get _googleIosClientId => MobileRuntimeConfig.value(
    'GOOGLE_IOS_CLIENT_ID', fallback: const String.fromEnvironment('GOOGLE_IOS_CLIENT_ID'));

  // google_sign_in v7 initialization must complete before authenticate().
  Future<void>? _googleInitialization;

  /// Supabase calls had no timeout at all, so an unreachable auth host left
  /// the button spinning forever. The identity probe already used 15s; the
  /// credential calls get the same ceiling with a message that says what
  /// actually timed out.
  static const Duration _authTimeout = Duration(seconds: 15);

  Future<T> _guard<T>(Future<T> future, String timeoutMessage) =>
      future.timeout(
        _authTimeout,
        onTimeout: () async {
          throw AuthTimeoutFailure(timeoutMessage);
        },
      );

  /// Fails closed when `Supabase.initialize()` never ran — an unconfigured
  /// build must report an unavailable service, not an empty session that a
  /// caller could mistake for "signed out and everything is fine".
  GoTrueClient get _client {
    try {
      return _auth();
    } on Object {
      // A CONFIGURATION failure, not a network outage. `main.dart` skips
      // Supabase.initialize() when the compile-time defines are absent, and
      // starting run-sitewise.cmd cannot inject values into a compiled app.
      throw const AuthConfigurationFailure();
    }
  }

  @override
  Future<SitewiseUser?> currentUser() async {
    // `currentSession` is a synchronous getter that returns whatever Keystore
    // holds — including an access token that expired while the app was closed.
    // Sending that token to GET /api/v1/auth/me produced a 401 (and a
    // "Session expired" card) on the Sign In screen before anyone had signed
    // in. `getSession()` refreshes an expired token first and resolves to null
    // once nothing usable is left, so an anonymous cold start makes no backend
    // call at all. A refreshed token is still verified by FastAPI below.
    final Session? session;
    try {
      session = await _guard(
        _client.getSession(),
        'Restoring your session took too long. Check your connection and try '
        'again.',
      );
    } on AuthException catch (error) {
      if (!isRejectedRefreshError(error)) {
        // A retryable / 5xx / unknown refresh failure is an outage, not a
        // signed-out user. gotrue keeps the saved session in that case, so
        // surface a connectivity error with Retry rather than silently
        // discarding a valid login.
        throw const NetworkFailure();
      }
      // Supabase definitively rejected the refresh token. That means "no
      // session", not an error the user caused. Drop the stale credentials
      // locally so a restart cannot re-offer them, and return a clean Sign In
      // state without ever calling /auth/me.
      await _discardStaleSession();
      return null;
    }
    if (session == null) return null;
    return _authorize(session);
  }

  @override
  Future<bool> isAuthenticated() async => await currentUser() != null;

  @override
  Future<SitewiseUser> signInWithEmail({
    required String email,
    required String password,
  }) async {
    final normalized = _normalize(email);
    _requirePassword(password);
    AuthResponse response;
    try {
      response = await _guard(
        _client.signInWithPassword(email: normalized, password: password),
        'Signing in took too long. Check your connection and try again.',
      );
    } on AuthException catch (error) {
      throw mapSupabaseError(error, email: normalized);
    } on SocketException {
      throw const NetworkFailure();
    }
    return _authorizeWithSession(response, fallbackEmail: normalized);
  }

  @override
  Future<SitewiseUser> signUpWithEmail({
    required String email,
    required String password,
    String? fullName,
  }) async {
    final normalized = _normalize(email);
    _requirePassword(password);

    final name = fullName?.trim();
    AuthResponse response;
    try {
      // Only `full_name` goes up. Public registration can never assign a
      // role: the backend provisions the profile (entrepreneur for the
      // public flow) and the authoritative value is re-read from `/auth/me`.
      response = await _guard(
        _client.signUp(
          email: normalized,
          password: password,
          data: {if (name != null && name.isNotEmpty) 'full_name': name},
          emailRedirectTo: MobileEndpoints.emailConfirmationRedirect.toString(),
        ),
        'Creating the account took too long. Check your connection and try '
        'again.',
      );
    } on AuthException catch (error) {
      throw mapSupabaseError(error, email: normalized);
    } on SocketException {
      throw const NetworkFailure();
    }

    // A session only exists once the address is confirmed, so there is
    // nothing to authorize and no access to grant.
    return _authorizeWithSession(response, fallbackEmail: normalized);
  }

  @override
  Future<SitewiseUser> signInWithProvider(AuthProvider provider) async {
    if (provider != AuthProvider.google) {
      throw const _GoogleLoginFailure(
        'This sign-in provider is not yet supported on mobile.',
      );
    }
    if (!Platform.isAndroid && !Platform.isIOS) {
      throw const _GoogleLoginFailure(
        'Native Google sign-in is available on Android and iOS only.',
      );
    }
    if (_googleWebClientId.isEmpty ||
        (Platform.isIOS && _googleIosClientId.isEmpty)) {
      throw const _GoogleLoginFailure(
        'Google login is not configured for this build.',
      );
    }

    try {
      // ??= alone would cache a FAILED initialization forever: one transient
      // failure would permanently disable the Google button for the whole
      // process. _initializeGoogleSignIn() clears the slot on failure so the
      // next tap retries cleanly. Cancellation arrives later, from
      // authenticate(), and never touches this slot.
      _googleInitialization ??= _initializeGoogleSignIn();
      await _guard(
        _googleInitialization!,
        'Google sign-in could not be initialized.',
      );

      // This is a native SDK flow. Do NOT set detectSessionInUri=true just to
      // support it: Supabase receives an ID token, not a deep-link callback.
      final account = await GoogleSignIn.instance.authenticate();
      final idToken = account.authentication.idToken;
      if (idToken == null || idToken.isEmpty) {
        throw const _GoogleLoginFailure(
          'Google did not return an identity token. Please try again.',
        );
      }

      // Supabase's Google exchange expects the Google access token as well.
      // Requesting scopes remains within the button-triggered interaction.
      const scopes = <String>['email'];
      final authorization =
          await account.authorizationClient.authorizationForScopes(scopes) ??
          await account.authorizationClient.authorizeScopes(scopes);

      final response = await _guard(
        _client.signInWithIdToken(
          provider: OAuthProvider.google,
          idToken: idToken,
          accessToken: authorization.accessToken,
        ),
        'Supabase did not complete Google sign-in.',
      );

      // Preserve the existing fail-closed FastAPI /api/v1/auth/me role check.
      // No screen is opened on the strength of a Google identity token alone.
      return _authorizeWithSession(response, fallbackEmail: account.email);
    } on GoogleSignInException catch (error) {
      if (error.code == GoogleSignInExceptionCode.canceled) {
        throw const _GoogleLoginFailure(
          'Google sign-in was canceled. You can try again.',
        );
      }
      throw const _GoogleLoginFailure(
        'Google sign-in failed. Check your connection and app configuration.',
      );
    } on AuthException catch (error) {
      // Generic email-password error mapping would mislabel a rejected
      // Google ID token as an invalid password.
      if (error.statusCode == '400') {
        throw const _GoogleLoginFailure(
          'Supabase rejected the Google login. Check the Google provider '
          'and OAuth client ID configuration.',
        );
      }
      throw mapSupabaseError(error);
    } on SocketException {
      throw const NetworkFailure();
    }
  }

  @override
  Future<void> sendPasswordRecoveryEmail(
    String email, {
    String? redirectTo,
  }) async {
    final normalized = _normalize(email);
    try {
      await _guard(
        _client.resetPasswordForEmail(
          normalized,
          redirectTo:
              redirectTo ?? MobileEndpoints.passwordRecoveryRedirect.toString(),
        ),
        'The reset request took too long. Check your connection and try again.',
      );
    } on AuthException catch (error) {
      throw mapSupabaseError(error, email: normalized);
    } on SocketException {
      throw const NetworkFailure();
    }
  }

  @override
  Future<void> signOut() async {
    try {
      // A hung sign-out must not trap the user in a broken session view; the
      // local credential clear is what actually matters here.
      await _guard(_client.signOut(), 'Signing out timed out.');
    } on AuthException {
      // Already signed out server-side: the local clear is what matters.
    } on AuthUnavailableFailure {
      // Same tolerance: the local session clear below still runs.
    }
  }

  // --- internals -----------------------------------------------------------

  /// Best-effort local clear after a rejected refresh token.
  ///
  /// gotrue removes the session itself before rethrowing a non-retryable
  /// refresh error, so this is normally a no-op with no network call; the
  /// explicit call also covers `AuthSessionMissingException`. Any failure is
  /// irrelevant — the caller still fails closed by reporting "no session".
  Future<void> _discardStaleSession() async {
    try {
      await _client.signOut();
    } on Object {
      // Deliberately swallowed: never turn "not signed in" into an error card.
    }
  }

  /// One-time google_sign_in SDK initialization whose FAILURE is retryable:
  /// a failed first attempt clears the cached slot so the next button press
  /// starts a fresh initialization instead of re-awaiting a dead future.
  Future<void> _initializeGoogleSignIn() async {
    try {
      await GoogleSignIn.instance.initialize(
        serverClientId: _googleWebClientId,
        clientId: Platform.isIOS ? _googleIosClientId : null,
      );
    } on Object {
      _googleInitialization = null;
      rethrow;
    }
  }

  Future<SitewiseUser> _authorizeWithSession(
    AuthResponse response, {
    required String fallbackEmail,
  }) async {
    final session = response.session;
    if (session == null) {
      throw EmailConfirmationRequiredFailure(
        email: response.user?.email ?? fallbackEmail,
      );
    }
    return _authorize(session, fallbackEmail: fallbackEmail);
  }

  /// Exchanges a Supabase session for the backend's answer about who this is.
  Future<SitewiseUser> _authorize(
    Session session, {
    String? fallbackEmail,
  }) async {
    final profile = await _probe.fetch(session.accessToken);

    final serverUserId = (profile['user_id'] as String?)?.trim() ?? '';
    if (serverUserId != session.user.id) {
      // The token authenticated, but not as the account the server believes
      // it holds. Drop the session rather than mixing identities.
      await signOut();
      throw const SessionExpiredFailure(
        'The authenticated identity changed. Please sign in again.',
      );
    }

    final status =
        (profile['account_status'] as String?)?.trim().toLowerCase() ?? '';
    if (status != 'active') {
      throw AccountInactiveFailure(
        status: status.isEmpty ? 'unknown' : status,
        email: fallbackEmail ?? session.user.email ?? '',
      );
    }

    return _buildUser(
      profile,
      canonicalRole: _requireRole(profile['role']),
      fallbackEmail: fallbackEmail ?? session.user.email ?? '',
    );
  }

  /// Maps the server's role name onto an [AppRole] name, with no permissive
  /// default: an unrecognised or absent role fails closed rather than
  /// handing out the one workspace this app protects.
  String _requireRole(Object? raw) {
    final name = (raw as String?)?.trim().toLowerCase();
    if (name == null || name.isEmpty) {
      throw const AccountInactiveFailure(
        status: 'no_role',
        message:
            'This account has no role assigned yet. Contact Sitewise support.',
      );
    }
    return switch (name) {
      'entrepreneur' || 'property_owner' || 'user' => 'entrepreneur',
      'admin' || 'administrator' => 'admin',
      'agent' => 'agent',
      _ => throw const AccountInactiveFailure(
        status: 'unknown_role',
        message:
            'This account has an unsupported role. Contact Sitewise support.',
      ),
    };
  }

  SitewiseUser _buildUser(
    Map<String, dynamic> profile, {
    required String canonicalRole,
    required String fallbackEmail,
  }) {
    final email = (profile['email'] as String?)?.trim() ?? '';
    final name = (profile['full_name'] as String?)?.trim() ?? '';
    return SitewiseUser(
      id: profile['user_id'] as String,
      name: name.isNotEmpty ? name : _nameFromEmail(email),
      email: email.isNotEmpty ? email : fallbackEmail,
      role: AppRole.values.firstWhere((r) => r.name == canonicalRole),
      // The value the server reported, already proven active by the caller.
      status: 'Active',
      location: '',
      joinedAt:
          DateTime.tryParse(profile['created_at'] as String? ?? '') ??
          DateTime.now(),
    );
  }

  static void _requirePassword(String password) {
    if (password.length < 6) {
      throw const ValidationFailure(
        'Password must contain at least 6 characters.',
      );
    }
  }

  static String _normalize(String email) => email.trim().toLowerCase();

  static String _nameFromEmail(String email) {
    final handle = email.split('@').first;
    final parts = handle
        .split(RegExp(r'[._\-]+'))
        .where((p) => p.isNotEmpty)
        .toList();
    if (parts.isEmpty) return 'Sitewise User';
    return parts.map((p) => p[0].toUpperCase() + p.substring(1)).join(' ');
  }
}

/// Whether a gotrue refresh failure means the saved credentials are no longer
/// usable, as opposed to the auth host being temporarily unreachable.
///
/// A rejected refresh token (400/401/403, `invalid_grant`, `session_expired`,
/// `refresh_token_*`, ...) is definitive: gotrue has already removed the local
/// session, so the only correct outcome is a clean Sign In form. A retryable
/// fetch error or a 5xx keeps the session intact and must be shown as a
/// connectivity problem with Retry — never as a silent sign-out.
///
/// Exposed for unit tests. It branches on SDK codes only and never lets raw
/// provider text reach a screen.
bool isRejectedRefreshError(AuthException error) {
  if (error is AuthRetryableFetchException) return false;

  final code = error.code?.toLowerCase() ?? '';
  if (code == ErrorCode.sessionExpired.code ||
      code == 'invalid_grant' ||
      code == 'invalid_jwt' ||
      code == 'user_banned' ||
      code == 'user_not_found' ||
      code.contains('refresh_token')) {
    return true;
  }

  final status = error.statusCode;
  return status == '400' || status == '401' || status == '403';
}

/// Translates a Gotrue error into the domain failure that decides where the
/// UI goes. Provider text and status codes never reach a screen.
AppFailure mapSupabaseError(AuthException error, {String? email}) {
  final code = error.code;
  final message = error.message.toLowerCase();

  if (code == ErrorCode.userAlreadyExists.code ||
      code == ErrorCode.emailExists.code ||
      message.contains('already registered') ||
      message.contains('already been registered')) {
    return const DuplicateEmailFailure();
  }
  if (code == ErrorCode.emailNotConfirmed.code ||
      message.contains('email not confirmed')) {
    return EmailConfirmationRequiredFailure(email: email ?? '');
  }
  if (code == ErrorCode.userBanned.code) {
    return const AccountInactiveFailure(
      status: 'suspended',
      message: 'This account has been suspended. Contact Sitewise support.',
    );
  }
  if (code == ErrorCode.weakPassword.code) {
    return const ValidationFailure(
      'That password is too weak. Choose something harder to guess.',
    );
  }
  if (error is AuthSessionMissingException ||
      code == ErrorCode.sessionExpired.code ||
      message.contains('session expired') ||
      message.contains('invalid claim:')) {
    return const SessionExpiredFailure();
  }
  // Checked before the generic 400 branch: a missing session is not a bad
  // password, and telling the user otherwise would send them off to reset it.
  if (code == ErrorCode.userNotFound.code ||
      error.statusCode == '400' ||
      message.contains('invalid login credentials')) {
    return const InvalidCredentialsFailure();
  }
  if (error is AuthRetryableFetchException || error is AuthUnknownException) {
    return const NetworkFailure();
  }
  return const AuthFailure('Sign in failed. Please try again.');
}

/// Safe, user-facing native SDK errors; never surface token/SDK raw details.
class _GoogleLoginFailure extends AuthFailure {
  const _GoogleLoginFailure(super.message);

  @override
  String get userMessage => message;
}
