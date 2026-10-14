import 'package:shared_logic/shared_logic.dart';
import '../datasources/local/onboarding_local_data_source.dart';

/// Bridges the domain contract to the local persistence primitive. No logic
/// beyond delegation — the data source owns the storage details.

class OnboardingRepositoryImpl implements OnboardingRepository {
  final OnboardingLocalDataSource local;

  const OnboardingRepositoryImpl(this.local);

  @override
  Future<bool> hasCompletedOnboarding() => local.hasCompletedOnboarding();

  @override
  Future<void> completeOnboarding() => local.setOnboardingCompleted();

  @override
  Future<void> resetOnboarding() => local.resetOnboarding();
}
