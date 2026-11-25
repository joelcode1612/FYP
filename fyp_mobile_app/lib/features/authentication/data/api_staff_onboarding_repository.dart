import 'package:shared_logic/shared_logic.dart';

class ApiStaffOnboardingRepository implements StaffOnboardingRepository {
  final ApiClient client;

  const ApiStaffOnboardingRepository(this.client);

  @override
  Future<void> complete() async {
    await client.post('/api/v1/staff/onboarding/complete', const {});
  }
}
