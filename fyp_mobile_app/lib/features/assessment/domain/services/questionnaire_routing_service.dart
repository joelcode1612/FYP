import 'package:fyp/features/assessment/domain/entities/assessment_draft.dart';
import 'package:fyp/features/assessment/domain/entities/questionnaire_question.dart';

/// Resolves the question set for one assessment draft.
///
/// Domain port; the demo implementation lives in Data.
abstract class QuestionnaireRoutingService {
  List<QuestionnaireQuestion> resolve(AssessmentDraft draft);
}
