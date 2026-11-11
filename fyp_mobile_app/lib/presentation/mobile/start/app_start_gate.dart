import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';
import '../../../core/bootstrap/app_bootstrap.dart';
import '../../../core/bootstrap/startup_trace.dart';
import '../../../core/config/dev_auth_bypass.dart';

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
///   session unverifiable .................. Sign In + non-blocking error
///                                           notice (the saved session is
///                                           KEPT — an unreachable backend
///                                           must not log anyone out); a
///                                           workspace route itself stays
///                                           locked by [AuthGuard]
///   account suspended or pending .......... account-status screen
///   signed in, onboarding incomplete ...... /onboarding
///   signed in as an Entrepreneur .......... that role's home route
///   signed in as Admin or Agent ........... Staff Web Portal notice
///
/// Nothing below the first line is reachable while the restore is still
/// running — the same screen shows a spinner, never a glimpse of a dashboard.
///
/// Since Supabase initialization no longer blocks `runApp`, this gate is the
/// visible owner of that wait: it holds the branded splash through the
/// bootstrap AND the backend identity check. Showing UI promptly and granting
/// access only after verification are therefore independent.
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

  /// Set once auth has resolved far enough to know the draft namespace.
  bool _draftsScoped = false;

  /// In-flight boot restore of the persistent drafts.
  Future<void>? _draftsRestore;

  /// Guards the one-shot splash hold while that restore finishes.
  bool _draftsWaited = false;

  /// One bootstrap wait per gate instance (a rebuild must not queue a second
  /// asynchronous restore).
  bool _bootStarted = false;

  @override
  void initState() {
    super.initState();

    // Development Demo Mode signs nobody in: drafts stay device-scoped and
    // are restored immediately.
    if (devAuthBypassEnabled) {
      ServiceLocator.restoreDrafts();
      return;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || devAuthBypassEnabled || _bootStarted) return;
      _bootStarted = true;
      StartupTrace.mark('gate_bootstrap_wait_start');
      // The UI is already on screen. Wait for the single Supabase bootstrap
      // before asking the notifier to restore/verify the session; the auth
      // service wrapper enforces the same ordering for AuthGuard, the auth
      // screen and Retry, so only one restore ever runs.
      await AppBootstrap.ready;
      if (!mounted) return;
      StartupTrace.mark('gate_bootstrap_ready');
      await ref.read(authNotifierProvider.notifier).start();
    });
  }

  /// Upper bound on the onboarding-flag read, mirroring
  /// [ServiceLocator.draftRestoreTimeout]. The flag lives behind
  /// `path_provider`'s platform channel; a stalled or unavailable channel would
  /// otherwise leave `_onboardingDone` null forever and hold this gate on the
  /// splash permanently.
  static const Duration _onboardingReadTimeout = Duration(seconds: 2);

  /// One in-flight read at a time — `build` re-runs while the flag is null.
  bool _onboardingReading = false;

  Future<void> _readOnboarding() async {
    if (_onboardingReading) return;
    _onboardingReading = true;
    var completed = false;
    try {
      completed = await ServiceLocator.onboardingRepo
          .hasCompletedOnboarding()
          .timeout(_onboardingReadTimeout);
    } catch (_) {
      // Unreadable store: show the intro again rather than trapping the user
      // on the splash. The flow is informational and always exits to the
      // workspace, so this degrades instead of blocking.
      completed = false;
    }
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
    // Development-only: enter the Entrepreneur workspace directly.
    if (devAuthBypassEnabled) {
      _go('/entrepreneur', enterRole: AppRole.entrepreneur);
      return _splash();
    }

    final state = ref.watch(authNotifierProvider);
    _scopeDrafts(state);
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
        // NOT a full-screen trap. A temporarily unreachable backend (offline
        // device, wrong API_BASE_URL, backend starting up) must still let the
        // user reach the Sign In screen: /auth renders the reason as a
        // non-blocking notice with a Retry action, and the saved session is
        // preserved by the notifier. Access is not weakened — no workspace
        // route may open, because AuthGuard keeps rendering its own
        // AuthUnavailableView for workspace access while the status is error.
        _go('/auth');
        return _splash();
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

  /// User-scopes the draft store once the resolved session is known (§4):
  /// drafts saved under one account never leak into another's, and sign-out
  /// falls back to the shared `device` namespace. Pure id re-scoping — it
  /// never deletes anything.
  ///
  /// Restoring is deferred until the status leaves initializing/authenticating,
  /// because the persisted drafts live under the *account* namespace —
  /// reading them while the store still says `device` would miss them.
  void _scopeDrafts(AuthState state) {
    final resolved =
        state.status != AuthStatus.initializing &&
        state.status != AuthStatus.authenticating;
    if (!resolved || _draftsScoped) return;
    _draftsScoped = true;
    ServiceLocator.scopeDraftsToAccount(state.user?.id);
    // §4: rehydrate persistent form state (preferences + assessment draft)
    // under the now-known namespace. The workspace navigation waits for it
    // (a local file read — milliseconds), so the first screen that reads
    // preferences or the assessment draft sees the restored values.
    _draftsRestore = ServiceLocator.restoreDrafts();
  }

  /// Signed in and verified: onboarding only ever sits between this point and
  /// the workspace, never before authentication.
  Widget _afterSignIn(AppRole role) {
    // Hold the splash until the draft restore finishes so the workspace's
    // first read of preferences/the assessment draft cannot race the file
    // read. Failures inside restoreDrafts never propagate (it swallows them).
    if (_draftsRestore != null && !_draftsWaited) {
      _draftsWaited = true;
      _draftsRestore!.whenComplete(() {
        if (!mounted) return;
        setState(() {}); // re-run build, now with drafts restored
      });
      return _splash();
    }
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
