import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:shared_logic/shared_logic.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/config/mobile_endpoints.dart';

/// Server-side identity lookup used to confirm what a local session claims.
///
/// Supabase proves *who* the token belongs to; only SiteWise knows *what* that
/// person may do. Split out so [SupabaseAuthRepository] can be exercised
/// against canned responses without a live backend.
abstract class IdentityProbe {
  /// Returns the decoded `/api/v1/auth/me` payload for [accessToken].
  ///
  /// Throws [SessionExpiredFailure] on 401, [AccountInactiveFailure] on 403
  /// and [AuthUnavailableFailure] on 5xx or an unreachable host.
  Future<Map<String, dynamic>> fetch(String accessToken);
}

class HttpIdentityProbe implements IdentityProbe {
  HttpIdentityProbe({http.Client? client, Uri? endpoint})
    : _client = client ?? http.Client(),
      _endpoint = endpoint ?? MobileEndpoints.profileUri;

  final http.Client _client;
  final Uri _endpoint;

  @override
  Future<Map<String, dynamic>> fetch(String accessToken) async {
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
      throw const AuthUnavailableFailure(
        'The Sitewise server took too long to respond.',
      );
    } on SocketException {
      throw const NetworkFailure();
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
        throw AuthUnavailableFailure(
          'The identity service responded with status ${response.statusCode}.',
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

  /// Fails closed when `Supabase.initialize()` never ran — an unconfigured
  /// build must report an unavailable service, not an empty session that a
  /// caller could mistake for "signed out and everything is fine".
  GoTrueClient get _client {
    try {
      return _auth();
    } on Object {
      throw const AuthUnavailableFailure(
        'This build has no sign-in service configured. Set SUPABASE_URL and '
        'SUPABASE_PUBLISHABLE_KEY before running the app.',
      );
    }
  }

  @override
  Future<SitewiseUser?> currentUser() async {
    final session = _client.currentSession;
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
      response = await _client.signInWithPassword(
        email: normalized,
        password: password,
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
      response = await _client.signUp(
        email: normalized,
        password: password,
        data: {
          if (name != null && name.isNotEmpty) 'full_name': name,
        },
        emailRedirectTo: MobileEndpoints.emailConfirmationRedirect.toString(),
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
    // Mobile has no OAuth link handler yet, so a federated sign-in cannot be
    // completed honestly here. It says so rather than fabricating a session.
    throw AuthFailure(
      'Sign in with ${provider.name.toUpperCase()} is not available in the '
      'mobile app yet. Use your email and password instead.',
    );
  }

  @override
  Future<void> sendPasswordRecoveryEmail(
    String email, {
    String? redirectTo,
  }) async {
    final normalized = _normalize(email);
    try {
      await _client.resetPasswordForEmail(
        normalized,
        redirectTo:
            redirectTo ??
            MobileEndpoints.passwordRecoveryRedirect.toString(),
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
      await _client.signOut();
    } on AuthException {
      // Already signed out server-side: the local clear is what matters.
    }
  }

  // --- internals -----------------------------------------------------------

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

    final status = (profile['account_status'] as String?)?.trim().toLowerCase() ?? '';
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
