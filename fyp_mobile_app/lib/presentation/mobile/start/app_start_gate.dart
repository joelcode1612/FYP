import 'package:shared_logic/shared_logic.dart';
import 'package:flutter/material.dart';

import '../../../application/services/service_locator.dart';
import '../../../core/theme/sitewise_theme.dart';
import '../../shared/widgets/sitewise_brand.dart';

/// Startup decision point (the "Sitewise splash" in the flow).
///
///   onboarding not completed -> /onboarding
///   onboarding completed, not authenticated -> /auth
///   authenticated -> the role's home route
///
/// The web tree that used to branch here lives in the Jaspr app now; this
/// gate serves the Flutter app only.

class AppStartGate extends StatefulWidget {
  final AppCubit appState;

  const AppStartGate({super.key, required this.appState});

  @override
  State<AppStartGate> createState() => _AppStartGateState();
}

class _AppStartGateState extends State<AppStartGate> {
  bool _resolved = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_resolved) return;
    _resolved = true;
    _resolve();
  }

  Future<void> _resolve() async {
    final completed = await ServiceLocator.onboardingRepo
        .hasCompletedOnboarding();
    if (!mounted) return;
    if (!completed) {
      _go('/onboarding');
      return;
    }

    final user = await ServiceLocator.auth.currentUser();
    if (!mounted) return;
    if (user == null) {
      _go('/auth');
      return;
    }

    widget.appState.setRole(user.role);
    _go(user.role.homeRoute);
  }

  void _go(String route) {
    if (!mounted) return;
    // Defer to after the current frame: _resolve() may complete on a
    // microtask that still runs inside the build phase.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Navigator.of(context).pushReplacementNamed(route);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
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
}
