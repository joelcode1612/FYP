import 'dart:convert';

import 'package:jaspr_test/jaspr_test.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/assessment_api.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/assessment_report.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/chart_spec.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/q01_synthetic_preview_fixture.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/synthetic_preview_gate.dart';
import 'package:sitewise_jaspr_web/features/assessment/presentation/components/chart_spec_view.dart';
import 'package:sitewise_jaspr_web/features/assessment/presentation/pages/assessment_report_view.dart';

import 'fixtures/chart_spec_fixtures.dart';

/// The point of the development-only unlock is that a synthetic chart draws
/// bars while remaining inadmissible. Every test here exists to stop one of the
/// ways that could stop being true.
ChartSpecModel _preview() =>
    ChartSpecModel.fromJson((jsonDecode(q01SyntheticPreviewChartJson) as Map).cast<String, dynamic>());

ChartSpecModel _held() =>
    ChartSpecModel.fromJson((jsonDecode(q01HeldChartJson) as Map).cast<String, dynamic>());

ChartSpecModel _notEstimable() => ChartSpecModel.fromJson(
    (jsonDecode(q01NotEstimableChartJson) as Map).cast<String, dynamic>());

/// Re-serialise a payload with one field replaced, for the negative proofs.
Map<String, dynamic> _mutate(String json, void Function(Map<String, dynamic>) edit) {
  final payload = (jsonDecode(json) as Map).cast<String, dynamic>();
  edit(payload);
  return payload;
}

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

AssessmentReportView _report({ChartSpecModel? chartSpec}) => AssessmentReportView(
  report: _payload(),
  record: _record(),
  register: const [],
  decisions: const {},
  scope: const [],
  objective: 'Decide whether the area supports the concept.',
  extraQuestions: const [],
  chartSpec: chartSpec,
  onBack: () {},
);

