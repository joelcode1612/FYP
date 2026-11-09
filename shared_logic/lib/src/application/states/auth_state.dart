import '../../domain/entities/app_role.dart';
import '../../domain/entities/user.dart';

/// Every authentication condition the app must be able to route on.
///
/// The set is deliberately exhaustive so no screen has to invent its own
/// interpretation of "signed in": [authenticated] is the only state that may
/// reach application functionality, and [initializing] exists so a cold start
/// can show a spinner instead of briefly exposing a dashboard.
enum AuthStatus {
  /// The stored session is being validated against the backend.
  initializing,

  /// No session, or the session was rejected.
  unauthenticated,

  /// A sign-in or sign-up request is in flight.
  authenticating,

  /// A verified session with a backend-assigned, active profile.
  authenticated,

  /// Registration succeeded but the address must be confirmed first; no
  /// session exists yet.
  emailConfirmationRequired,

  /// A previously valid session expired or was revoked.
  sessionExpired,

  /// The profile exists but is suspended or not yet activated.
  accountInactive,

  /// The authentication service could not be reached or failed unexpectedly.
  error;

  bool get isActiveSession => this == AuthStatus.authenticated;
}

/// WHY an [AuthStatus.error] happened.
///
/// The status alone only says "verification failed". Screens need to know
/// whether the build is misconfigured, the host is unreachable, the request
/// timed out, TLS failed, or the backend answered with an error — otherwise
/// every problem is reported as the same generic "service unavailable" and a
/// developer cannot act on it. Values carry no SDK/HTTP/credential detail,
/// so they are safe to branch on in the UI.
enum AuthErrorKind {
  /// No failure, or a non-error status.
  none,

  /// Compile-time configuration missing or invalid (Supabase defines).
  configuration,

  /// Connection refused, DNS failure, no route, or missing INTERNET access.
  connectivity,

  /// The request reached its timeout ceiling.
  timeout,

  /// TLS handshake or certificate failure.
  tls,

  /// Backend 5xx, unreadable profile, or an unavailable identity service.
  server,

  /// Anything else; still fails closed.
  unknown,
}

/// Immutable snapshot of the shared authentication state.
///
/// One instance is published app-wide by [AuthCubit] so startup, the auth
/// screens, the route guards, the dashboard and sign-out all read the same
/// truth instead of each asking the repository.
class AuthState {
  final AuthStatus status;

  /// Present only for [AuthStatus.authenticated].
  final SitewiseUser? user;

  /// Safe, user-facing explanation of a non-authenticated state. Never a raw
  /// SDK or HTTP detail.
  final String? message;

  /// The address a pending confirmation or recovery refers to.
  final String? email;

  /// Classification of an [AuthStatus.error]. [AuthErrorKind.none] elsewhere.
  final AuthErrorKind errorKind;

  const AuthState({
    this.status = AuthStatus.initializing,
    this.user,
    this.message,
    this.email,
    this.errorKind = AuthErrorKind.none,
  });

  static const AuthState initializing = AuthState(
    status: AuthStatus.initializing,
  );

  bool get isAuthenticated => status == AuthStatus.authenticated && user != null;

  /// The backend-assigned role, or null while there is no verified session.
  ///
  /// This is read from [user], which the repository only ever populates from
  /// the server profile — never from anything the client chose.
  AppRole? get role => user?.role;

  @override
  bool operator ==(Object other) =>
      other is AuthState &&
      other.status == status &&
      other.user == user &&
      other.message == message &&
      other.email == email &&
      other.errorKind == errorKind;

  @override
  int get hashCode => Object.hash(status, user, message, email, errorKind);

  @override
  String toString() =>
      'AuthState(${status.name}, user: ${user?.email}, message: $message, '
      'errorKind: ${errorKind.name})';
}
