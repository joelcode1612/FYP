/// Shared failure types. Repositories throw these; ViewModels translate
/// them into error states. No exceptions leak raw SDK errors to UI.
abstract class AppFailure implements Exception {
  final String message;
  final int? statusCode;
  final String? backendCode;

  /// A write may have reached the server; callers must reconcile or reuse its
  /// exact idempotency identity, never silently create another operation.
  final bool outcomeUnknown;
  const AppFailure(
    this.message, {
    this.statusCode,
    this.backendCode,
    this.outcomeUnknown = false,
  });

  /// Short, user-facing text for this failure class. Deliberately generic:
  /// it never includes SDK, HTTP or stack details.
  String get userMessage => 'Something went wrong. Please try again.';

  @override
  String toString() => message;
}

class NetworkFailure extends AppFailure {
  const NetworkFailure([super.message = 'Unable to reach the server.']);
  const NetworkFailure.transport(String message, {bool outcomeUnknown = false})
    : super(message, outcomeUnknown: outcomeUnknown);

  @override
  String get userMessage =>
      'Unable to reach Sitewise. Check your connection and try again.';
}

/// Thrown when a feature is unavailable because the app is running on static
/// demo data instead of the authenticated backend.
///
/// Lives with the other failure types, not with the transport port: an
/// application controller reports it as state and must not import a network
/// file only to name the error.
class DemoModeFailure extends AppFailure {
  const DemoModeFailure() : super('Network is disabled in demo-data mode.');
}

/// The request reached the Sitewise service but was refused for lack of a
/// valid session (HTTP 401/403). Distinct from [NetworkFailure] so the UI
/// can say "sign in again" instead of "check your connection".
class UnauthorizedFailure extends AppFailure {
  const UnauthorizedFailure([super.message = 'Your session has expired.']);
  const UnauthorizedFailure.response(
    String message, {
    int? statusCode,
    String? backendCode,
  }) : super(message, statusCode: statusCode, backendCode: backendCode);

  @override
  String get userMessage => 'Your session has expired. Please sign in again.';
}

/// The request reached the service and the service reported a server-side
/// problem (HTTP 5xx / database failure). Not a connection problem and not
/// an authorization problem.
class ServiceFailure extends AppFailure {
  const ServiceFailure([super.message = 'The Sitewise service hit a problem.']);
  const ServiceFailure.response(
    String message, {
    int? statusCode,
    String? backendCode,
  }) : super(message, statusCode: statusCode, backendCode: backendCode);

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

/// A business-rule conflict returned by FastAPI (HTTP 409). This is NOT a
/// network error. FastAPI's `detail` is a deliberately user-facing reason.
class ConflictFailure extends AppFailure {
  const ConflictFailure(String message, {String? backendCode})
    : super(message, statusCode: 409, backendCode: backendCode);

  @override
  String get userMessage => message;
}

class NotFoundFailure extends AppFailure {
  const NotFoundFailure([super.message = 'The requested item was not found.']);
  const NotFoundFailure.response(
    String message, {
    int? statusCode,
    String? backendCode,
  }) : super(message, statusCode: statusCode, backendCode: backendCode);

  @override
  String get userMessage => 'We could not find what you were looking for.';
}

class ValidationFailure extends AppFailure {
  const ValidationFailure([super.message = 'Some fields need attention.']);
  const ValidationFailure.response(
    String message, {
    int? statusCode,
    String? backendCode,
  }) : super(message, statusCode: statusCode, backendCode: backendCode);

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

  const AuthFailure.response(
    String message, {
    int? statusCode,
    String? backendCode,
  }) : super(message, statusCode: statusCode, backendCode: backendCode);

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
      'This invited account must finish email verification, MFA and onboarding before it can enter the workspace.',
    _ => 'This account is not active. Contact Sitewise support.',
  };
}

