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
      'Sitewise could not reach the sign-in service. No access was granted — check your connection and try again.';
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
