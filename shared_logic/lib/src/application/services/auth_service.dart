import '../../domain/entities/user.dart';
import '../../domain/repositories/auth_repository.dart';

/// Authentication application layer. Widgets (onboarding, auth screen, role
/// menu) talk to this — never to a backend client directly.

class AuthService {
  final AuthRepository repo;

  const AuthService(this.repo);

  Future<SitewiseUser?> currentUser() => repo.currentUser();

  Future<bool> isAuthenticated() => repo.isAuthenticated();

  Future<SitewiseUser> signIn({
    required String email,
    required String password,
  }) => repo.signInWithEmail(email: email, password: password);

  Future<SitewiseUser> signUp({
    required String email,
    required String password,
    String? fullName,
    String? accountPurpose,
    bool acceptTerms = false,
  }) => repo.signUpWithEmail(
    email: email,
    password: password,
    fullName: fullName,
    accountPurpose: accountPurpose,
    acceptTerms: acceptTerms,
  );

  Future<SitewiseUser> signInWithProvider(
    AuthProvider provider, {
    String? accountPurpose,
  }) => repo.signInWithProvider(provider, accountPurpose: accountPurpose);

  /// See [AuthRepository.resendSignupVerificationEmail]. Side-channel only:
  /// no session, role or verification state is changed by this call.
  Future<void> resendSignupVerificationEmail(String email) =>
      repo.resendSignupVerificationEmail(email);

  Future<void> sendPasswordRecoveryEmail(String email, {String? redirectTo}) =>
      repo.sendPasswordRecoveryEmail(email, redirectTo: redirectTo);

  Future<void> signOut() => repo.signOut();
}
