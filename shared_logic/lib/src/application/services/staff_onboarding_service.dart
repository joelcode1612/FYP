import '../../domain/repositories/staff_onboarding_repository.dart';

class StaffOnboardingService {
  final StaffOnboardingRepository repository;

  const StaffOnboardingService(this.repository);

  Future<void> complete() => repository.complete();
}
