import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_logic/shared_logic.dart';

/// The app-wide authentication state as a Flutter view model.
///
/// [AuthCubit] stays the single owner of the auth rules — the re-entrant
/// [start], the "only a repository result can produce `authenticated`"
/// invariant, and every `AuthStatus` a failure maps to. This class adds nothing
/// to that logic; it is the notification adapter that lets screens subscribe
/// with `provider` instead of a bloc widget: every cubit emission becomes one
/// `notifyListeners` call, and every read delegates to `cubit.state` so a
/// guard that inspects the state synchronously sees exactly what it saw before.
///
/// The cubit instance is owned by [ServiceLocator] (the composition root and
/// the tests swap it, never this class), so [dispose] cancels only the local
/// subscription and leaves the cubit alive.
class AuthViewModel extends ChangeNotifier {
  final AuthCubit _cubit;
  late final StreamSubscription<AuthState> _subscription;

  AuthViewModel({required AuthCubit cubit}) : _cubit = cubit {
    _subscription = cubit.stream.listen((_) => notifyListeners());
  }

  AuthState get state => _cubit.state;

  AuthStatus get status => state.status;

  SitewiseUser? get user => state.user;

  /// The backend-assigned role, or null while there is no verified session.
  AppRole? get role => state.role;

  String? get message => state.message;

  String? get email => state.email;

  bool get isAuthenticated => state.isAuthenticated;

  Future<void> start() => _cubit.start();

  Future<void> retry() => _cubit.retry();

  Future<bool> signIn({required String email, required String password}) =>
      _cubit.signIn(email: email, password: password);

  Future<bool> signUp({
    required String email,
    required String password,
    String? fullName,
  }) => _cubit.signUp(email: email, password: password, fullName: fullName);

  Future<bool> signInWithProvider(AuthProvider provider) =>
      _cubit.signInWithProvider(provider);

  Future<void> signOut() => _cubit.signOut();

  Future<String> recoverPassword(String email, {String? redirectTo}) =>
      _cubit.recoverPassword(email, redirectTo: redirectTo);

  @override
  Future<void> dispose() async {
    await _subscription.cancel();
    super.dispose();
  }
}
