import 'package:jaspr_test/jaspr_test.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/assessment_api.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/assessment_report.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/chart_spec.dart';
import 'package:sitewise_jaspr_web/features/assessment/presentation/pages/assessment_report_view.dart';

import 'fixtures/chart_spec_fixtures.dart';

AssessmentRecord _record({int? respondents, int? responses}) =>
    AssessmentRecord.fromJson({
      'assessment_id': 'assess-0001',
      'property_id': 'prop-0001',
      'status': 'in_progress',
      'current_stage': 4,
      'current_stage_key': 'question_review',
      'completed_stages': 3,
      'total_stages': 5,
      'progress_percent': 60,
      'report_available': false,
      'respondent_count': ?respondents,
      'response_count': ?responses,
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

AssessmentReportView _view({ChartSpecModel? chartSpec, AssessmentRecord? record}) =>
    AssessmentReportView(
      report: _payload(),
      record: record ?? _record(),
      register: const [],
      decisions: const {},
      scope: const [],
      objective: 'Decide whether the area supports the concept.',
      extraQuestions: const [],
      chartSpec: chartSpec,
      onBack: () {},
    );

void main() {
  group('Report R03 questionnaire section', () {
    testComponents('renders the held state when no chart spec is admitted', (tester) {
      tester.pumpComponent(_view());

      expect(find.text('R03 · Concept intent distribution — held'), findsOneComponent);
      expect(
        find.textContaining('an empty chart would read as a measured zero'),
        findsOneComponent,
      );
      expect(
        find.textContaining('no report-admission adapter is adopted'),
        findsOneComponent,
      );
      // No chart shell at all: not even an empty frame.
      expect(find.text('Share of V'), findsNothing);
      expect(find.text('Limitations'), findsNothing);
    });

    testComponents('renders the chart when an admitted spec is supplied', (tester) {
      tester.pumpComponent(
        _view(chartSpec: ChartSpecModel.fromJson(conformanceChartPayload())),
      );

      expect(find.text('Stated first-three-month interest'), findsOneComponent);
      expect(find.text('Share of V'), findsOneComponent);
      expect(find.text('Limitations'), findsOneComponent);
      expect(find.text('R03 · Concept intent distribution — held'), findsNothing);
    });

    testComponents('refuses a held spec and keeps the section in its held state', (tester) {
      tester.pumpComponent(
        _view(chartSpec: ChartSpecModel.fromJson(heldChartPayload())),
      );

      // A caller cannot smuggle a withheld measurement into the report: the
      // spec parses, but isReportAdmissible is false, so the chart is not drawn.
      expect(find.text('R03 · Concept intent distribution — held'), findsOneComponent);
      expect(find.text('Stated first-three-month interest'), findsNothing);
      expect(find.text('Share of V'), findsNothing);
    });

    testComponents('participation is reported as participation, not a distribution', (tester) {
      tester.pumpComponent(
        _view(record: _record(respondents: 4, responses: 3)),
      );

      expect(
        find.textContaining('4 registered respondent(s)'),
        findsOneComponent,
      );
      expect(
        find.textContaining('participation is not a distribution'),
        findsOneComponent,
      );
    });
  });
}
