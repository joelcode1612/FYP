import 'package:jaspr_test/jaspr_test.dart';
import 'package:sitewise_jaspr_web/components/assessment_journey_stepper.dart';
import 'package:sitewise_jaspr_web/data/assessment_api.dart';

const capability = AssessmentCapability(available: false);
const record = AssessmentRecord(
  assessmentId: 'synthetic', propertyId: 'synthetic', status: 'in_progress',
  currentStage: 2, currentStageKey: 'business_requirements', completedStages: 1,
  totalStages: 5, progressPercent: 20, reportAvailable: false,
  requirements: null, requirementsVersion: 0,
  capabilities: AssessmentCapabilities(model: capability, explanation: capability, report: capability),
  nextAction: AssessmentNextAction(kind: 'continue', stageKey: 'business_requirements', label: ''),
  property: null,
  stages: [
    AssessmentStage(key: 'select_property', number: 1, title: 'Property', status: 'complete'),
    AssessmentStage(key: 'business_requirements', number: 2, title: 'Requirements', status: 'current'),
    AssessmentStage(key: 'location_evidence', number: 3, title: 'Evidence', status: 'incomplete'),
    AssessmentStage(key: 'ai_explanation', number: 4, title: 'Explanation', status: 'complete'),
    AssessmentStage(key: 'assessment_report', number: 5, title: 'Report', status: 'complete'),
  ],
);

void main() {
  test('preview access and research entry use separate server decisions', () {
    const readiness = <String, dynamic>{
      'stage_3': {'enterable': true},
      'stage_4': {'enterable': false},
      'stage_5': {'preview_enterable': true},
    };
    expect(canViewAssessmentStage('select_property', readiness), isTrue);
    expect(canViewAssessmentStage('business_requirements', readiness), isTrue);
    expect(canViewAssessmentStage('location_evidence', readiness), isTrue);
    expect(canViewAssessmentStage('ai_explanation', readiness), isFalse);
    expect(canViewAssessmentStage('assessment_report', readiness), isTrue);
    expect(canViewAssessmentStage('assessment_report', null), isFalse);
    expect(canViewAssessmentStage('ai_explanation', {
      'stage_4': {'enterable': true},
    }), isTrue);
    expect(canViewAssessmentStage('unknown', readiness), isFalse);
  });
  test('readiness rejects wrong assessment, unknown contract and inconsistent state', () {
    final value = <String, dynamic>{
      'contract_version': 'sitewise-assessment-workflow/2',
      'assessment_id': 'synthetic',
      'stage_1': {'complete': true},
      'stage_2': {'complete': true},
      'stage_3': {'enterable': true},
    };
    expect(AssessmentApi.parseWorkflowReadiness(value, 'synthetic'), value);
    expect(() => AssessmentApi.parseWorkflowReadiness(value, 'other'), throwsFormatException);
    expect(() => AssessmentApi.parseWorkflowReadiness({...value, 'contract_version': 'other'}, 'synthetic'), throwsFormatException);
    expect(() => AssessmentApi.parseWorkflowReadiness({...value, 'stage_2': {'complete': false}}, 'synthetic'), throwsFormatException);
  });
  testComponents('versioned readiness overrides legacy stage timestamps', (tester) async {
    tester.pumpComponent(AssessmentJourneyStepper(
      record: record, busy: false, governedWorkflow: true,
      workflowReadiness: const {
        'stage_1': {'complete': true},
        'stage_2': {'complete': true},
        'stage_3': {'enterable': true},
      },
      onOpenStage: (_) {},
    ));
    await tester.pump();
    expect(find.text('2 / 5'), findsOneComponent);
    expect(find.text('Business review and research goals'), findsOneComponent);
  });

  testComponents('unknown readiness does not present legacy progress as verified', (tester) async {
    tester.pumpComponent(AssessmentJourneyStepper(
      record: record, busy: false, governedWorkflow: true,
      onOpenStage: (_) {},
    ));
    await tester.pump();
    expect(find.text('Checking progress…'), findsOneComponent);
    expect(find.text('3 / 5'), findsNothing);
  });
}
