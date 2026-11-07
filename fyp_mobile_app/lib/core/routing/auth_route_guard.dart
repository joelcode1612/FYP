import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../presentation/mobile/start/auth_blocking_views.dart';
import 'mobile_role.dart';

/// How a route was reached before the user had a session.
///
/// Held outside the navigator so a deep link survives the redirect to Sign
/// In and is only replayed once the account is known to be allowed there.
class AuthPendingDestination {
  const AuthPendingDestination({required this.route, this.arguments});

  final String route;
  final Object? arguments;

  static AuthPendingDestination? _current;

  static AuthPendingDestination? get current => _current;

  static void save(String route, Object? arguments) {
    _current = AuthPendingDestination(route: route, arguments: arguments);
  }

  /// Consumes the saved destination and returns it only when the signed-in
  /// role may actually enter it; otherwise the caller falls back to the role
  /// home. An argument is consumed exactly once, so a stale deep link cannot
  /// replay after a later sign-in.
  static String? takeFor(AppRole? role) {
    final pending = _current;
    _current = null;
    if (pending == null || role == null) return null;
    final home = mobileHomeRouteFor(role);
    if (home == null) return null;
    final allowed =
        pending.route == home ||
        pending.route.startsWith('$home/') ||
        pending.route == '/capture' ||
        pending.route == '/tour-preview';
    return allowed ? pending.route : null;
  }

  @visibleForTesting
  static void clear() => _current = null;
}

/// Who may enter a route.
enum RouteAccess {
  /// Reachable with no session (Sign In, password recovery, the landing page).
  public,

  /// Requires a verified session in a role this app can actually open.
  workspace,
}

/// Route-level authentication gate.
///
/// `AppStartGate` only decides the *first* screen; this wraps every other
/// generated route, so a manual `pushNamed`, a saved deep link or a session
/// that expires mid-use cannot land on a protected page. It reads the shared
/// [AuthCubit] rather than asking the repository, which is what keeps the
/// guard, the auth screen and the dashboard reporting the same session.
///
/// While the outcome is unknown it shows a spinner — never the page beneath.
class AuthGuard extends StatefulWidget {
  const AuthGuard({
    super.key,
    required this.auth,
    required this.access,
    required this.builder,
    this.appState,
  });

  final AuthCubit auth;
  final RouteAccess access;

  /// Built only once entry is granted, so a signed-out visit never even
  /// constructs the protected page.
  final WidgetBuilder builder;
  final AppCubit? appState;

  @override
  State<AuthGuard> createState() => _AuthGuardState();
}

class _AuthGuardState extends State<AuthGuard> {
  StreamSubscription<AuthState>? _sub;
  bool _redirecting = false;

  @override
  void initState() {
    super.initState();
    _sub = widget.auth.stream.listen((_) {
      if (mounted) setState(() {});
    });
    // A protected route can be entered without ever passing through the
    // startup gate (deep link, state restore). Kick the single restore here;
    // `start()` ignores repeat calls, so this cannot race the gate.
    widget.auth.start();
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    _sub = null;
    super.dispose();
  }

  void _redirectToAuth(AuthPendingDestination? requested) {
    if (_redirecting) return;
    _redirecting = true;
    if (requested != null) {
      AuthPendingDestination.save(requested.route, requested.arguments);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Navigator.of(context).pushReplacementNamed('/auth');
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.access == RouteAccess.public) return widget.builder(context);

    final state = widget.auth.state;
    switch (state.status) {
      case AuthStatus.authenticated:
        final role = state.role;
        // No role means no authority: only the backend-assigned one may open
        // a workspace, and a missing one is never guessed at.
        if (role == null || mobileHomeRouteFor(role) == null) {
          return StaffWorkspaceRequiredView(
            role: role,
            auth: widget.auth,
            appState: widget.appState,
          );
        }
        return widget.builder(context);
      case AuthStatus.accountInactive:
        return AccountStatusView(message: state.message, auth: widget.auth);
      case AuthStatus.sessionExpired:
      case AuthStatus.unauthenticated:
      case AuthStatus.emailConfirmationRequired:
        final settings = ModalRoute.of(context)?.settings;
        _redirectToAuth(
          settings?.name == null
              ? null
              : AuthPendingDestination(
                  route: settings!.name!,
                  arguments: settings.arguments,
                ),
        );
        return const _AuthPendingView();
      case AuthStatus.initializing:
      case AuthStatus.authenticating:
        return const _AuthPendingView();
      case AuthStatus.error:
        return AuthUnavailableView(auth: widget.auth);
    }
  }
}

/// Shown while the guard decides, so a protected route is never painted first.
class _AuthPendingView extends StatelessWidget {
  const _AuthPendingView();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: CircularProgressIndicator()),
    );
  }
}
