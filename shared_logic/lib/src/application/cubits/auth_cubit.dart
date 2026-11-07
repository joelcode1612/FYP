import 'package:bloc/bloc.dart';

import '../../core/errors/app_failure.dart';
import '../../domain/entities/user.dart';
import '../../domain/repositories/auth_repository.dart';
import '../services/auth_service.dart';
import '../states/auth_state.dart';

/// Single owner of the app-wide authentication state.
///
/// Both the startup gate and the route guards read this cubit rather than
/// asking [AuthService] themselves, which is what keeps a cold start, a deep
/// link and a mid-session token expiry from disagreeing about who is signed
/// in. [AuthRepository] failures are translated into [AuthStatus] values
/// here so no screen has to inspect exception types.
///
/// Two rules are enforced by construction:
///   * [start] is re-entrant safe — a second call while the first is running
///     is ignored, so two widgets mounting at once cannot race two restores
///     against each other or emit two redirects.
///   * no method ever emits [AuthStatus.authenticated] from anything but a
///     repository result, and the repository only reports the backend-
///     validated profile.
class AuthCubit extends Cubit<AuthState> {
  AuthCubit({required this.auth}) : super(AuthState.initializing);

  final AuthService auth;

  bool _started = false;
  bool _starting = false;
  bool _busy = false;

  /// Validate whatever session persistence holds and publish the outcome.
  ///
  /// Re-entrant: a second call while the first is in flight is ignored, and a
  /// call after one has finished is a no-op. That is what stops two widgets
  /// mounting at once (the start gate and a route guard) from racing two
  /// restores and emitting two redirects. Use [retry] to force a re-check.
  Future<void> start() async {
    if (_started || _starting) return;
    await _restore();
  }

  /// Re-runs the restore after a failure the user has acted on (retry button).
  Future<void> retry() => _restore();

  Future<void> _restore() async {
    _starting = true;
    _started = true;
    emit(AuthState.initializing);
    try {
      final user = await auth.currentUser();
      if (isClosed) return;
      emit(
        user == null
            ? const AuthState(status: AuthStatus.unauthenticated)
            : AuthState(status: AuthStatus.authenticated, user: user),
      );
    } on AccountInactiveFailure catch (failure) {
      await _invalidate(
        AuthState(
          status: AuthStatus.accountInactive,
          message: failure.userMessage,
          email: failure.email,
        ),
      );
    } on SessionExpiredFailure catch (failure) {
      await _invalidate(
        AuthState(status: AuthStatus.sessionExpired, message: failure.userMessage),
      );
    } on AuthUnavailableFailure catch (failure) {
      emit(AuthState(status: AuthStatus.error, message: failure.userMessage));
    } on NetworkFailure catch (failure) {
      emit(AuthState(status: AuthStatus.error, message: failure.userMessage));
    } on AppFailure catch (failure) {
      emit(AuthState(status: AuthStatus.error, message: failure.userMessage));
    } catch (_) {
      emit(
        const AuthState(
          status: AuthStatus.error,
          message:
              'Sitewise could not verify your session. No access was granted.',
        ),
      );
    } finally {
      _starting = false;
    }
  }

  /// Signs in and returns whether the caller may now navigate onward.
  Future<bool> signIn({
    required String email,
    required String password,
  }) => _attempt(
    () => auth.signIn(email: email, password: password),
    pendingEmail: email,
  );

  /// Registers a new account. Public registration always creates an
  /// entrepreneur; the role is never taken from the caller.
  Future<bool> signUp({
    required String email,
    required String password,
    String? fullName,
  }) => _attempt(
    () => auth.signUp(email: email, password: password, fullName: fullName),
    pendingEmail: email,
  );

  Future<bool> signInWithProvider(AuthProvider provider) =>
      _attempt(() => auth.signInWithProvider(provider));

  /// Ends the session and returns to [AuthStatus.unauthenticated].
  Future<void> signOut() async {
    try {
      await auth.signOut();
    } on AppFailure {
      // A failed server-side sign-out must still leave the app locked: the
      // local session is cleared below regardless.
    }
    if (isClosed) return;
    emit(const AuthState(status: AuthStatus.unauthenticated));
  }

  /// Password recovery is side-channel only: it sends an email and must never
  /// change the signed-in state. Returns the message to display.
  Future<String> recoverPassword(String email, {String? redirectTo}) async {
    try {
      await auth.sendPasswordRecoveryEmail(email, redirectTo: redirectTo);
      return 'If that address has a Sitewise account, a reset link is on its way.';
    } on AppFailure catch (failure) {
      return failure.userMessage;
    } catch (_) {
      return 'Sitewise could not send the reset email. Please try again.';
    }
  }

  Future<bool> _attempt(
    Future<SitewiseUser> Function() request, {
    String? pendingEmail,
  }) async {
    if (_busy) return false;
    _busy = true;
    emit(const AuthState(status: AuthStatus.authenticating));
    try {
      final user = await request();
      if (isClosed) return false;
      emit(AuthState(status: AuthStatus.authenticated, user: user));
      return true;
    } on EmailConfirmationRequiredFailure catch (failure) {
      if (!isClosed) {
        emit(
          AuthState(
            status: AuthStatus.emailConfirmationRequired,
            message: failure.userMessage,
            email: failure.email.isNotEmpty ? failure.email : pendingEmail,
          ),
        );
      }
      return false;
    } on AccountInactiveFailure catch (failure) {
      if (!isClosed) {
        emit(
          AuthState(
            status: AuthStatus.accountInactive,
            message: failure.userMessage,
            email: failure.email ?? pendingEmail,
          ),
        );
      }
      return false;
    } on AuthUnavailableFailure catch (failure) {
      if (!isClosed) {
        emit(
          AuthState(
            status: AuthStatus.error,
            message: failure.userMessage,
            email: pendingEmail,
          ),
        );
      }
      return false;
    } on NetworkFailure catch (failure) {
      if (!isClosed) {
        emit(
          AuthState(
            status: AuthStatus.error,
            message: failure.userMessage,
            email: pendingEmail,
          ),
        );
      }
      return false;
    } on AppFailure catch (failure) {
      // Credentials, duplicates and validation all keep the user on the form.
      if (!isClosed) {
        emit(
          AuthState(
            status: AuthStatus.unauthenticated,
            message: failure.userMessage,
            email: pendingEmail,
          ),
        );
      }
      return false;
    } catch (_) {
      if (!isClosed) {
        emit(
          AuthState(
            status: AuthStatus.error,
            message:
                'Sitewise could not complete that request. Please try again.',
            email: pendingEmail,
          ),
        );
      }
      return false;
    } finally {
      _busy = false;
    }
  }

  /// Drops an unusable session so a restart cannot re-offer it.
  Future<void> _invalidate(AuthState next) async {
    try {
      await auth.signOut();
    } catch (_) {
      // Best effort — the emitted state still denies access.
    }
    if (isClosed) return;
    emit(next);
  }
}
