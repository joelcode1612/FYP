import 'package:jaspr_test/jaspr_test.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/assessment_api.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/assessment_report.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/explanation_candidate.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/explanation_readback_preview.dart';
import 'package:sitewise_jaspr_web/features/assessment/presentation/pages/assessment_report_view.dart';

AssessmentRecord _record() => AssessmentRecord.fromJson({
  'assessment_id': 'assess-0001',
  'property_id': 'prop-0001',
  'status': 'in_progress',
  'current_stage': 4,
  'current_stage_key': 'question_review',
  'completed_stages': 3,
  'total_stages': 5,
  'progress_percent': 60,
  'report_available': false,
});

AssessmentReportPayload _payload() => const AssessmentReportPayload(
  assessmentId: 'assess-0001',
  propertyId: 'prop-0001',
  status: 'in_progress',
  generatedAt: null,
  requirementsVersion: 1,
  questionnaire: ReportSection.empty,
  property: ReportSection.empty,
  listingMedia: ReportSection.empty,
  geospatialFeatures: ReportSection.empty,
  evidenceCategories: ReportSection.empty,
  researchAssociation: ReportSection.empty,
  explanation: ReportSection.empty,
  requirementMatching: RequirementMatching(),
  missingInformation: [],
  modelInformation: {},
  exportPdf: false,
  exportReason: null,
);

/// A real withheld envelope, shaped exactly as
/// `POST /api/v1/cq/assessments/.../explanations` returns it for a gated item.
Map<String, dynamic> withheldEnvelope({bool insufficient = true}) => {
  'contract_version': 'ee01-explanation-candidate/3',
  'producer': 'EE01-EXPLANATION-QUESTION-REGISTRY-1',
  'prompt_version': null,
  'authority': 'CANDIDATE_UNVERIFIED',
  'llm_execution': 'NOT_ATTEMPTED',
  'scientific_acceptance': false,
  'owner_authorization': false,
  'publication_authorized': false,
  'fielding_authorized': false,
  'report_release_authorized': false,
  'candidate': {
    'headline': 'Q05 — withheld, approved stimulus absent',
    'observation_interpretation':
        'Findings for Q05 are withheld because the instrument, source or required '
            'stimulus has not been approved. No quantitative conclusion is issued.',
    'research_interpretation':
        'No claim from Q05 can be made in this state, so no research conclusion is offered.',
    'planning_implication':
        'No planning implication follows from a measurement that is not available.',
    'limitations':
        'Stated responses are a planning input only; they are not a forecast. '
            'No approved M2 offer exists.',
    'summary': 'The evidence supports no interpretation of concept intent at this time.',
    'insufficient_evidence': insufficient,
    'missing_evidence_references': ['Q05', 'MISSING_APPROVED_STIMULUS'],
  },
  'question': {
    'question_id': 'Q05',
    'effective_state': 'MISSING_APPROVED_STIMULUS',
    'instrument_gate': 'MISSING_APPROVED_STIMULUS',
    'registry_version': 'q01-q13-explanation/1',
    'registry_sha256': '64d0d074899e18959c66e450af34ee223d431962c492e026cd7add04cea84144',
  },
};

AssessmentReportView _view({ExplanationPanel? explanation}) => AssessmentReportView(
  report: _payload(),
  record: _record(),
  register: const [],
  decisions: const {},
  scope: const [],
  objective: 'Decide whether the area supports the concept.',
  extraQuestions: const [],
  explanation: explanation,
  onBack: () {},
);

