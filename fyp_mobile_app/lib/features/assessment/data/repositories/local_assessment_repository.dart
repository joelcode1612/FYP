import 'package:fyp/features/assessment/domain/entities/assessment_draft.dart';
import 'package:fyp/features/assessment/domain/repositories/assessment_repository.dart';
import 'package:fyp/features/assessment/domain/repositories/assessment_local_service.dart';

/// Data-layer implementation of [AssessmentRepository].
///
/// The storage port is injected — this class never constructs SQLite itself.
class LocalAssessmentRepository implements AssessmentRepository {
  const LocalAssessmentRepository({required this.localService});

  final AssessmentLocalService localService;

  @override
  Future<List<AssessmentDraft>> loadDrafts() => localService.loadDrafts();

  @override
  Future<void> saveDraft(AssessmentDraft draft) =>
      localService.saveDraft(draft);
}
