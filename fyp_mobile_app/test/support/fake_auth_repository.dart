import 'package:shared_logic/shared_logic.dart';

/// The profile a successful sign-in resolves to by default. Mirrors what the
/// backend returns for a public registration: role `entrepreneur`, status
/// `active`.
SitewiseUser testUser({
  String id = 'ent-1',
  String name = 'Sarah Tan',
  String email = 'sarah@artisanbrew.my',
  AppRole role = AppRole.entrepreneur,
  String status = 'Active',
}) => SitewiseUser(
  id: id,
  name: name,
  email: email,
  role: role,
  status: status,
  location: 'Petaling Jaya, Selangor',
  joinedAt: DateTime(2024, 9, 5),
);

/// In-memory [AuthRepository] for tests.
///
/// It stands in for the Supabase + backend pair: whichever failure is set on
/// [signInFailure], [signUpFailure], [restoreFailure] or [recoveryFailure] is
/// thrown instead of succeeding, so a test can drive the exact outcome the
/// real service would report. Nothing here fabricates a session — a user only
/// exists after a call that did not throw.
class FakeAuthRepository implements AuthRepository {
  /// The session a restart would find.
  SitewiseUser? user;

  AppFailure? signInFailure;
  AppFailure? signUpFailure;
  AppFailure? restoreFailure;
  AppFailure? providerFailure;
  AppFailure? recoveryFailure;

  /// Thrown by [signOut] as well, to prove the cubit still locks the app.
  AppFailure? signOutFailure;

  /// What a successful call resolves to (an admin test sets this to an admin).
  SitewiseUser result = testUser();

  int restoreCalls = 0;
  /// How many times credentials were actually sent (sign in, sign up or provider).
  int credentialCalls = 0;
  int recoveryCalls = 0;
  int signOutCalls = 0;
  String? lastSignInEmail;
  String? lastSignInPassword;
  String? lastSignUpEmail;
  String? lastSignUpFullName;
  String? lastRecoveryEmail;

  @override
  Future<SitewiseUser?> currentUser() async {
    restoreCalls++;
    final failure = restoreFailure;
    if (failure != null) throw failure;
    return user;
  }

  @override
  Future<bool> isAuthenticated() async => user != null;

  @override
  Future<SitewiseUser> signInWithEmail({
    required String email,
    required String password,
  }) async {
    credentialCalls++;
    lastSignInEmail = email;
    lastSignInPassword = password;
    final failure = signInFailure;
    if (failure != null) throw failure;
    return user = SitewiseUser(
      id: result.id,
      name: result.name,
      email: email,
      role: result.role,
      status: result.status,
      location: result.location,
      joinedAt: result.joinedAt,
    );
  }

  @override
  Future<SitewiseUser> signUpWithEmail({
    required String email,
    required String password,
    String? fullName,
  }) async {
    credentialCalls++;
    lastSignUpEmail = email;
    lastSignUpFullName = fullName;
    final failure = signUpFailure;
    if (failure != null) throw failure;
    // Public registration is always an entrepreneur, whatever the caller asked.
    return user = SitewiseUser(
      id: result.id,
      name: fullName ?? result.name,
      email: email,
      role: AppRole.entrepreneur,
      status: result.status,
      location: result.location,
      joinedAt: DateTime.now(),
    );
  }

  @override
  Future<SitewiseUser> signInWithProvider(AuthProvider provider) async {
    credentialCalls++;
    final failure = providerFailure;
    if (failure != null) throw failure;
    return user = result;
  }

  @override
  Future<void> sendPasswordRecoveryEmail(
    String email, {
    String? redirectTo,
  }) async {
    recoveryCalls++;
    lastRecoveryEmail = email;
    final failure = recoveryFailure;
    if (failure != null) throw failure;
  }

  @override
  Future<void> signOut() async {
    signOutCalls++;
    user = null;
    final failure = signOutFailure;
    if (failure != null) throw failure;
  }
}
