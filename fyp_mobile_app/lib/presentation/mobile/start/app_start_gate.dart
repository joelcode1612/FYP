import 'package:shared_logic/shared_logic.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../application/services/service_locator.dart';
import '../../../core/routing/mobile_role.dart';
import '../../../core/theme/sitewise_theme.dart';
import '../../shared/widgets/sitewise_brand.dart';
import 'auth_blocking_views.dart';

/// Startup decision point (the "Sitewise splash" in the flow).
///
/// Authentication is resolved FIRST and on the server, before any other part
/// of the app is allowed to render:
///
///   no session, or a rejected one .......... Sign In (/auth)
///   session unverifiable .................. retry screen, access withheld
///   account suspended or pending .......... account-status screen
///   signed in, onboarding incomplete ...... /onboarding
///   signed in as an Entrepreneur .......... that role's home route
///   signed in as Admin or Agent ........... Staff Web Portal notice
///
/// Nothing below the first line is reachable while the restore is still
/// running — the same screen shows a spinner, never a glimpse of a dashboard.
class AppStartGate extends StatefulWidget {
  final AppCubit appState;
  final AuthCubit auth;

  const AppStartGate({super.key, required this.appState, required this.auth});

  @override
  State<AppStartGate> createState() => _AppStartGateState();
}

class _AppStartGateState extends State<AppStartGate> {
  bool? _onboardingDone;

  /// One navigation per gate: a rebuild while the frame is pending must not
  /// queue a second replacement.
  bool _navigated = false;

  @override
  void initState() {
    super.initState();
    // Idempotent: if a route guard already began the restore, this joins it
    // rather than starting a second one.
    widget.auth.start();
  }

  Future<void> _readOnboarding() async {
    final completed = await ServiceLocator.onboardingRepo
        .hasCompletedOnboarding();
    if (mounted) setState(() => _onboardingDone = completed);
  }

  void _go(String route) {
    if (_navigated) return;
    _navigated = true;
    // Deferred: the decision can complete on a microtask inside build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Navigator.of(context).pushReplacementNamed(route);
    });
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<AuthCubit, AuthState>(
      bloc: widget.auth,
      builder: (context, auth) {
        switch (auth.status) {
          case AuthStatus.authenticated:
            final role = auth.role;
            if (role == null || mobileHomeRouteFor(role) == null) {
              return StaffWorkspaceRequiredView(
                role: role,
                auth: widget.auth,
                appState: widget.appState,
              );
            }
            return _afterSignIn(role);
          case AuthStatus.accountInactive:
            return AccountStatusView(message: auth.message, auth: widget.auth);
          case AuthStatus.error:
            return AuthUnavailableView(auth: widget.auth);
          case AuthStatus.sessionExpired:
          case AuthStatus.unauthenticated:
          case AuthStatus.emailConfirmationRequired:
            _go('/auth');
            return _splash();
          case AuthStatus.initializing:
          case AuthStatus.authenticating:
            return _splash();
        }
      },
    );
  }

  /// Signed in and verified: onboarding only ever sits between this point and
  /// the workspace, never before authentication.
  Widget _afterSignIn(AppRole role) {
    if (_onboardingDone == null) {
      _readOnboarding();
      return _splash();
    }
    final home = mobileHomeRouteFor(role)!;
    if (_onboardingDone == false) {
      _go('/onboarding');
      return _splash();
    }
    widget.appState.setRole(role);
    _go(home);
    return _splash();
  }

  Widget _splash() => Scaffold(
    backgroundColor: SitewiseColors.background,
    body: const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SitewiseBrand(fontSize: 20),
          SizedBox(height: 18),
          SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2.4),
          ),
        ],
      ),
    ),
  );
}