void main() {
  group('synthetic preview gate', () {
    test('is closed unless every condition holds', () {
      const local = 'localhost';
      expect(
        syntheticPreviewAllowed(
          requested: true,
          developmentBuild: true,
          productionBuild: false,
          host: local,
        ),
        isTrue,
      );
      // Not requested.
      expect(
        syntheticPreviewAllowed(
          requested: false,
          developmentBuild: true,
          productionBuild: false,
          host: local,
        ),
        isFalse,
      );
      // Not a development build.
      expect(
        syntheticPreviewAllowed(
          requested: true,
          developmentBuild: false,
          productionBuild: false,
          host: local,
        ),
        isFalse,
      );
      // A product build refuses even when the flag is present.
      expect(
        syntheticPreviewAllowed(
          requested: true,
          developmentBuild: true,
          productionBuild: true,
          host: local,
        ),
        isFalse,
      );
      // A real hostname refuses even when the flag is present.
      expect(
        syntheticPreviewAllowed(
          requested: true,
          developmentBuild: true,
          productionBuild: false,
          host: 'app.sitewise.example',
        ),
        isFalse,
      );
    });

    test('accepts the local development origins only', () {
      for (final host in ['localhost', '127.0.0.1', '::1', '[::1]']) {
        expect(
          syntheticPreviewAllowed(
            requested: true,
            developmentBuild: true,
            productionBuild: false,
            host: host,
          ),
          isTrue,
          reason: host,
        );
      }
    });

    test('the compile-time flag defaults to off', () {
      // A plain `dart test` build carries no --dart-define, so the route must
      // be absent. If this ever flips, the default in the gate was changed.
      expect(syntheticPreviewRequested, isFalse);
    });

    test('the preview route is namespaced under /dev/', () {
      expect(syntheticPreviewPath, startsWith('/dev/'));
    });
  });

  group('synthetic preview chart model', () {
    test('parses as a synthetic preview and is not report admissible', () {
      final spec = _preview();
      expect(spec.isSyntheticPreview, isTrue);
      expect(spec.isReportAdmissible, isFalse);
      expect(spec.renderState, ChartRenderState.syntheticPreviewOnly);
      expect(spec.admission.isHeld, isTrue);
      expect(spec.admission.realReportable, isFalse);
      expect(spec.measurement.substantive, 40);
    });

    test('carries a share on every option under the preview status only', () {
      final spec = _preview();
      expect(spec.options.length, 9);
      for (final option in spec.options) {
        expect(option.percentageStatus, ChartPercentageStatus.syntheticPreviewEstimable);
        expect(option.percentageText, isNotNull);
      }
      // Not one option claims the production share status.
      expect(
        spec.options.every((o) => o.percentageStatus != ChartPercentageStatus.estimable),
        isTrue,
      );
      // `hasPercentages` stays false: these are not estimable in the
      // production sense, and code that asks that question must get "no".
      expect(spec.hasPercentages, isFalse);
    });

    test('the held variant withholds the identical measurement', () {
      final held = _held();
      final preview = _preview();
      expect(held.isReportAdmissible, isFalse);
      expect(held.isSyntheticPreview, isFalse);
      expect(
        held.options.map((o) => o.count).toList(),
        preview.options.map((o) => o.count).toList(),
      );
      expect(held.options.every((o) => o.percentageText == null), isTrue);
    });

    test('the not-estimable variant has no denominator and no shares', () {
      final spec = _notEstimable();
      expect(spec.renderState, ChartRenderState.notEstimable);
      expect(spec.measurement.substantive, 0);
      expect(spec.highestOptions, isEmpty);
      expect(spec.options.every((o) => o.percentageText == null), isTrue);
    });
  });

  group('synthetic preview cannot become a report claim', () {
    test('rejects a preview marked real_reportable', () {
      final payload = _mutate(q01SyntheticPreviewChartJson, (json) {
        (json['admission'] as Map)['real_reportable'] = true;
      });
      expect(
        () => ChartSpecModel.fromJson(payload),
        throwsA(
          isA<ChartSpecException>().having(
            (e) => e.code,
            'code',
            'E_SYNTHETIC_PREVIEW_MARKED_REPORTABLE',
          ),
        ),
      );
    });

    test('rejects a preview carrying an admitted admission block', () {
      final payload = _mutate(q01SyntheticPreviewChartJson, (json) {
        json['admission'] = {
          'status': 'ADMITTED',
          'authority': 'AUTHORITY_VERIFIED',
          'gates': <String>[],
          'real_reportable': false,
        };
      });
      expect(
        () => ChartSpecModel.fromJson(payload),
        throwsA(
          isA<ChartSpecException>().having(
            (e) => e.code,
            'code',
            'E_SYNTHETIC_PREVIEW_WITH_ADMISSION',
          ),
        ),
      );
    });

    test('rejects a preview share that lost its preview status', () {
      // Relabelling the shares as ESTIMABLE would let a demonstration claim
      // production authority, so the parser refuses the mismatch.
      final payload = _mutate(q01SyntheticPreviewChartJson, (json) {
        for (final option in json['options'] as List) {
          (option as Map)['percentage_status'] = 'ESTIMABLE';
        }
      });
      expect(
        () => ChartSpecModel.fromJson(payload),
        throwsA(
          isA<ChartSpecException>().having(
            (e) => e.code,
            'code',
            'E_RENDERABLE_OPTION_NOT_ESTIMABLE',
          ),
        ),
      );
    });

    testComponents('the production report section refuses a synthetic spec', (tester) {
      tester.pumpComponent(_report(chartSpec: _preview()));

      // The chart parses and draws in isolation, but the report will not accept
      // it: `isReportAdmissible` is false, so the section stays held.
      expect(find.text('R03 · Concept intent distribution — held'), findsOneComponent);
      expect(find.text(ChartSpecView.syntheticPreviewBannerText), findsNothing);
      expect(find.text('Share of V'), findsNothing);
    });

    testComponents('the report still admits a genuinely admitted spec', (tester) {
      tester.pumpComponent(
        _report(chartSpec: ChartSpecModel.fromJson(conformanceChartPayload())),
      );
      expect(find.text('Share of V'), findsOneComponent);
      expect(find.text('R03 · Concept intent distribution — held'), findsNothing);
    });
  });

  group('ChartSpecView renders the preview', () {
    test('the banner text is exactly the required string', () {
      expect(
        ChartSpecView.syntheticPreviewBannerText,
        'SYNTHETIC DEMONSTRATION — NOT REPORT EVIDENCE',
      );
    });

    testComponents('draws bars, counts and shares for the preview', (tester) {
      tester.pumpComponent(ChartSpecView(spec: _preview()));

      // Banner, before anything else.
      expect(find.text(ChartSpecView.syntheticPreviewBannerText), findsOneComponent);
      // Bars exist: the bar track is only emitted by _bars().
      expect(find.text('I live in this area'), findsComponents);
      // The printed share is the backend's decimal string, trimmed.
      expect(find.text('37.5%'), findsComponents);
      expect(find.text('30%'), findsComponents);
      // Counts are disclosed, so no cell says withheld.
      expect(find.text('withheld'), findsNothing);
      // A held line is still advertised as held.
      expect(find.text('Not report-admissible'), findsOneComponent);
      expect(find.text('Synthetic preview'), findsOneComponent);
      // Mandatory furniture.
      expect(find.text('Limitations'), findsOneComponent);
    });

    testComponents('the denominator line does not contradict its own scope', (tester) {
      tester.pumpComponent(ChartSpecView(spec: _preview()));

      // V = 40 includes 6 respondents who selected only an exclusive terminal,
      // so a sentence calling all 40 "substantive answers" would be false. The
      // scope sentence names what V counts; the renderer must only add the
      // number.
      expect(
        find.textContaining('including 6 who selected only an exclusive alternative'),
        findsOneComponent,
      );
      expect(find.textContaining('V = 40.'), findsOneComponent);
      expect(find.textContaining('40 substantive answers'), findsNothing);
    });

    testComponents('the held variant draws no bars and withholds every cell', (tester) {
      tester.pumpComponent(ChartSpecView(spec: _held()));

      expect(find.text(ChartSpecView.syntheticPreviewBannerText), findsNothing);
      expect(find.text('Findings withheld'), findsOneComponent);
      expect(find.text('withheld'), findsComponents);
      expect(find.text('37.5%'), findsNothing);
    });

    testComponents('the not-estimable variant draws no bars and claims no share', (tester) {
      tester.pumpComponent(ChartSpecView(spec: _notEstimable()));

      expect(find.text('Not estimable'), findsOneComponent);
      expect(find.text('37.5%'), findsNothing);
      expect(find.text(ChartSpecView.syntheticPreviewBannerText), findsNothing);
    });
  });
}