void main() {
  group('ExplanationPanel parsing', () {
    test('a withheld envelope is renderable but never admitted', () {
      final panel = ExplanationPanel.fromJson(withheldEnvelope());
      expect(panel.isHeldExplanation, isTrue);
      expect(panel.isReportAdmissible, isFalse);
      expect(panel.isRenderable, isTrue);
      expect(panel.state, 'MISSING_APPROVED_STIMULUS');
      expect(panel.questionId, 'Q05');
      expect(panel.stateLabel, 'Withheld — approved stimulus absent');
    });

    test('a substantive but unadmitted explanation is not renderable', () {
      // insufficient_evidence=false with no admission marker: the report must
      // publish nothing, because the explanation would disclose a finding.
      final panel = ExplanationPanel.fromJson(withheldEnvelope(insufficient: false));
      expect(panel.isReportAdmissible, isFalse);
      expect(panel.isRenderable, isFalse);
    });

    test('an envelope asserting authority is refused at parse time', () {
      final payload = withheldEnvelope();
      payload['report_release_authorized'] = true;
      expect(() => ExplanationPanel.fromJson(payload), throwsFormatException);
    });

    test('a candidate that is not CANDIDATE_UNVERIFIED is refused', () {
      final payload = withheldEnvelope();
      payload['authority'] = 'VERIFIED';
      expect(() => ExplanationPanel.fromJson(payload), throwsFormatException);
    });

    test('an unknown contract version is refused', () {
      final payload = withheldEnvelope();
      payload['contract_version'] = 'ee01-explanation-candidate/2';
      expect(() => ExplanationPanel.fromJson(payload), throwsFormatException);
    });
  });

  group('Report R03 explanation section', () {
    testComponents('renders no explanation card when none is supplied', (tester) {
      tester.pumpComponent(_view());
      expect(find.text('Q05 · explanation'), findsNothing);
      expect(find.textContaining('Findings for Q05 are withheld'), findsNothing);
      // The held state is still the section's own notice.
      expect(find.text('R03 · Concept intent distribution — held'), findsOneComponent);
    });

    testComponents('renders a withheld explanation beneath the held notice', (tester) {
      tester.pumpComponent(_view(explanation: ExplanationPanel.fromJson(withheldEnvelope())));

      expect(find.text('Q05 · explanation'), findsOneComponent);
      expect(find.text('Explanation withheld'), findsOneComponent);
      expect(find.textContaining('Findings for Q05 are withheld'), findsOneComponent);
      expect(
        find.textContaining('No planning implication follows from a measurement'),
        findsOneComponent,
      );
      // It sits beside the held R03 notice, never replacing it.
      expect(find.text('R03 · Concept intent distribution — held'), findsOneComponent);
    });

    testComponents('renders nothing for a substantive unadmitted explanation', (tester) {
      tester.pumpComponent(
        _view(explanation: ExplanationPanel.fromJson(withheldEnvelope(insufficient: false))),
      );
      // No card, no caveat, no warning: a warning would still confirm the
      // measurement exists.
      expect(find.text('Q05 · explanation'), findsNothing);
      expect(find.text('Explanation withheld'), findsNothing);
      expect(find.textContaining('Findings for Q05 are withheld'), findsNothing);
    });
  });

  group('EX-04 module-level refusal', () {
    test('an unavailable panel is renderable, names no item and admits nothing', () {
      final panel = ExplanationPanel.unavailable(reason: 'The module is held.');
      expect(panel.moduleHeld, isTrue);
      expect(panel.isRenderable, isTrue);
      expect(panel.isReportAdmissible, isFalse);
      expect(panel.stateLabel, 'Explanations unavailable');
      expect(panel.questionId, isNull);
      expect(panel.observation, 'The module is held.');
    });

    test('it does not read like a withheld item', () {
      // A withheld item was considered and found unexplainable; this says
      // nothing was measured. The wording must not be interchangeable.
      final unavailable = ExplanationPanel.unavailable();
      final withheld = ExplanationPanel.fromJson(withheldEnvelope());
      expect(unavailable.stateLabel, isNot(withheld.stateLabel));
      expect(unavailable.questionId, isNull);
      expect(withheld.questionId, 'Q05');
    });

    testComponents('the report shows an unavailable notice, not a withheld card',
        (tester) async {
      tester.pumpComponent(_view(explanation: ExplanationPanel.unavailable()));
      await tester.pump();
      expect(find.text('Explanations'), findsOneComponent);
      // The report uses "Unavailable" as a status word elsewhere, so the
      // identifying assertion is the notice's own headline, which is unique.
      expect(
        find.text('Explanations are not available for this assessment'),
        findsOneComponent,
      );
      // The withheld card's own labels must not appear: no item was withheld.
      expect(find.text('Explanation withheld'), findsNothing);
      expect(find.text('Admitted'), findsNothing);
    });
  });

  group('EX-04 measurement binding', () {
    test('a held explanation needs no binding', () {
      final panel = ExplanationPanel.fromJson(withheldEnvelope());
      expect(panel.boundToSnapshot(null), isTrue);
      expect(panel.boundToSnapshot('any-snapshot'), isTrue);
    });

    test('a substantive explanation must match the measurement it explains', () {
      final payload = withheldEnvelope(insufficient: false);
      (payload['candidate'] as Map)['snapshot_id'] = 'snap-0001';
      final panel = ExplanationPanel.fromJson(payload);
      expect(panel.isRenderable, isFalse);
      expect(panel.boundToSnapshot('snap-0001'), isTrue);
      expect(panel.boundToSnapshot('snap-9999'), isFalse);
      expect(panel.boundToSnapshot(null), isFalse);
    });

    test('a substantive explanation with no snapshot of its own cannot bind', () {
      final panel = ExplanationPanel.fromJson(withheldEnvelope(insufficient: false));
      expect(panel.snapshotId, isNull);
      expect(panel.boundToSnapshot('snap-0001'), isFalse);
    });
  });

  group('EX-05 store-backed readback', () {
    test('parse and verify the bound candidate identity', () {
      final panel = ExplanationPanel.fromReadback(
        ExplanationReadbackPreview.envelope(
          headlinePrefix: 'Synthetic deterministic —',
          producer: 'EE01-EXPLANATION-QUESTION-REGISTRY-1',
          resultId: 'result-0001',
          executionKind: 'DETERMINISTIC_ONLY',
          outcome: 'DETERMINISTIC_ONLY',
          llmExecution: 'NOT_ATTEMPTED',
        ),
      );
      expect(panel.assessmentId, ExplanationReadbackPreview.assessmentId);
      expect(panel.campaignId, ExplanationReadbackPreview.campaignId);
      expect(panel.snapshotId, ExplanationReadbackPreview.snapshotId);
      expect(panel.questionId, 'Q05');
      expect(panel.resultId, 'result-0001');
      expect(panel.rulesetVersion, 'Q05@1');
      expect(panel.validationStatus, 'valid');
      expect(panel.admissionState,
          ExplanationPanel.withheldAdmissionState);
      expect(panel.isRenderable, isTrue);
      expect(panel.isReportAdmissible, isFalse);
      expect(panel.boundToSnapshot(ExplanationReadbackPreview.snapshotId), isTrue);
      expect(panel.boundToSnapshot('snap-9999'), isTrue); // held item
    });

    test('refuse stale, admitted and authority-asserting readback', () {
      final stale = ExplanationReadbackPreview.envelope(
        headlinePrefix: 'Synthetic —',
        producer: 'EE01-EXPLANATION-QUESTION-REGISTRY-1',
        resultId: 'result-0002',
        executionKind: 'DETERMINISTIC_ONLY',
        outcome: 'DETERMINISTIC_ONLY',
        llmExecution: 'NOT_ATTEMPTED',
      );
      stale['stale_reason'] = 'SOURCE_FINGERPRINT_CHANGED';
      expect(() => ExplanationPanel.fromReadback(stale),
          throwsA(isA<FormatException>()));

      final admitted = ExplanationReadbackPreview.envelope(
        headlinePrefix: 'Synthetic —',
        producer: 'EE01-EXPLANATION-QUESTION-REGISTRY-1',
        resultId: 'result-0003',
        executionKind: 'DETERMINISTIC_ONLY',
        outcome: 'DETERMINISTIC_ONLY',
        llmExecution: 'NOT_ATTEMPTED',
      );
      admitted['admitted'] = true;
      expect(() => ExplanationPanel.fromReadback(admitted),
          throwsA(isA<FormatException>()));

      final authority = ExplanationReadbackPreview.envelope(
        headlinePrefix: 'Synthetic —',
        producer: 'EE01-EXPLANATION-QUESTION-REGISTRY-1',
        resultId: 'result-0004',
        executionKind: 'DETERMINISTIC_ONLY',
        outcome: 'DETERMINISTIC_ONLY',
        llmExecution: 'NOT_ATTEMPTED',
      );
      authority['report_release_authorized'] = true;
      expect(() => ExplanationPanel.fromReadback(authority),
          throwsA(isA<FormatException>()));
    });

    test('synthetic preview permission never grants report admission', () {
      final panels = ExplanationReadbackPreview.panels();
      expect(panels.length, 3);
      for (final panel in panels) {
        expect(panel.syntheticPreview, isTrue);
        expect(panel.isSyntheticPreviewRenderable, isTrue);
        expect(panel.isReportAdmissible, isFalse);
        expect(panel.authority, 'CANDIDATE_UNVERIFIED');
      }
      final unavailable = ExplanationReadbackPreview.unavailable();
      expect(unavailable.isSyntheticPreviewRenderable, isFalse);
      expect(unavailable.isRenderable, isTrue);
    });
  });
}
