import 'package:jaspr_test/jaspr_test.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/assessment_api.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/assessment_report.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/chart_preview.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/report_measurement.dart';
import 'package:sitewise_jaspr_web/features/assessment/presentation/components/chart_spec_view.dart';
import 'package:sitewise_jaspr_web/features/assessment/presentation/pages/assessment_report_view.dart';

import 'fixtures/chart_spec_fixtures.dart';

/// Round 24 / Gates 2, 4 and 5 — what the client may draw, and what it must say
/// instead.
///
/// The server decides eligibility; this client only decides *presentation*. So
/// these tests do not re-derive any funnel arithmetic. They assert the narrow
/// things the client is actually responsible for:
///
/// * a slot is drawable only when it is eligible **and** its render state is the
///   synthetic one — never because a `ChartSpec` happened to parse;
/// * a `NOT_SHOWN` slot and a slot missing an approved stimulus are described,
///   never charted, because an empty chart reads as a measured zero;
/// * the bundle refuses to parse if it is not marked synthetic and
///   non-reportable, so a preview can never pose as a finding.

Map<String, dynamic> _slot({
  required String slotId,
  required String renderState,
  bool eligible = true,
  int q = 142,
  int s = 135,
  int a = 135,
  int v = 135,
  int candidates = 1,
  Map<String, dynamic>? spec,
  String? code,
}) => {
  'slot_id': slotId,
  'snapshot_id': 'snap-$slotId',
  'cutoff': '2026-11-25T18:00:00+00:00',
  'eligible': eligible,
  'candidates': candidates,
  'code': ?code,
  'spec': ?spec,
  'funnel': {'q': q, 's': s, 'a': a, 'v': v},
};

Map<String, dynamic> _bundle(List<Map<String, dynamic>> slots, {
  String contract = 'chart-preview/1',
  bool synthetic = true,
  bool reportable = false,
}) => {
  'contract_version': contract,
  'assessment_id': 'assess-0001',
  'campaign_id': 'de3121ff-8e96-46dc-9330-1cc438b143a5',
  'selection_policy': 'LATEST_CUTOFF_PER_SLOT_THEN_SNAPSHOT_ID/1',
  'synthetic': synthetic,
  'reportable': reportable,
  'admission': {'status': 'HELD', 'real_reportable': false},
  'slots': slots,
};

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

/// The HELD association section 05 shows. The preview lives under this card —
/// it is an inspection aid for evidence that exists and is withheld, so it is
/// unreachable when there is no association to hold.
const ReportMeasurement _heldMeasurement = ReportMeasurement(
  contractVersion: ReportMeasurement.contract,
  available: true,
  status: ReportMeasurement.statusHeld,
  reasonCode: 'REPORT_FINDINGS_WITHHELD_NO_AUTHORIZED_SOURCE',
  reason: 'EE-01 withholds findings: no authorized source exists.',
  countsDisclosed: false,
  detailReadable: false,
  identity: null,
  slots: [],
  admissionState: 'HELD',
  reportReleaseAuthorized: false,
);

