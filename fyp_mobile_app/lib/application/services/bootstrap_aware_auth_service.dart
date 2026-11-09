import 'package:shared_logic/shared_logic.dart';

import '../../core/bootstrap/app_bootstrap.dart';
import '../../core/bootstrap/startup_trace.dart';

/// Composition-root decorator that serializes authentication behind the
/// one-shot Supabase bootstrap.
///
/// Three independent widgets kick `AuthNotifier.start()` at cold start (the
/// startup gate, `AuthGuard` and the auth screen), and Retry can run later.
/// Now that `Supabase.initialize()` is no longer awaited before `runApp`, any
/// of them could otherwise read `Supabase.instance` too early and publish a
/// spurious "not configured" failure. Every call routed through this class
/// awaits the SAME memoised [AppBootstrap.ready] future first.
///
/// This is the only place the wait is enforced, so the presentation layer,
/// shared [AuthNotifier] and repository contracts stay untouched. It does
/// not weaken authorization: `currentUser()` still ends in the FastAPI
/// `/api/v1/auth/me` check inside `SupabaseAuthRepository`.
class BootstrapAwareAuthService extends AuthService {
  BootstrapAwareAuthService(super.repo);

  Future<T> _afterBootstrap<T>(Future<T> Function() action) async {
    await AppBootstrap.ready;
    StartupTrace.mark('bootstrap_ready');
    return action();
  }

  @override
  Future<SitewiseUser?> currentUser() => _afterBootstrap(() async {
    StartupTrace.mark('session_restore_start');
    try {
      return await super.currentUser();
    } finally {
      StartupTrace.mark('session_restore_end');
      StartupTrace.report('auth_resolved');
    }
  });

  @override
  Future<bool> isAuthenticated() =>
      _afterBootstrap(() => super.isAuthenticated());

  @override
  Future<SitewiseUser> signIn({
    required String email,
    required String password,
  }) => _afterBootstrap(() => super.signIn(email: email, password: password));

  @override
  Future<SitewiseUser> signUp({
    required String email,
    required String password,
    String? fullName,
  }) => _afterBootstrap(
    () => super.signUp(email: email, password: password, fullName: fullName),
  );

  @override
  Future<SitewiseUser> signInWithProvider(AuthProvider provider) =>
      _afterBootstrap(() => super.signInWithProvider(provider));

  @override
  Future<void> sendPasswordRecoveryEmail(String email, {String? redirectTo}) =>
      _afterBootstrap(
        () => super.sendPasswordRecoveryEmail(email, redirectTo: redirectTo),
      );

  @override
  Future<void> signOut() => _afterBootstrap(() => super.signOut());
}
