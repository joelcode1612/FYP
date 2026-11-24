import 'package:jaspr_test/jaspr_test.dart';
import 'package:sitewise_jaspr_web/features/assessment/presentation/components/assessment_journey_stepper.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/assessment_api.dart';

const capability = AssessmentCapability(available: false);
const capabilities = AssessmentCapabilities(
  model: capability, explanation: capability, report: capability,
);

/// Builds a server-shaped record. The count and every stage status come from
/// the persisted record; workflowReadiness is deliberately a separate input.
AssessmentRecord recordWithCompletedStages(int completed) {
  final keys = const [
    'select_property', 'business_requirements', 'location_evidence',
    'ai_explanation', 'assessment_report',
  ];
  final statuses = [
    for (var i = 0; i < keys.length; i++)
      i < completed
          ? 'complete'
          : i == completed
              ? 'current'
              : 'incomplete',
  ];
  return AssessmentRecord(
    assessmentId: 'synthetic',
    propertyId: 'synthetic',
    status: completed == 5 ? 'completed' : 'in_progress',
    currentStage: completed < 5 ? completed + 1 : 5,
    currentStageKey: keys[completed < 5 ? completed : 4],
    completedStages: completed,
    totalStages: 5,
    progressPercent: completed * 20,
    reportAvailable: false,
    requirements: null,
    requirementsVersion: 0,
    capabilities: capabilities,
    nextAction: const AssessmentNextAction(
      kind: 'continue', stageKey: 'business_requirements', label: '',
    ),
    property: null,
    stages: [
      for (var i = 0; i < keys.length; i++)
        AssessmentStage(
          key: keys[i], number: i + 1, title: keys[i], status: statuses[i],
        ),
    ],
  );
}

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
      'contract_version': 'sitewise-assessment-workflow/3',
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

  test('a blocked checkpoint parses its server state', () {
    final stage = AssessmentStage.fromJson({
      'key': 'location_evidence', 'number': 3, 'title': 'Location evidence',
      'status': 'unavailable', 'state': 'BLOCKED',
      'unavailable_reason': 'OBJECTIVE_CONTRACT_UNAVAILABLE_FOR_INSTRUMENT',
    });
    expect(stage.isBlocked, isTrue);
    expect(stage.isComplete, isFalse);
    expect(stage.isUnavailable, isTrue);
    expect(stage.unavailableReason,
        'OBJECTIVE_CONTRACT_UNAVAILABLE_FOR_INSTRUMENT');
  });

  test('remaining falls back to total minus completed', () {
    expect(recordWithCompletedStages(2).stagesRemaining, 3);
    expect(recordWithCompletedStages(0).stagesRemaining, 5);
    expect(recordWithCompletedStages(5).stagesRemaining, 0);
  });

  testComponents('the stepper names how many checkpoints remain', (tester) async {
    tester.pumpComponent(AssessmentJourneyStepper(
      record: recordWithCompletedStages(2), busy: false, governedWorkflow: true,
      onOpenStage: (_) {},
    ));
    await tester.pump();
    expect(find.text('2 / 5'), findsOneComponent);
    expect(find.text(' completed · 3 remaining'), findsOneComponent);
  });

  testComponents('zero persisted stages render as zero, not as checking progress', (tester) async {
    tester.pumpComponent(AssessmentJourneyStepper(
      record: recordWithCompletedStages(0), busy: false, governedWorkflow: true,
      workflowReadiness: const {
        'stage_1': {'complete': false},
        'stage_2': {'complete': false},
      },
      onOpenStage: (_) {},
    ));
    await tester.pump();
    expect(find.text('0 / 5'), findsOneComponent);
    expect(find.text('Checking progress…'), findsNothing);
    expect(find.text('✓'), findsNothing);
  });

  testComponents('one persisted stage renders as one regardless of readiness', (tester) async {
    tester.pumpComponent(AssessmentJourneyStepper(
      record: recordWithCompletedStages(1), busy: false, governedWorkflow: true,
      workflowReadiness: const {
        'stage_1': {'complete': true},
        'stage_2': {'complete': false},
        'stage_3': {'enterable': false},
      },
      onOpenStage: (_) {},
    ));
    await tester.pump();
    expect(find.text('1 / 5'), findsOneComponent);
    expect(find.text('2 / 5'), findsNothing);
    expect(find.text('✓'), findsOneComponent);
  });

  testComponents('four persisted stages render as four', (tester) async {
    tester.pumpComponent(AssessmentJourneyStepper(
      record: recordWithCompletedStages(4), busy: false, governedWorkflow: true,
      workflowReadiness: const {
        'stage_1': {'complete': true},
        'stage_2': {'complete': true},
        'stage_3': {'enterable': true},
        'stage_4': {'enterable': true},
        'stage_5': {'preview_enterable': false},
      },
      onOpenStage: (_) {},
    ));
    await tester.pump();
    expect(find.text('4 / 5'), findsOneComponent);
    expect(find.text('✓'), findsNComponents(4));
    expect(find.text('Business review and research goals'), findsOneComponent);
  });

  testComponents('unavailable readiness blocks entry but does not erase persisted progress', (tester) async {
    final record = recordWithCompletedStages(4);
    tester.pumpComponent(AssessmentJourneyStepper(
      record: record, busy: false, governedWorkflow: true,
      workflowReadiness: null,
      onOpenStage: (_) {},
    ));
    await tester.pump();
    expect(find.text('4 / 5'), findsOneComponent);
    expect(find.text('Checking progress…'), findsNothing);
    expect(find.text('✓'), findsNComponents(4));

    // Readiness remains the authority for enterability, not for completion.
    expect(canViewAssessmentStage('location_evidence', null), isFalse);
    expect(canViewAssessmentStage('ai_explanation', null), isFalse);
    expect(canViewAssessmentStage('assessment_report', null), isFalse);
    expect(record.stageByKey('ai_explanation')?.isComplete, isTrue);
  });

  testComponents('conflicting readiness cannot downgrade the server progress count', (tester) async {
    const conflictingReadiness = <String, dynamic>{
      'stage_1': {'complete': false},
      'stage_2': {'complete': false},
      'stage_3': {'enterable': false},
      'stage_4': {'enterable': false},
      'stage_5': {'preview_enterable': false},
    };
    tester.pumpComponent(AssessmentJourneyStepper(
      record: recordWithCompletedStages(4), busy: false, governedWorkflow: true,
      workflowReadiness: conflictingReadiness,
      onOpenStage: (_) {},
    ));
    await tester.pump();
    expect(find.text('4 / 5'), findsOneComponent);
    expect(find.text('0 / 5'), findsNothing);
    expect(find.text('✓'), findsNComponents(4));

    // The same conflict still closes entry to gated stages.
    expect(canViewAssessmentStage('location_evidence', conflictingReadiness), isFalse);
    expect(canViewAssessmentStage('ai_explanation', conflictingReadiness), isFalse);
    expect(canViewAssessmentStage('assessment_report', conflictingReadiness), isFalse);
  });
}