AssessmentReportPayload _payload() => const AssessmentReportPayload(
  assessmentId: 'assess-0001',
  propertyId: 'prop-0001',
  status: 'in_progress',
  generatedAt: null,
  requirementsVersion: 1,
  questionnaire: ReportSection.empty,
  measurement: _heldMeasurement,
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

AssessmentReportView _view({ChartPreviewBundle? previews}) => AssessmentReportView(
  report: _payload(),
  record: _record(),
  register: const [],
  decisions: const {},
  scope: const [],
  objective: 'Decide whether the area supports the concept.',
  extraQuestions: const [],
  chartPreviews: previews,
  onBack: () {},
);

ChartPreviewBundle _parsed(List<Map<String, dynamic>> slots) =>
    ChartPreviewBundle.tryParse(_bundle(slots))!;

void main() {
  group('Eligibility is the server decision, not a parsed spec', () {
    test('a synthetic-preview spec is drawable', () {
      final bundle = _parsed([
        _slot(slotId: 'Q01', renderState: 'SYNTHETIC_PREVIEW_ONLY',
            spec: syntheticPreviewChartPayload()),
      ]);
      expect(bundle.drawable.map((slot) => slot.slotId), ['Q01']);
    });

    test('a held spec that parses is still not drawable', () {
      // WITHHELD_NOT_AUTHORIZED is eligible and parses; drawing it would be the
      // disclosure the admission block forbids.
      final bundle = _parsed([
        _slot(slotId: 'Q01', renderState: 'WITHHELD_NOT_AUTHORIZED',
            spec: heldChartPayload()),
      ]);
      expect(bundle.drawable, isEmpty);
      expect(bundle.slots.single.stateLine, contains('Held'));
    });

    test('an ineligible slot is never drawable even with a spec', () {
      final bundle = _parsed([
        _slot(slotId: 'Q01', renderState: 'SYNTHETIC_PREVIEW_ONLY',
            eligible: false, code: 'CHART_OVERRIDE_CANNOT_AUTHORIZE',
            spec: syntheticPreviewChartPayload()),
      ]);
      expect(bundle.drawable, isEmpty);
      expect(bundle.slots.single.stateLine,
          contains('CHART_OVERRIDE_CANNOT_AUTHORIZE'));
    });
  });

  group('The two terminals that must not become zero-value charts', () {
    test('NOT_SHOWN is described, not drawn, and does not claim zero demand', () {
      final bundle = _parsed([
        _slot(slotId: 'Q02', renderState: 'NOT_SHOWN', s: 0, a: 0, v: 0,
            spec: notShownChartPayload()),
      ]);
      final slot = bundle.slots.single;
      expect(slot.isNotShown, isTrue);
      expect(slot.isDrawable, isFalse);
      expect(bundle.drawable, isEmpty);
      expect(slot.stateLine, contains('never presented'));
      expect(slot.stateLine, contains('not a zero result'));
    });

    test('a missing approved stimulus stays withheld in preview', () {
      final bundle = _parsed([
        _slot(slotId: 'Q05', renderState: 'UNAVAILABLE_MISSING_APPROVED_STIMULUS',
            spec: missingStimulusChartPayload()),
      ]);
      final slot = bundle.slots.single;
      expect(slot.isMissingStimulus, isTrue);
      expect(slot.isDrawable, isFalse);
      expect(slot.stateLine, contains('approved stimulus'));
    });
  });

  group('The bundle refuses to be mistaken for a finding', () {
    test('refuses a payload not marked synthetic', () {
      expect(
        ChartPreviewBundle.tryParse(_bundle([], synthetic: false)),
        isNull,
      );
    });

    test('refuses a payload that claims to be reportable', () {
      expect(
        ChartPreviewBundle.tryParse(_bundle([], reportable: true)),
        isNull,
      );
    });

    test('refuses an unknown contract version', () {
      expect(
        ChartPreviewBundle.tryParse(_bundle([], contract: 'chart-preview/2')),
        isNull,
      );
    });
  });

  group('Revision selection is visible', () {
    test('more than one stored snapshot is reported, not hidden', () {
      final bundle = _parsed([
        _slot(slotId: 'Q01', renderState: 'SYNTHETIC_PREVIEW_ONLY',
            candidates: 2, spec: syntheticPreviewChartPayload()),
        _slot(slotId: 'Q03', renderState: 'SYNTHETIC_PREVIEW_ONLY',
            spec: syntheticPreviewChartPayload()),
      ]);
      expect(bundle.multiRevision.map((slot) => slot.slotId), ['Q01']);
      expect(bundle.selectionPolicy, contains('LATEST_CUTOFF'));
    });
  });

  group('Report rendering', () {
    testComponents('draws only the eligible slot and explains the other two',
        (tester) {
      tester.pumpComponent(_view(previews: _parsed([
        _slot(slotId: 'Q01', renderState: 'SYNTHETIC_PREVIEW_ONLY',
            spec: syntheticPreviewChartPayload()),
        _slot(slotId: 'Q02', renderState: 'NOT_SHOWN', s: 0, a: 0, v: 0,
            spec: notShownChartPayload()),
        _slot(slotId: 'Q05', renderState: 'UNAVAILABLE_MISSING_APPROVED_STIMULUS',
            spec: missingStimulusChartPayload()),
      ])));

      expect(find.text('Response distribution by question'), findsOneComponent);
      // The professional status chip, not a wire code and not a warning banner.
      expect(find.text(ChartSpecView.demoModeLabel), findsComponents);
      expect(find.textContaining('1 of 3 measured questions charted'),
          findsOneComponent);
      // One chart, and it is the synthetic one.
      expect(find.text('Share of V'), findsOneComponent);
      // The two terminals are prose.
      expect(find.textContaining('never presented'), findsOneComponent);
      expect(find.textContaining('approved stimulus'), findsOneComponent);
      // The hold is still the report's own statement, above the diagnostic.
      expect(find.text('R03 · Concept intent distribution — held'),
          findsOneComponent);
      expect(find.text('Findings withheld'), findsOneComponent);
    });

    testComponents('renders no preview section at all when the gate is closed',
        (tester) {
      tester.pumpComponent(_view());
      expect(find.text('Synthetic chart preview'), findsNothing);
      expect(find.text('Not reportable'), findsNothing);
    });
  });
}
