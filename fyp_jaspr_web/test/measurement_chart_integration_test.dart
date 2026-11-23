import 'dart:convert';

import 'package:jaspr_test/jaspr_test.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/assessment_api.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/assessment_report.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/chart_spec.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/measurement_chart_fixture.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/measurement_chart_preview.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/q01_synthetic_preview.dart';
import 'package:sitewise_jaspr_web/features/assessment/presentation/pages/assessment_report_view.dart';

/// RP-02/RP-04 — the real EE-01 measurement readback, inside the existing
/// report.
///
/// These tests assert three things and nothing more: that the payload is a
/// genuine `chart-spec/1` bound to one EE-01 readback context; that it renders
/// in the report's own R03 section beside — never instead of — the held notice
/// and the Q01 demonstration; and that it discloses no count and no percentage,
/// because admission is closed.
/// The assessment this readback belongs to. The report binds a measurement to
/// the assessment named in its provenance (RT-E2E-01), so the fixture is only
/// drawn when the record names the same assessment.
const String _measurementAssessment = '37f20705-cd31-5b53-b792-9b30cb49c465';

AssessmentRecord _record() => AssessmentRecord.fromJson({
  'assessment_id': _measurementAssessment,
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
  assessmentId: _measurementAssessment,
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

AssessmentReportView _report({
  MeasurementChartPreview? measurementChart,
  Q01SyntheticPreview? q01Preview,
}) => AssessmentReportView(
  report: _payload(),
  record: _record(),
  register: const [],
  decisions: const {},
  scope: const [],
  objective: 'Decide whether the area supports the concept.',
  extraQuestions: const [],
  measurementChart: measurementChart,
  q01Preview: q01Preview,
  onBack: () {},
);

Map<String, dynamic> _chartJson() =>
    (jsonDecode(measurementChartPayloadJson) as Map).cast<String, dynamic>();

Map<String, dynamic> _provenanceJson() =>
    (jsonDecode(measurementChartProvenanceJson) as Map).cast<String, dynamic>();

void main() {
  group('RP-02 measurement payload', () {
    test('is a chart-spec/1 built from a withheld EE-01 snapshot', () {
      final preview = MeasurementChartPreview.fromFixture();
      final chart = preview.chart;

      expect(chart.schemaVersion, 'chart-spec/1');
      expect(chart.questionId, 'Q05');
      expect(chart.reportSections, ['R03']);
      expect(chart.renderState, ChartRenderState.withheldNotAuthorized);
      expect(chart.admission.isHeld, isTrue);
      expect(chart.admission.realReportable, isFalse);
      expect(chart.admission.gates, isNotEmpty);
      expect(chart.isReportAdmissible, isFalse);
      expect(chart.hasPercentages, isFalse);
      for (final option in chart.options) {
        expect(option.percentageText, isNull,
            reason: 'no option may carry a share while admission is closed');
      }
    });

    test('carries the real funnel from the persisted snapshot', () {
      final preview = MeasurementChartPreview.fromFixture();
      final m = preview.chart.measurement;

      expect(m.invited, isNull,
          reason: 'I is UNKNOWN_NOT_ENUMERABLE, never a number');
      expect(m.qualified, 28);
      expect(m.shown, 28);
      expect(m.answered, 28);
      expect(m.substantive, 24);

      // A single-select chart's option counts must sum to V exactly.
      final total = preview.chart.options
          .fold<int>(0, (sum, option) => sum + option.count);
      expect(total, m.substantive);
    });

    test('is bound to one EE-01 readback context', () {
      final preview = MeasurementChartPreview.fromFixture();
      expect(preview.provenance.campaignId, preview.chart.campaignId);
      expect(preview.provenance.evidenceContextHash,
          preview.chart.evidenceContextHash);
      expect(preview.provenance.policyVersion, isNotEmpty);
      expect(preview.provenance.testRunId, isNotEmpty);
    });

    test('refuses a payload that has been granted admission', () {
      final chart = _chartJson();
      (chart['admission'] as Map)['status'] = 'ADMITTED';

      expect(
        () => MeasurementChartPreview.fromPayloads(chart, _provenanceJson()),
        throwsA(isA<MeasurementChartException>().having(
          (e) => e.code, 'code', 'E_FIXTURE_HAS_ADMISSION')),
      );
    });

    test('refuses a payload that emits a percentage', () {
      final chart = _chartJson();
      final options = (chart['options'] as List).cast<Map<String, dynamic>>();
      options.first['percentage'] = '50';

      // The contract parser rejects this before the adapter sees it, which is
      // the stronger outcome: a share can never reach a withheld chart at all.
      // Either refusal is acceptable; silently accepting it is not.
      expect(
        () => MeasurementChartPreview.fromPayloads(chart, _provenanceJson()),
        throwsA(anyOf(
          isA<ChartSpecException>().having((e) => e.code, 'code',
              'E_PERCENTAGE_EMITTED_WITHOUT_AUTHORITY'),
          isA<MeasurementChartException>(),
        )),
      );
    });

    test('refuses provenance that names a different campaign', () {
      final provenance = _provenanceJson();
      provenance['campaign_id'] = '00000000-0000-0000-0000-000000000000';

      expect(
        () => MeasurementChartPreview.fromPayloads(_chartJson(), provenance),
        throwsA(isA<MeasurementChartException>().having(
          (e) => e.code, 'code', 'E_PROVENANCE_CAMPAIGN_MISMATCH')),
      );
    });
  });

  group('RP-04 measurement readback inside the existing report', () {
    testComponents('renders beside the held R03 notice and the Q01 demo',
        (tester) {
      tester.pumpComponent(_report(
        measurementChart: MeasurementChartPreview.fromFixture(),
        q01Preview: Q01SyntheticPreview.fromFixture(),
      ));

      // The report's own furniture is untouched.
      expect(find.text('Customer questionnaire'), findsNComponents(2));
      expect(find.text('05'), findsComponents);

      // R03 keeps its held state — the readback is added, not substituted.
      expect(find.text('R03 · Concept intent distribution — held'),
          findsOneComponent);

      // The measurement card, in the report's own card style. "Findings
      // withheld" appears twice by design: the card's provenance pill and the
      // chart figure's own notice title.
      expect(find.textContaining('Q05 · d01 concept intent — measurement readback'),
          findsOneComponent);
      expect(find.text('Findings withheld'), findsNComponents(2));

      // The real funnel is printed, from the persisted snapshot.
      expect(
        find.textContaining('28 qualified · 28 shown · 28 answered · 24 substantive'),
        findsOneComponent,
      );

      // The open gates are named rather than summarised away. The identifier
      // appears more than once on purpose — once in the card's gate list and
      // again in the chart figure's own footer — so this asserts presence, not
      // a count.
      expect(find.textContaining('A10_ADAPTER_UNVERIFIED'), findsComponents);

      // The Q01 demonstration is still there, in the same section.
      expect(find.textContaining('Q01 · Area connection'), findsOneComponent);
    });

    testComponents('discloses no share when the readback is present',
        (tester) {
      tester.pumpComponent(
          _report(measurementChart: MeasurementChartPreview.fromFixture()));

      // Every option code is rendered (the notice lists the scale), but no
      // percentage text appears anywhere in the document.
      expect(find.textContaining('%'), findsNothing);
    });

    testComponents('renders nothing extra when the fixture is not supplied',
        (tester) {
      tester.pumpComponent(_report());

      expect(find.textContaining('measurement readback'), findsNothing);
      expect(find.text('Findings withheld'), findsNothing);
      // The held R03 state remains, exactly as before this change.
      expect(find.text('R03 · Concept intent distribution — held'),
          findsOneComponent);
    });
  });
}
