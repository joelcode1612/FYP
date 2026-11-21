import 'package:fyp/features/assessment/domain/entities/assessment_draft.dart';
import 'package:fyp/features/assessment/domain/entities/questionnaire_question.dart';
import 'package:fyp/features/assessment/domain/services/questionnaire_routing_service.dart';

/// No authorized manifest is bound to the local draft. Never infer C0/C1
/// from local answers or substitute a demonstration question bank.
class HeldQuestionnaireRoutingService implements QuestionnaireRoutingService {
  const HeldQuestionnaireRoutingService();
  @override
  List<QuestionnaireQuestion> resolve(AssessmentDraft draft) =>
      const [];
}
