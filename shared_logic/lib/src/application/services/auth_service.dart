import 'package:shared_logic/shared_logic.dart';

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
  }) => repo.signUpWithEmail(
    email: email,
    password: password,
    fullName: fullName,
  );

  Future<SitewiseUser> signInWithProvider(AuthProvider provider) =>
      repo.signInWithProvider(provider);

  Future<void> sendPasswordRecoveryEmail(String email, {String? redirectTo}) =>
      repo.sendPasswordRecoveryEmail(email, redirectTo: redirectTo);

  Future<void> signOut() => repo.signOut();
}
