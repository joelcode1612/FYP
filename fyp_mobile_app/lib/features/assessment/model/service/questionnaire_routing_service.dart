import '../entities/assessment_draft.dart';
import '../entities/questionnaire_question.dart';

abstract class QuestionnaireRoutingService {
  List<QuestionnaireQuestion> resolve(AssessmentDraft draft);
}

/// No authorized manifest is bound to the local draft. Never infer C0/C1
/// from local answers or substitute a demonstration question bank.
class HeldQuestionnaireRoutingService implements QuestionnaireRoutingService {
  const HeldQuestionnaireRoutingService();
  @override
  List<QuestionnaireQuestion> resolve(AssessmentDraft draft) =>
      const [];
}
