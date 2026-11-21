import 'package:fyp/features/assessment/domain/entities/assessment_draft.dart';

/// Persists assessment drafts.
///
/// The SQLite implementation lives in Data; the domain and presentation never
/// construct it directly. Revision-guarded writes are the storage engine's
/// responsibility — this port only states the contract.
abstract class AssessmentLocalService {
  Future<List<AssessmentDraft>> loadDrafts();
  Future<void> saveDraft(AssessmentDraft draft);
  Future<void> close();
}
