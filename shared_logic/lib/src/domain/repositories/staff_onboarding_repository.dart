abstract class StaffOnboardingRepository {
  /// Completes the server-verified invitation lifecycle for the current
  /// pending Owner/Agent. Workspace access still requires an `/auth/me` refresh.
  Future<void> complete();
}
