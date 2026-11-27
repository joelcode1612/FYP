import 'dart:convert';

import 'package:jaspr_test/jaspr_test.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/assessment_api.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/assessment_report.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/chart_spec.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/q01_synthetic_preview.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/q01_synthetic_preview_fixture.dart';
import 'package:sitewise_jaspr_web/features/assessment/presentation/components/chart_spec_view.dart';
import 'package:sitewise_jaspr_web/features/assessment/presentation/pages/assessment_report_view.dart';

import 'fixtures/chart_spec_fixtures.dart';

/// The Q01 demonstration must render **inside** the existing report, not
/// beside it. These tests assert that, and that its presence changes nothing
/// about the report's production admission behaviour.
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

AssessmentReportView _report({
  ChartSpecModel? chartSpec,
  Q01SyntheticPreview? q01Preview,
  List<(String, String)> scope = const [],
}) => AssessmentReportView(
  report: _payload(),
  record: _record(),
  register: const [],
  decisions: const {},
  scope: scope,
  objective: 'Decide whether the area supports the concept.',
  extraQuestions: const [],
  chartSpec: chartSpec,
  q01Preview: q01Preview,
  onBack: () {},
);

void main() {
  group('Q01 demonstration inside the existing report', () {
    testComponents('renders the Q01 section in the questionnaire section', (tester) {
      tester.pumpComponent(_report(q01Preview: Q01SyntheticPreview.fromFixture()));

      // The report's own section furniture is intact. "Customer questionnaire"
      // appears twice by design: once in the jump bar, once as the section
      // heading.
      expect(find.text('Customer questionnaire'), findsNComponents(2));
      expect(find.text('05'), findsComponents);

      // The Q01 card and its chart.
      expect(find.textContaining('Q01 · Area connection'), findsOneComponent);
      // Two "Demo Mode" pills, in two different slots by design: the report
      // card's provenance slot (where every other card carries "Decision
      // support" / "From Step 2") and the chart figure's own eyebrow row, which
      // [ChartSpecView] adds for every demonstration chart.
      expect(find.text(ChartSpecView.demoModeLabel), findsNComponents(2));
      expect(find.text('I live in this area'), findsComponents);
      expect(find.text('37.5%'), findsComponents);
      expect(find.text('15'), findsComponents);

      // The compact demonstration note, once — on the chart. The full
      // data-origin sentence is printed once in the report's methodology block,
      // not over every figure.
      expect(
        find.textContaining(ChartSpecView.demoModeDescription),
        findsOneComponent,
      );

      // Deterministic interpretation and the exclusive alternatives.
      expect(find.text('Deterministic interpretation'), findsOneComponent);
      expect(find.textContaining('Registry template VD-Q01-APPROVED'), findsOneComponent);
      expect(find.textContaining('Rarely 3'), findsOneComponent);

      // The respondent count is stated. The bare phrase "40 synthetic
      // respondents" appears twice (the section sub-marker and this sentence),
      // so the assertion anchors on the sentence that carries V.
      expect(
        find.textContaining('40 synthetic respondents gave a valid Q01 answer'),
        findsOneComponent,
      );
    });

    testComponents('renders no Q01 section when the fixture is not supplied', (tester) {
      tester.pumpComponent(_report());

      expect(find.textContaining('Q01 · Area connection'), findsNothing);
      expect(find.text(ChartSpecView.demoModeLabel), findsNothing);
      expect(find.text(ChartSpecView.syntheticPreviewBannerText), findsNothing);
      expect(find.text('I live in this area'), findsNothing);
      // The section is still there, in its held state.
      expect(find.text('Customer questionnaire'), findsNComponents(2));
      expect(find.text('R03 · Concept intent distribution — held'), findsOneComponent);
    });

    testComponents('the demonstration does not make R03 renderable', (tester) {
      tester.pumpComponent(_report(q01Preview: Q01SyntheticPreview.fromFixture()));

      // R03 has no admitted spec, so it keeps its held state even though a
      // chart is on screen in the same section. A demonstration must never be
      // read as an admission.
      expect(find.text('R03 · Concept intent distribution — held'), findsOneComponent);
      expect(
        find.textContaining('an empty chart would read as a measured zero'),
        findsOneComponent,
      );
    });

    testComponents('a synthetic spec passed as an admitted chart is still refused', (tester) {
      tester.pumpComponent(
        _report(
          chartSpec: Q01SyntheticPreview.fromFixture().chart,
          q01Preview: Q01SyntheticPreview.fromFixture(),
        ),
      );

      // `chartSpec` requires `isReportAdmissible`; a synthetic preview is not,
      // so R03 stays held. The Q01 demonstration still renders separately.
      expect(find.text('R03 · Concept intent distribution — held'), findsOneComponent);
      expect(find.textContaining('Q01 · Area connection'), findsOneComponent);
    });

    testComponents('an admitted spec still renders R03 and hides the held notice', (tester) {
      tester.pumpComponent(
        _report(chartSpec: ChartSpecModel.fromJson(conformanceChartPayload())),
      );

      expect(find.text('R03 · Concept intent distribution — held'), findsNothing);
      expect(find.text('Share of V'), findsOneComponent);
    });

    testComponents('the report keeps its business description section', (tester) {
      tester.pumpComponent(
        _report(
          q01Preview: Q01SyntheticPreview.fromFixture(),
          scope: const [
            ('Business overview', 'Neighbourhood café'),
            ('Products and services', 'Coffee and pastries'),
          ],
        ),
      );

      expect(find.text('Business description'), findsNComponents(2));
      expect(find.text('Declared business'), findsOneComponent);
      expect(find.text('Neighbourhood café'), findsOneComponent);
    });
  });

  group('Q01SyntheticPreview adapter', () {
    test('parses the bundled fixture and reports the expected counts', () {
      final preview = Q01SyntheticPreview.fromFixture();
      expect(preview.respondents, 40);
      expect(preview.exclusiveOnly, 6);
      expect(preview.affiliationSelections, 53);
      expect(preview.overlapSelections, 19);
      expect(preview.affiliation.length, 6);
      expect(preview.exclusive.length, 3);
      expect(preview.chart.isSyntheticPreview, isTrue);
      expect(preview.chart.isReportAdmissible, isFalse);
      expect(preview.templateId, 'VD-Q01-APPROVED');
    });

    test('refuses a payload whose chart is not a synthetic preview', () {
      // The held variant is a *valid* chart — it parses cleanly — so the refusal
      // comes from this adapter's own synthetic check rather than from the chart
      // model rejecting a half-mutated payload.
      final json = _payloadJson();
      json['chart'] = jsonDecode(q01HeldChartJson);
      expect(
        () => Q01SyntheticPreview.fromJson(json),
        throwsA(
          isA<Q01PreviewException>()
              .having((e) => e.code, 'code', 'E_Q01_PREVIEW_NOT_SYNTHETIC'),
        ),
      );
    });

    test('a chart can never be both a synthetic preview and report-admissible', () {
      // The two are different values of one enum, so no payload can satisfy
      // both. This is why the adapter needs no separate admissibility check.
      final chart = Q01SyntheticPreview.fromFixture().chart;
      expect(chart.isSyntheticPreview && chart.isReportAdmissible, isFalse);
      expect(chart.renderState, ChartRenderState.syntheticPreviewOnly);
      expect(chart.admission.isHeld, isTrue);
    });

    test('tryFromFixture returns the fixture rather than throwing', () {
      expect(Q01SyntheticPreview.tryFromFixture(), isNotNull);
    });
  });
}

/// A mutable copy of the bundled payload, for the refusal cases.
///
/// Decoded from the same constant the app uses, so the negative tests cannot
/// drift from the fixture they are about.
Map<String, dynamic> _payloadJson() =>
    (jsonDecode(q01SyntheticPreviewPayloadJson) as Map).cast<String, dynamic>();
