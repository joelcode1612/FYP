/// Shared failure types. Repositories throw these; ViewModels translate
/// them into error states. No exceptions leak raw SDK errors to UI.
abstract class AppFailure implements Exception {
  final String message;
  const AppFailure(this.message);

  /// Short, user-facing text for this failure class. Deliberately generic:
  /// it never includes SDK, HTTP or stack details.
  String get userMessage => 'Something went wrong. Please try again.';

  @override
  String toString() => message;
}

class NetworkFailure extends AppFailure {
  const NetworkFailure([super.message = 'Unable to reach the server.']);

  @override
  String get userMessage =>
      'Unable to reach Sitewise. Check your connection and try again.';
}

/// The request reached the Sitewise service but was refused for lack of a
/// valid session (HTTP 401/403). Distinct from [NetworkFailure] so the UI
/// can say "sign in again" instead of "check your connection".
class UnauthorizedFailure extends AppFailure {
  const UnauthorizedFailure([super.message = 'Your session has expired.']);

  @override
  String get userMessage => 'Your session has expired. Please sign in again.';
}

/// The request reached the service and the service reported a server-side
/// problem (HTTP 5xx / database failure). Not a connection problem and not
/// an authorization problem.
class ServiceFailure extends AppFailure {
  const ServiceFailure([super.message = 'The Sitewise service hit a problem.']);

  @override
  String get userMessage =>
      'The Sitewise service hit a problem on our side. Please try again.';
}

/// A response arrived but could not be parsed into the expected contract —
/// a malformed body is a contract problem, not a connection problem.
class ResponseFormatFailure extends AppFailure {
  const ResponseFormatFailure([
    super.message = 'The server response could not be read.',
  ]);

  @override
  String get userMessage =>
      'The server sent a response Sitewise could not read. Please try again.';
}

class NotFoundFailure extends AppFailure {
  const NotFoundFailure([super.message = 'The requested item was not found.']);

  @override
  String get userMessage => 'We could not find what you were looking for.';
}

class ValidationFailure extends AppFailure {
  const ValidationFailure([super.message = 'Some fields need attention.']);

  @override
  String get userMessage =>
      'Some details need attention. Please check and try again.';
}

class CacheFailure extends AppFailure {
  const CacheFailure([super.message = 'Unable to load local data.']);

  @override
  String get userMessage =>
      'We could not read your saved data. Please try again.';
}

// ---------------------------------------------------------------------------
// Authentication failures.
//
// These carry the *shape* of an auth problem only. The message is already a
// safe, user-facing sentence — never a Gotrue/HTTP/stack detail — so screens
// may show `message` directly. The distinction matters for routing: an
// invalid password keeps the user on the form, an expired session or an
// inactive account sends them away, and an unavailable service must never
// grant access.
// ---------------------------------------------------------------------------

class AuthFailure extends AppFailure {
  const AuthFailure([super.message = 'We could not sign you in.']);

  @override
  String get userMessage =>
      'We could not sign you in. Please check your details and try again.';
}

/// Wrong email or password, or an identity that does not exist.
class InvalidCredentialsFailure extends AuthFailure {
  const InvalidCredentialsFailure([
    super.message = 'Incorrect email or password.',
  ]);

  @override
  String get userMessage => 'Incorrect email or password.';
}

/// The address already belongs to an account.
class DuplicateEmailFailure extends AuthFailure {
  const DuplicateEmailFailure([
    super.message = 'An account already exists for that email. Log in instead.',
  ]);

  @override
  String get userMessage =>
      'An account already exists for that email. Try logging in instead.';
}

/// Registration succeeded but the address must be confirmed before any
/// session exists. Carries the address so the UI can tell the user where to
/// look, and so "resend" can be offered.
class EmailConfirmationRequiredFailure extends AuthFailure {
  final String email;

  const EmailConfirmationRequiredFailure({
    required this.email,
    String message =
        'Please confirm your email address to activate your account.',
  }) : super(message);

  @override
  String get userMessage =>
      'Please confirm your email address to activate your account.';
}

/// A stored session was rejected (expired, revoked or no longer valid).
class SessionExpiredFailure extends AuthFailure {
  const SessionExpiredFailure([
    super.message = 'Your session has expired. Please sign in again.',
  ]);

  @override
  String get userMessage => 'Your session has expired. Please sign in again.';
}

/// The backend profile exists but is not usable (suspended or pending).
class AccountInactiveFailure extends AuthFailure {
  final String status;

  /// The address the attempt was made with, so the screen can name it.
  final String? email;

  const AccountInactiveFailure({
    required this.status,
    this.email,
    String message = 'This account is not active.',
  }) : super(message);

  @override
  String get userMessage => switch (status) {
    'suspended' =>
      'This account has been suspended. Contact Sitewise support to restore access.',
    'pending' =>
      'This account is not active yet. Sitewise must activate it before you can sign in.',
    _ => 'This account is not active. Contact Sitewise support.',
  };
}

/// The authentication service itself could not be reached (offline, DNS,
/// 5xx, or an unconfigured build). Callers must fail closed: showing the
/// dashboard here would be granting access without verification.
class AuthUnavailableFailure extends AuthFailure {
  const AuthUnavailableFailure([
    super.message = 'The sign-in service is currently unavailable.',
  ]);

  @override
  String get userMessage =>
      'Sitewise could not reach the sign-in service — check your connection and try again.';
}

/// A BUILD problem, not an outage: `Supabase.initialize()` never ran because
/// this Flutter binary was launched without its compile-time defines.
/// Starting the backend launcher cannot change a compiled-in value, so the UI
/// must say so instead of blaming the network.
class AuthConfigurationFailure extends AuthUnavailableFailure {
  const AuthConfigurationFailure([
    super.message = 'This build has no sign-in configuration.',
  ]);

  @override
  String get userMessage =>
      'This build has no sign-in configuration. Start Flutter with '
      '--dart-define-from-file=fyp_mobile_app/config/dev.json — starting '
      'run-sitewise.cmd alone cannot supply Dart compile-time values.';
}

/// A request that reached the timeout ceiling. Distinct from a refused
/// connection (host not listening) and from a server-side 5xx.
class AuthTimeoutFailure extends AuthUnavailableFailure {
  const AuthTimeoutFailure([
    super.message = 'The SiteWise service took too long to respond.',
  ]);

  @override
  String get userMessage =>
      'The SiteWise service took too long to respond. Check that '
      'run-sitewise.cmd is running, then try again.';
}

/// TLS handshake / certificate failure. Grouping this with "no internet"
/// hides certificate and HTTPS/HTTP mismatches from the developer.
class AuthTlsFailure extends AuthUnavailableFailure {
  const AuthTlsFailure([
    super.message = 'The secure connection could not be established.',
  ]);

  @override
  String get userMessage =>
      'A secure connection to the SiteWise service could not be established. '
      'Check the API URL scheme and certificate.';
}

/// Converts *any* thrown object into a readable, non-technical message.
///
/// Widgets and cubits must call this instead of interpolating `e.toString()`,
/// which can surface raw SDK/network text to the user. Unknown errors always
/// collapse to [fallback] so no implementation detail leaks.
String readableFailure(Object error, {required String fallback}) {
  if (error is AppFailure) return error.userMessage;
  return fallback;
}
