import '../entities/user.dart';

/// External identity providers Sitewise offers on the auth screen.
enum AuthProvider { apple, google }

/// Domain contract for authentication. Implemented in data/.
///
/// Presentation never talks to Supabase (or any backend) directly — it calls
/// [AuthService], which calls this contract. Swapping the demo implementation
/// for a Supabase-backed one therefore requires no UI change.
abstract class AuthRepository {
  /// Seeded accounts surfaced by the demo auth screen as a hint. Empty when a
  /// real backend is connected ([AppConfig.usesDemoData] == false).
  List<SitewiseUser> get demoAccounts;

  /// The signed-in user, or null when no session is active.
  Future<SitewiseUser?> currentUser();

  /// Convenience flag mirroring [currentUser] != null.
  Future<bool> isAuthenticated();

  /// Email + password sign in. Throws [AppFailure] on invalid credentials.
  Future<SitewiseUser> signInWithEmail({
    required String email,
    required String password,
  });

  /// Creates a new account. Throws [AppFailure] when the email is taken.
  Future<SitewiseUser> signUpWithEmail({
    required String email,
    required String password,
  });

  /// Federated sign in (Apple / Google).
  Future<SitewiseUser> signInWithProvider(AuthProvider provider);

  /// Clears the active session.
  Future<void> signOut();
}
