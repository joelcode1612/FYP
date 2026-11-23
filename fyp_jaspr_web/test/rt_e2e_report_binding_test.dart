import 'package:jaspr_test/jaspr_test.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/assessment_api.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/assessment_report.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/business_description.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/measurement_chart_preview.dart';
import 'package:sitewise_jaspr_web/features/assessment/presentation/pages/assessment_report_view.dart';

/// RT-E2E-01 — the two bindings the report must enforce itself.
///
/// 1. A measurement readback is drawn **only** under the assessment its
///    provenance names. Handing the report another assessment's readback must
///    render nothing, not a card with someone else's funnel in it.
/// 2. A confirmed business description is drawn only when it carries its
///    confirmation provenance, and an unconfirmed assessment gets an explicit
///    held state rather than a blank card or an invented declaration.
AssessmentRecord _record({String assessmentId = 'assess-0001'}) =>
    AssessmentRecord.fromJson({
      'assessment_id': assessmentId,
      'property_id': 'prop-0001',
      'status': 'in_progress',
      'current_stage': 4,
      'current_stage_key': 'question_review',
      'completed_stages': 3,
      'total_stages': 5,
      'progress_percent': 60,
      'report_available': false,
    });

AssessmentReportPayload _payload({String assessmentId = 'assess-0001'}) =>
    AssessmentReportPayload(
      assessmentId: assessmentId,
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
      requirementMatching: const RequirementMatching(),
      missingInformation: const [],
      modelInformation: const {},
      exportPdf: false,
      exportReason: null,
    );

AssessmentReportView _report({
  String assessmentId = 'assess-0001',
  MeasurementChartPreview? measurementChart,
  BusinessDescription? businessDescription,
  List<(String, String)> scope = const [],
}) => AssessmentReportView(
  report: _payload(assessmentId: assessmentId),
  record: _record(assessmentId: assessmentId),
  register: const [],
  decisions: const {},
  scope: scope,
  objective: 'Decide whether the area supports the concept.',
  extraQuestions: const [],
  measurementChart: measurementChart,
  businessDescription: businessDescription,
  onBack: () {},
);

BusinessDescription _confirmed() => BusinessDescription.fromJson({
  'contract_version': 'report-business-description/1',
  'status': 'AVAILABLE',
  'reason_code': null,
  'detail': null,
  'source': {
    'context_id': '80dbc244-e55b-504c-b472-1c133de27229',
    'confirmation_id': 'd2453af1-70e8-4be6-9fbe-20fe5e41b357',
    'assessment_revision': 20,
    'packet_hash': 'a' * 64,
    'concept_version': 'M2-CONFIRMED-20-d472f36176307e4e',
  },
  'rows': [
    {
      'key': 'concept_title',
      'label': 'Concept',
      'text': 'Slow Bar',
      'code': null,
      'source': {'item_key': 'M2V2-12', 'confirmation_id': 'd2453af1-70e8-4be6-9fbe-20fe5e41b357'},
    },
    {
      'key': 'product_categories',
      'label': 'Products and services',
      'text': 'Coffee and espresso beverages',
      'code': 'Coffee and espresso beverages',
      'source': {'item_key': 'M2V2-05'},
    },
  ],
  'uncertainty': {
    'id': '4c9691a9-4db4-44f2-9688-a930cd295dd7',
    'text': 'Whether customers would pay the tested price.',
  },
  'limitations': ['Entrepreneur confirmation is not independent factual verification.'],
  'evidence_class': 'ENTREPRENEUR_CONFIRMED',
});

