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

  /// Whether the verified profile may enter an active workspace. A pending
  /// invited Owner/Agent returned by [currentUser] is restricted to onboarding
  /// and must not make this true.
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
  ///
  /// [accountPurpose] is the *registration preference* chosen in the mobile
  /// three-step flow ("entrepreneur" / "listing_provider"). It is written to
  /// Supabase user metadata for onboarding only — it is NOT a role, and the
  /// backend continues to assign the authoritative role from its own profile
  /// row. Implementations must never turn this value into a permission.
  Future<SitewiseUser> signUpWithEmail({
    required String email,
    required String password,
    String? fullName,
    String? accountPurpose,
    bool acceptTerms = false,
  });

  /// Federated sign in (Apple / Google).
  ///
  /// [accountPurpose] carries the same non-authoritative registration
  /// preference through the OAuth flow, so a Google account created from the
  /// sign-up funnel keeps the choice the user made at step 1. It is optional:
  /// login and existing OAuth accounts pass nothing.
  Future<SitewiseUser> signInWithProvider(
    AuthProvider provider, {
    String? accountPurpose,
  });

  /// Re-sends the sign-up confirmation email for an address whose account is
  /// still waiting for verification. This never changes auth state and never
  /// marks the address as verified — only the provider's emailed link can do
  /// that. Throws an [AppFailure] subtype on failure.
  Future<void> resendSignupVerificationEmail(String email);

  /// Sends a password-recovery email. [redirectTo] is the completion URL the
  /// provider puts in the link, when the flow finishes outside this app.
  Future<void> sendPasswordRecoveryEmail(String email, {String? redirectTo});

  /// Clears the active session.
  Future<void> signOut();
}
