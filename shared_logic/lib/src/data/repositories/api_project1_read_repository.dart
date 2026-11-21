import '../../core/network/api_client.dart';
import '../../domain/entities/project1_readiness.dart';

/// Uses each platform's existing Supabase bearer transport. Never falls back
/// to local fixtures or identifies an M2 record by a property/workspace UUID.
final class ApiProject1ReadRepository {
  final ApiClient client;
  const ApiProject1ReadRepository(this.client);

  Future<Project1Readiness> read({String? assessmentId}) async {
    if (assessmentId != null && assessmentId.trim().isEmpty) {
      throw ArgumentError.value(assessmentId, 'assessmentId');
    }
    final path = assessmentId == null
        ? '/api/v1/project1-read/readiness'
        : '/api/v1/project1-read/assessments/${Uri.encodeComponent(assessmentId)}/readiness';
    final result = Project1Readiness.fromJson(await client.get(path));
    if (result.assessmentId != assessmentId) {
      throw const FormatException('Project1 assessment binding mismatch.');
    }
    return result;
  }
}
