/// Domain contract for the mobile first-run onboarding state.
///
/// Onboarding completion is a *local, device-level* flag — deliberately
/// separate from authentication. A user who completed (or skipped) onboarding
/// and later logs out must NOT be shown onboarding again.
abstract class OnboardingRepository {
  /// True once the user has intentionally left the onboarding flow.
  Future<bool> hasCompletedOnboarding();

  /// Persists the completion flag. Called on Get Started / Log In / Sign Up /
  /// Skip — never on a swipe between onboarding pages.
  Future<void> completeOnboarding();

  /// Clears the flag (used by tests and a future "replay onboarding" action).
  Future<void> resetOnboarding();
}
