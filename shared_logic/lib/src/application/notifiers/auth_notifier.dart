import 'package:riverpod/riverpod.dart';

import '../../core/errors/app_failure.dart';
import '../../domain/entities/user.dart';
import '../../domain/repositories/auth_repository.dart';
import '../services/auth_service.dart';
import '../states/auth_state.dart';
import 'providers.dart';

/// Single owner of the app-wide authentication state.
///
/// Both the startup gate and the route guards read this notifier rather than
/// asking [AuthService] themselves, which is what keeps a cold start, a deep
/// link and a mid-session token expiry from disagreeing about who is signed
/// in. [AuthRepository] failures are translated into [AuthStatus] values
/// here so no screen has to inspect exception types.
///
/// Two rules are enforced by construction:
///   * [start] is re-entrant safe — a second call while the first is running
///     is ignored, so two widgets mounting at once cannot race two restores
///     against each other or emit two redirects.
///   * no method ever publishes [AuthStatus.authenticated] from anything but a
///     repository result, and the repository only reports the backend-
///     validated profile.
class AuthNotifier extends Notifier<AuthState> {
  late AuthService _auth;
  bool _started = false;
  bool _starting = false;
  bool _busy = false;

  @override
  AuthState build() {
    _auth = ref.watch(authServiceProvider);
    return AuthState.initializing;
  }

  /// Validate whatever session persistence holds and publish the outcome.
  ///
  /// Re-entrant: a second call while the first is in flight is ignored, and a
  /// call after one has finished is a no-op. Use [retry] to force a re-check.
  Future<void> start() async {
    if (_started || _starting) return;
    await _restore();
  }

  /// Re-runs the restore after a failure the user has acted on (retry button).
  Future<void> retry() => _restore();