/// A trusted invitation lifecycle response from the onboarding endpoint.
/// The backend code drives recovery; the message is already user-facing.
class StaffOnboardingFailure extends AuthFailure {
  const StaffOnboardingFailure(
    String message, {
    int? statusCode,
    String? backendCode,
  }) : super.response(message, statusCode: statusCode, backendCode: backendCode);

  @override
  String get userMessage => message;
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

class ThrottledFailure extends AppFailure {
  const ThrottledFailure(String message, {String? backendCode})
    : super(message, statusCode: 429, backendCode: backendCode);
}

/// One safe HTTP classification shared by browser, SSR and mobile transports.
/// This carries operation metadata; it never changes authentication or authority.
AppFailure apiOperationFailure({
  int? status,
  String? code,
  String? message,
  bool mutation = false,
}) {
  final safeCode =
      code != null && RegExp(r'^[A-Za-z0-9_.:-]{1,100}$').hasMatch(code)
      ? code
      : null;
  final text = message != null && message.trim().isNotEmpty
      ? message
      : 'The data service could not complete this request.';
  if (const {
    'staff_mfa_required',
    'invitation_expired',
    'invitation_revoked',
    'invitation_not_accepted',
    'invitation_ownership',
    'identity_mismatch',
    'onboarding_suspended',
    'owner_invitation_required',
    'invitation_invalid',
    'invitation_changed',
    'onboarding_forbidden',
  }.contains(safeCode)) {
    return StaffOnboardingFailure(
      text,
      statusCode: status,
      backendCode: safeCode,
    );
  }
  return switch (status) {
    null => NetworkFailure.transport(
      'The service response could not be verified. Reload saved data before starting another operation.',
      outcomeUnknown: mutation,
    ),
    401 || 403 => UnauthorizedFailure.response(
      text,
      statusCode: status,
      backendCode: safeCode,
    ),
    404 => NotFoundFailure.response(
      text,
      statusCode: status,
      backendCode: safeCode,
    ),
    409 => ConflictFailure(text, backendCode: safeCode),
    422 => ValidationFailure.response(
      text,
      statusCode: status,
      backendCode: safeCode,
    ),
    429 => ThrottledFailure(text, backendCode: safeCode),
    _ => ServiceFailure.response(
      text,
      statusCode: status,
      backendCode: safeCode,
    ),
  };
}

// ---------------------------------------------------------------------------
// Second-factor (authenticator) failures.
//
// These are deliberately separate from the sign-in failures above: the user is
// already signed in, and the only thing that failed is the step-up. Telling
// them their "sign-in failed" would send them off to reset a password that
// works. Each maps to a different recovery action on the authenticator screen,
// so callers branch on the TYPE rather than on provider message text.
// ---------------------------------------------------------------------------

/// The authenticator code did not match. The session is untouched and the user
/// can simply try the next code.
class MfaCodeRejectedFailure extends AuthFailure {
  const MfaCodeRejectedFailure([
    super.message = 'That authenticator code was not accepted.',
  ]);

  @override
  String get userMessage =>
      'That code was not accepted. Enter the current code from your '
      'authenticator app — a code is only valid for about 30 seconds.';
}

/// The challenge the code was checked against has expired, so no code can
/// succeed until a new one is requested.
class MfaChallengeExpiredFailure extends AuthFailure {
  const MfaChallengeExpiredFailure([
    super.message = 'The authenticator challenge expired.',
  ]);

  @override
  String get userMessage =>
      'This verification took too long and expired. Request a new code.';
}

/// The account cannot start another enrolment, or the request contradicts the
/// factors it already has (e.g. a second enrolment while one is in progress).
class MfaEnrollmentConflictFailure extends AuthFailure {
  const MfaEnrollmentConflictFailure([
    super.message = 'The authenticator enrolment could not be started.',
  ]);

  @override
  String get userMessage =>
      'The authenticator setup could not be started. Finish or cancel the '
      'enrolment you already began, then try again.';
}
