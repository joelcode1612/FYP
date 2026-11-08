import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';

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
class AppStartGate extends ConsumerStatefulWidget {
  const AppStartGate({super.key});

  @override
  ConsumerState<AppStartGate> createState() => _AppStartGateState();
}

class _AppStartGateState extends ConsumerState<AppStartGate> {
  bool? _onboardingDone;

  /// One navigation per gate: a rebuild while the frame is pending must not
  /// queue a second replacement.
  bool _navigated = false;

  @override
  void initState() {
    super.initState();
    // Idempotent: if a route guard already began the restore, this joins it
    // rather than starting a second one. Deferred because a provider must not
    // be modified inside the build lifecycle; the splash frame is unconditional.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(authNotifierProvider.notifier).start();
    });
  }

  Future<void> _readOnboarding() async {
    final completed = await ServiceLocator.onboardingRepo
        .hasCompletedOnboarding();
    if (mounted) setState(() => _onboardingDone = completed);
  }

  void _go(String route, {AppRole? enterRole}) {
    if (_navigated) return;
    _navigated = true;
    // Deferred: the decision can complete on a microtask inside build, and a
    // notifier must not change state while the tree is being built.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (enterRole != null) {
        ref.read(appNotifierProvider.notifier).setRole(enterRole);
      }
      Navigator.of(context).pushReplacementNamed(route);
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(authNotifierProvider);
    switch (state.status) {
      case AuthStatus.authenticated:
        final role = state.role;
        if (role == null || mobileHomeRouteFor(role) == null) {
          return StaffWorkspaceRequiredView(role: role);
        }
        return _afterSignIn(role);
      case AuthStatus.accountInactive:
        return AccountStatusView(message: state.message);
      case AuthStatus.error:
        return const AuthUnavailableView();
      case AuthStatus.sessionExpired:
      case AuthStatus.unauthenticated:
      case AuthStatus.emailConfirmationRequired:
        _go('/auth');
        return _splash();
      case AuthStatus.initializing:
      case AuthStatus.authenticating:
        return _splash();
    }
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
    _go(home, enterRole: role);
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
