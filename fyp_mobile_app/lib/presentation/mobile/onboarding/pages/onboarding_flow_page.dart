import 'package:shared_logic/shared_logic.dart';
import 'package:flutter/material.dart';

import '../../../../application/onboarding/onboarding_controller.dart';
import '../../../../application/services/service_locator.dart';
import '../../../../core/theme/sitewise_theme.dart';
import 'onboarding_360_tour_page.dart';
import 'onboarding_business_preferences_page.dart';
import 'onboarding_get_started_page.dart';
import 'onboarding_intro_page.dart';
import 'onboarding_location_intelligence_page.dart';

/// Mobile onboarding host. Owns the [PageView] and delegates all progression
/// and completion logic to [OnboardingController]. The individual pages are
/// presentation-only and never perform navigation themselves.
///
/// On exit (Get Started / Log In / Sign Up / Skip) the controller marks
/// onboarding complete and this page routes to the separate `/auth` feature.

class OnboardingFlowPage extends StatefulWidget {
  final AppCubit appState;

  /// Injectable for tests; when null the page builds one from [ServiceLocator].
  final OnboardingController? controller;

  const OnboardingFlowPage({
    super.key,
    required this.appState,
    this.controller,
  });

  @override
  State<OnboardingFlowPage> createState() => _OnboardingFlowPageState();
}

class _OnboardingFlowPageState extends State<OnboardingFlowPage> {
  late final OnboardingController _controller;
  late final bool _ownsController;

  @override
  void initState() {
    super.initState();
    _ownsController = widget.controller == null;
    _controller =
        widget.controller ??
        OnboardingController(onboarding: ServiceLocator.onboardingRepo);
    _controller.onAuthRequested = _openAuth;
  }

  void _openAuth(AuthEntryPoint entry) {
    if (!mounted) return;
    Navigator.of(context).pushNamed('/auth', arguments: entry.name);
  }

  void _onPageChanged(int value) {
    _controller.onPageChanged(value);
    // Refresh so PopScope.canPop tracks whether an in-flow step remains.
    setState(() {});
  }

  @override
  void dispose() {
    if (_ownsController) _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // Within the flow, system back steps to the previous onboarding page;
      // on the first page it pops the route (exits the app when onboarding is
      // the root, as it is on a first launch).
      canPop: !_controller.canGoBack,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _controller.previous();
      },
      child: Scaffold(
        backgroundColor: SitewiseColors.background,
        body: SafeArea(
          child: PageView(
            controller: _controller.pageController,
            onPageChanged: _onPageChanged,
            children: [
              OnboardingIntroPage(
                onSkip: _controller.skip,
                onNext: _controller.next,
              ),
              OnboardingBusinessPreferencesPage(
                onSkip: _controller.skip,
                onNext: _controller.next,
              ),
              OnboardingLocationIntelligencePage(
                onSkip: _controller.skip,
                onNext: _controller.next,
              ),
              Onboarding360TourPage(
                onSkip: _controller.skip,
                onNext: _controller.next,
              ),
              OnboardingGetStartedPage(
                onSkip: _controller.skip,
                onLogin: () => _controller.openAuth(AuthEntryPoint.login),
                onSignUp: () => _controller.openAuth(AuthEntryPoint.signUp),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