void main() {
  group('measurement readback binding', () {
    testComponents('is not drawn under another assessment', (tester) {
      // The bundled fixture belongs to the FC4-D assessment, not to this one.
      tester.pumpComponent(
        _report(measurementChart: MeasurementChartPreview.fromFixture()),
      );

      expect(find.textContaining('measurement readback'), findsNothing);
      expect(find.text('Findings withheld'), findsNothing);
      // R03 keeps its held state, and the section is still whole.
      expect(find.text('R03 · Concept intent distribution — held'), findsOneComponent);
      expect(find.text('Customer questionnaire'), findsNComponents(2));
    });

    testComponents('is drawn under the assessment it names', (tester) {
      tester.pumpComponent(
        _report(
          assessmentId: '37f20705-cd31-5b53-b792-9b30cb49c465',
          measurementChart: MeasurementChartPreview.fromFixture(),
        ),
      );

      expect(find.textContaining('measurement readback'), findsOneComponent);
      // Twice by design: the card's provenance pill and the chart's own notice.
      expect(find.text('Findings withheld'), findsNComponents(2));
      // The funnel is printed from the persisted snapshot, and the counts in
      // the chart body stay withheld. "V = 24" appears twice by design: the
      // chart's denominator note and the report's funnel sentence.
      expect(find.textContaining('V = 24'), findsNComponents(2));
      expect(find.text('28'), findsNothing);
      // R03 itself is still held: a readback is not an admission.
      expect(find.text('R03 · Concept intent distribution — held'), findsOneComponent);
    });

    testComponents('renders nothing when no readback is supplied', (tester) {
      tester.pumpComponent(_report());

      expect(find.textContaining('measurement readback'), findsNothing);
      expect(find.text('R03 · Concept intent distribution — held'), findsOneComponent);
    });
  });

  group('confirmed business description', () {
    testComponents('renders the confirmed rows with provenance and limitations',
        (tester) {
      tester.pumpComponent(_report(businessDescription: _confirmed()));

      expect(find.text('Confirmed business description'), findsOneComponent);
      expect(find.text('Slow Bar'), findsOneComponent);
      expect(find.text('Coffee and espresso beverages'), findsComponents);
      expect(find.text('Confirmed declaration'), findsOneComponent);
      expect(find.textContaining('confirmation d2453af1-70'), findsOneComponent);
      expect(find.textContaining('revision 20'), findsOneComponent);
      expect(
        find.textContaining('not independent factual verification'),
        findsOneComponent,
      );
      // The Step-2 draft card is not printed beside the confirmed one.
      expect(find.text('Declared business'), findsNothing);
    });

    testComponents('renders a held state when nothing is confirmed', (tester) {
      final held = BusinessDescription.fromJson({
        'contract_version': 'report-business-description/1',
        'status': 'NO_CONFIRMED_BUSINESS_CONTEXT',
        'reason_code': null,
        'detail': 'This assessment has no persisted business context yet.',
        'source': null,
        'rows': const [],
        'uncertainty': null,
        'limitations': const [],
        'evidence_class': null,
      });
      tester.pumpComponent(_report(businessDescription: held));

      expect(find.text('No confirmed business description yet'), findsOneComponent);
      expect(
        find.textContaining('no persisted business context yet'),
        findsOneComponent,
      );
      expect(find.text('Confirmed business description'), findsNothing);
      expect(find.text('Declared business'), findsNothing);
    });

    testComponents('falls back to the Step-2 rows when no description was read',
        (tester) {
      tester.pumpComponent(
        _report(scope: const [('Business overview', 'Neighbourhood café')]),
      );

      expect(find.text('Declared business'), findsOneComponent);
      expect(find.text('Neighbourhood café'), findsOneComponent);
    });
  });

  group('BusinessDescription adapter', () {
    test('refuses an AVAILABLE payload without confirmation provenance', () {
      expect(
        () => BusinessDescription.fromJson({
          'contract_version': 'report-business-description/1',
          'status': 'AVAILABLE',
          'source': {'context_id': 'c'},
          'rows': [
            {'key': 'concept_title', 'label': 'Concept', 'text': 'X'},
          ],
        }),
        throwsFormatException,
      );
    });

    test('drops rows with neither text nor code', () {
      final description = BusinessDescription.fromJson({
        'contract_version': 'report-business-description/1',
        'status': 'AVAILABLE',
        'source': {
          'context_id': 'c',
          'confirmation_id': 'k',
          'assessment_revision': 1,
          'packet_hash': 'h',
        },
        'rows': [
          {'key': 'a', 'label': 'A', 'text': '  '},
          {'key': 'b', 'label': 'B', 'text': 'value'},
        ],
      });

      expect(description.rows.length, 1);
      expect(description.rows.single.text, 'value');
      expect(description.isAvailable, isTrue);
    });

    test('a non-AVAILABLE status never yields rows', () {
      final description = BusinessDescription.fromJson({
        'contract_version': 'report-business-description/1',
        'status': 'BUSINESS_CONTEXT_HELD',
        'reason_code': 'BCB_CONTEXT_SOURCE_CHANGED',
        'rows': [
          {'key': 'a', 'label': 'A', 'text': 'leaked'},
        ],
      });

      expect(description.rows, isEmpty);
      expect(description.isAvailable, isFalse);
      expect(description.isNotYetConfirmed, isFalse);
      expect(description.reasonCode, 'BCB_CONTEXT_SOURCE_CHANGED');
    });
  });
}
