import 'package:fyp/features/assessment/domain/entities/assessment_draft.dart';

/// Loads and saves assessment drafts through an injected storage port.
///
/// Domain-facing contract — no storage engine, no SQLite, no file IO. The
/// Data implementation is [LocalAssessmentRepository].
abstract class AssessmentRepository {
  Future<List<AssessmentDraft>> loadDrafts();
  Future<void> saveDraft(AssessmentDraft draft);
}
