import 'package:shared_logic/shared_logic.dart';
import 'package:flutter/material.dart';


/// The five onboarding stages that precede authentication. Authentication is
/// deliberately NOT a step here — it is a separate feature the flow opens.

enum OnboardingStep {
  introduction,
  businessPreferences,
  locationIntelligence,
  tour360,
  getStarted,
}

/// Which tab the auth screen should open on when onboarding hands off.
enum AuthEntryPoint { login, signUp }

/// Owns onboarding progression: the [PageController], the current page and
/// the completion/skip hand-off. Individual pages stay presentation-only.
///
/// It never performs navigation itself — it emits [onAuthRequested] and the
/// host page (`OnboardingFlowPage`) routes. It also never talks to Supabase:
/// completion is persisted through [OnboardingRepository].
class OnboardingController extends ChangeNotifier {
  OnboardingController({required this.onboarding});

  final OnboardingRepository onboarding;

  /// Set by the host page so the controller can request navigation to auth.
  void Function(AuthEntryPoint entry)? onAuthRequested;

  static const List<OnboardingStep> steps = OnboardingStep.values;

  static int get pageCount => OnboardingStep.values.length;

  final PageController pageController = PageController();

  int _index = 0;
  bool _leaving = false;

  int get index => _index;
  int get lastIndex => pageCount - 1;
  bool get isLastStep => _index == lastIndex;
  bool get canGoBack => _index > 0;

  /// Called from `PageView.onPageChanged`. Swiping only moves the indicator —
  /// it never marks onboarding complete.
  void onPageChanged(int value) {
    if (value == _index) return;
    _index = value;
    notifyListeners();
  }

  /// Advance one step; on the final step this hands off to Sign Up.
  Future<void> next() async {
    if (isLastStep) {
      await openAuth(AuthEntryPoint.signUp);
      return;
    }
    await _animateTo(_index + 1);
  }

  /// Go back one step (used by the hardware/keyboard back affordance).
  Future<void> previous() async {
    if (!canGoBack) return;
    await _animateTo(_index - 1);
  }

  /// Skip: mark onboarding complete, then hand off to authentication.
  Future<void> skip() => openAuth(AuthEntryPoint.login);

  /// Single exit path for Get Started / Log In / Sign Up / Skip. This is the
  /// only place onboarding is marked complete.
  Future<void> openAuth(AuthEntryPoint entry) async {
    if (_leaving) return;
    _leaving = true;
    try {
      await onboarding.completeOnboarding();
    } catch (_) {
      // Persistence is best effort; the user still proceeds to auth.
    } finally {
      _leaving = false;
    }
    onAuthRequested?.call(entry);
  }

  Future<void> _animateTo(int target) => pageController.animateToPage(
    target,
    duration: const Duration(milliseconds: 320),
    curve: Curves.easeOutCubic,
  );

  @override
  void dispose() {
    pageController.dispose();
    super.dispose();
  }
}