  Future<void> _restore() async {
    // One restore at a time: two rapid Retry taps (or the gate and the auth
    // screen both triggering) must not race two /auth/me requests against
    // each other. The in-flight call's result is the one that lands.
    if (_starting) return;
    _starting = true;
    _started = true;
    state = AuthState.initializing;
    try {
      final user = await _auth.currentUser();
      if (!ref.mounted) return;
      state = user == null
          ? const AuthState(status: AuthStatus.unauthenticated)
          : AuthState(status: AuthStatus.authenticated, user: user);
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
    } on AuthConfigurationFailure catch (failure) {
      _publish(_error(AuthErrorKind.configuration, failure.userMessage));
    } on AuthTlsFailure catch (failure) {
      _publish(_error(AuthErrorKind.tls, failure.userMessage));
    } on AuthTimeoutFailure catch (failure) {
      _publish(_error(AuthErrorKind.timeout, failure.userMessage));
    } on NetworkFailure catch (failure) {
      _publish(_error(AuthErrorKind.connectivity, failure.userMessage));
    } on AuthUnavailableFailure catch (failure) {
      _publish(_error(AuthErrorKind.server, failure.userMessage));
    } on AppFailure catch (failure) {
      _publish(_error(AuthErrorKind.unknown, failure.userMessage));
    } catch (_) {
      // "No access was granted" is owned by the screens that render the
      // unavailable state (each phrases it with its own retry guidance), so
      // this fallback states only the cause and never duplicates it.
      _publish(
        _error(AuthErrorKind.unknown, 'Sitewise could not verify your session.'),
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
    () => _auth.signIn(email: email, password: password),
    pendingEmail: email,
  );

  /// Registers a new account. Public registration always creates an
  /// entrepreneur; the role is never taken from the caller.
  Future<bool> signUp({
    required String email,
    required String password,
    String? fullName,
  }) => _attempt(
    () => _auth.signUp(email: email, password: password, fullName: fullName),
    pendingEmail: email,
  );

  Future<bool> signInWithProvider(AuthProvider provider) =>
      _attempt(() => _auth.signInWithProvider(provider));

  /// Ends the session and returns to [AuthStatus.unauthenticated].
  Future<void> signOut() async {
    try {
      await _auth.signOut();
    } on AppFailure {
      // A failed server-side sign-out must still leave the app locked: the
      // local session is cleared below regardless.
    }
    if (!ref.mounted) return;
    state = const AuthState(status: AuthStatus.unauthenticated);
  }

  /// Password recovery is side-channel only: it sends an email and must never
  /// change the signed-in state. Returns the message to display.
  Future<String> recoverPassword(String email, {String? redirectTo}) async {
    try {
      await _auth.sendPasswordRecoveryEmail(email, redirectTo: redirectTo);
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
    _publish(const AuthState(status: AuthStatus.authenticating));
    try {
      final user = await request();
      if (!ref.mounted) return false;
      state = AuthState(status: AuthStatus.authenticated, user: user);
      return true;
    } on EmailConfirmationRequiredFailure catch (failure) {
      if (ref.mounted) {
        _publish(
          AuthState(
            status: AuthStatus.emailConfirmationRequired,
            message: failure.userMessage,
            email: failure.email.isNotEmpty ? failure.email : pendingEmail,
          ),
        );
      }
      return false;
    } on AccountInactiveFailure catch (failure) {
      if (ref.mounted) {
        _publish(
          AuthState(
            status: AuthStatus.accountInactive,
            message: failure.userMessage,
            email: failure.email ?? pendingEmail,
          ),
        );
      }
      return false;
    } on AuthConfigurationFailure catch (failure) {
      if (ref.mounted) {
        _publish(
          _error(
            AuthErrorKind.configuration,
            failure.userMessage,
            email: pendingEmail,
          ),
        );
      }
      return false;
    } on AuthTlsFailure catch (failure) {
      if (ref.mounted) {
        _publish(
          _error(AuthErrorKind.tls, failure.userMessage, email: pendingEmail),
        );
      }
      return false;
    } on AuthTimeoutFailure catch (failure) {
      if (ref.mounted) {
        _publish(
          _error(
            AuthErrorKind.timeout,
            failure.userMessage,
            email: pendingEmail,
          ),
        );
      }
      return false;
    } on NetworkFailure catch (failure) {
      if (ref.mounted) {
        _publish(
          _error(
            AuthErrorKind.connectivity,
            failure.userMessage,
            email: pendingEmail,
          ),
        );
      }
      return false;
    } on AuthUnavailableFailure catch (failure) {
      if (ref.mounted) {
        _publish(
          _error(
            AuthErrorKind.server,
            failure.userMessage,
            email: pendingEmail,
          ),
        );
      }
      return false;
    } on AppFailure catch (failure) {
      // Credentials, duplicates and validation all keep the user on the form.
      if (ref.mounted) {
        _publish(
          AuthState(
            status: AuthStatus.unauthenticated,
            message: failure.userMessage,
            email: pendingEmail,
          ),
        );
      }
      return false;
    } catch (_) {
      if (ref.mounted) {
        _publish(
          _error(
            AuthErrorKind.unknown,
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

  /// Builds a fail-closed error state that also says WHICH component failed.
  /// The message is always a safe, user-facing sentence from [AppFailure].
  AuthState _error(AuthErrorKind kind, String message, {String? email}) =>
      AuthState(
        status: AuthStatus.error,
        message: message,
        errorKind: kind,
        email: email,
      );

  void _publish(AuthState next) {
    if (ref.mounted) state = next;
  }

  /// Drops an unusable session so a restart cannot re-offer it.
  Future<void> _invalidate(AuthState next) async {
    try {
      await _auth.signOut();
    } catch (_) {
      // Best effort — the emitted state still denies access.
    }
    if (!ref.mounted) return;
    state = next;
  }
}

final authNotifierProvider = NotifierProvider<AuthNotifier, AuthState>(
  AuthNotifier.new,
);
