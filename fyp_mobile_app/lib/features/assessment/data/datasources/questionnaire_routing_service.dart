import 'package:fyp/features/assessment/domain/entities/assessment_draft.dart';
import 'package:fyp/features/assessment/domain/entities/questionnaire_question.dart';
import 'package:fyp/features/assessment/domain/services/questionnaire_routing_service.dart';

/// This two-question path is a UI-only sample, NOT C0 or C1 scientific routing.
/// Replace with a read-only adapter consuming your versioned authorized backend plan.
class DemoQuestionnaireRoutingService implements QuestionnaireRoutingService {
  const DemoQuestionnaireRoutingService();

  @override
  List<QuestionnaireQuestion> resolve(AssessmentDraft draft) =>
      demoQuestionBank;
}
