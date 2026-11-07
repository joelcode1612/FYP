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

  const AuthState({
    this.status = AuthStatus.initializing,
    this.user,
    this.message,
    this.email,
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
      other.email == email;

  @override
  int get hashCode => Object.hash(status, user, message, email);

  @override
  String toString() =>
      'AuthState(${status.name}, user: ${user?.email}, message: $message)';
}
