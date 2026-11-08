import 'package:provider/provider.dart';
import 'package:flutter/material.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../application/state/auth_view_model.dart';
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
/// [AuthViewModel] from the provider scope rather than asking the repository,
/// which is what keeps the guard, the auth screen and the dashboard reporting
/// the same session.
///
/// While the outcome is unknown it shows a spinner — never the page beneath.
class AuthGuard extends StatefulWidget {
  const AuthGuard({super.key, required this.access, required this.builder});

  final RouteAccess access;

  /// Built only once entry is granted, so a signed-out visit never even
  /// constructs the protected page.
  final WidgetBuilder builder;

  @override
  State<AuthGuard> createState() => _AuthGuardState();
}

class _AuthGuardState extends State<AuthGuard> {
  /// The provider-owned, app-wide session state. Read once: the route below
  /// the navigator root always resolves the same instance.
  late final AuthViewModel _auth = context.read<AuthViewModel>();

  bool _redirecting = false;

  @override
  void initState() {
    super.initState();
    // A protected route can be entered without ever passing through the
    // startup gate (deep link, state restore). Kick the single restore here;
    // `start()` ignores repeat calls, so this cannot race the gate.
    _auth.start();
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
    // The whole session state is watched, so an expiry mid-session re-checks
    // authority here instead of leaving a guarded screen mounted.
    final auth = context.watch<AuthViewModel>();
    if (widget.access == RouteAccess.public) return widget.builder(context);

    final state = auth.state;
    switch (state.status) {
      case AuthStatus.authenticated:
        final role = state.role;
        // No role means no authority: only the backend-assigned one may open
        // a workspace, and a missing one is never guessed at.
        if (role == null || mobileHomeRouteFor(role) == null) {
          return StaffWorkspaceRequiredView(role: role, auth: auth);
        }
        return widget.builder(context);
      case AuthStatus.accountInactive:
        return AccountStatusView(message: state.message, auth: auth);
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
        return AuthUnavailableView(auth: auth);
    }
  }
}

/// Shown while the guard decides, so a protected route is never painted first.
class _AuthPendingView extends StatelessWidget {
  const _AuthPendingView();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: Center(child: CircularProgressIndicator()));
  }
}
