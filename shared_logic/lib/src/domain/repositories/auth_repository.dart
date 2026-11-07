import '../entities/user.dart';

/// External identity providers Sitewise offers on the auth screen.
enum AuthProvider { apple, google }

/// Domain contract for authentication. Implemented in data/.
///
/// Presentation never talks to Supabase (or any backend) directly — it calls
/// [AuthService], which calls this contract. Swapping the demo implementation
/// for a Supabase-backed one therefore requires no UI change.
///
/// Every method reports failures by throwing an [AppFailure] subtype — the
/// auth-specific ones ([InvalidCredentialsFailure], [DuplicateEmailFailure],
/// [EmailConfirmationRequiredFailure], [SessionExpiredFailure],
/// [AccountInactiveFailure], [AuthUnavailableFailure]) — so callers can route
/// on the *kind* of problem instead of parsing strings.
abstract class AuthRepository {
  /// The signed-in user, or null when no session is active.
  ///
  /// Implementations backed by a server must verify the stored session and
  /// return the *backend-assigned* profile rather than whatever the client
  /// last cached, so a revoked, expired or downgraded account cannot keep
  /// working across a restart. Throws [AuthUnavailableFailure] when the
  /// service cannot be reached — never a silent "not signed in".
  Future<SitewiseUser?> currentUser();

  /// Convenience flag mirroring [currentUser] != null.
  Future<bool> isAuthenticated();

  /// Email + password sign in. Throws [InvalidCredentialsFailure] on wrong
  /// credentials and [AccountInactiveFailure] for a suspended or pending
  /// account.
  Future<SitewiseUser> signInWithEmail({
    required String email,
    required String password,
  });

  /// Creates a new account. Throws [DuplicateEmailFailure] when the email is
  /// taken and [EmailConfirmationRequiredFailure] when the provider requires
  /// address confirmation before a session exists.
  ///
  /// [fullName] is stored on the profile when the implementation supports it;
  /// implementations must never accept a role from the client.
  Future<SitewiseUser> signUpWithEmail({
    required String email,
    required String password,
    String? fullName,
  });

  /// Federated sign in (Apple / Google).
  Future<SitewiseUser> signInWithProvider(AuthProvider provider);

  /// Sends a password-recovery email. [redirectTo] is the completion URL the
  /// provider puts in the link, when the flow finishes outside this app.
  Future<void> sendPasswordRecoveryEmail(String email, {String? redirectTo});

  /// Clears the active session.
  Future<void> signOut();
}
