import '../entities/assessment_draft.dart';
import '../service/assessment_local_service.dart';

class AssessmentRepository {
  final AssessmentLocalService localService;
  const AssessmentRepository({required this.localService});
  Future<List<AssessmentDraft>> loadDrafts() => localService.loadDrafts();
  Future<void> saveDraft(AssessmentDraft draft) =>
      localService.saveDraft(draft);
}
