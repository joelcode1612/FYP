import 'package:jaspr_test/jaspr_test.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/assessment_api.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/assessment_report.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/report_composition.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/report_measurement.dart';
import 'package:sitewise_jaspr_web/features/assessment/presentation/pages/assessment_report_view.dart';

/// CP-RPT-05/10 — the report renders the backend's composition, not its own guess.
///
/// What is pinned here:
///
/// * section 08 prints the composed state of every section, with a human label
///   rather than the wire token;
/// * an admitted but unmeasured Section B item is rendered with the measurement
///   attributes the report cannot obtain shown as *unestablished*, because a
///   blank line reads as zero;
/// * the owner's intended answer is labelled as an intention, never as a
///   respondent answer;
/// * a composition that could not be read is stated, not silently replaced by a
///   plausible-looking table.

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
  requirementsVersion: 12,
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

Map<String, dynamic> _section({
  required String index,
  required String title,
  required String availability,
  required String reason,
  List<Map<String, dynamic>> items = const [],
  String? measurementState,
}) => {
  'index': index,
  'dom_id': 'asw-rpt-$index',
  'title': title,
  'purpose': 'purpose',
  'availability': availability,
  'reason_code': reason,
  'detail': 'detail for $index',
  'measurement_state': ?measurementState,
  'a10': const <Map<String, dynamic>>[],
  'evidence': const <Map<String, dynamic>>[],
  'chart': null,
  'items': items,
};

Map<String, dynamic> _compositionJson({List<Map<String, dynamic>>? items}) => {
  'contract_version': 'report-composition/1',
  'assessment_id': 'assess-0001',
  'assessment_revision': 12,
  'assessment_revision_semantics': 'REQUIREMENTS_FORM_VERSION_NOT_A_REVISION',
  'counts_disclosed': false,
  'counts': {
    'AVAILABLE': 1,
    'ADMINISTRATIVE': 4,
    'PARTIAL': items == null ? 0 : 1,
    'PENDING_MEASUREMENT': 0,
    'UNAVAILABLE': 1,
    'WITHHELD': items == null ? 2 : 1,
    'NOT_APPLICABLE': items == null ? 1 : 0,
  },
  'revisions': {
    'marketplace_requirements_form_version': 12,
    'm2_confirmation_revision': 24,
    'report_revision': null,
  },
  'instrument': {
    'a10_contract_version': 'P3-01C-VNEXT-0.6.1-CUST-REC',
    'gate_identities_total': 24,
    'gates_closed': 0,
    'undefined_gate_ids': 5,
    'decisions_total': 22,
    'decisions_adopted': 0,
  },
  'admission': {
    'report_release_authorized': false,
    'counts_disclosed': false,
    'reason_code': 'REPORT_FINDINGS_WITHHELD_NO_AUTHORIZED_SOURCE',
  },
  'sections': [
    _section(index: '01', title: 'Assessment overview',
        availability: 'ADMINISTRATIVE', reason: 'REPORT_SUBJECT_RESOLVED'),
    _section(index: '02', title: 'Business description',
        availability: 'AVAILABLE', reason: 'BUSINESS_DESCRIPTION_CONFIRMED'),
    _section(index: '03', title: 'Business findings and uncertainties',
        availability: 'WITHHELD',
        reason: 'REPORT_FINDINGS_WITHHELD_NO_AUTHORIZED_SOURCE'),
    _section(index: '04', title: 'Research and question decisions',
        availability: 'ADMINISTRATIVE', reason: 'DECISION_REGISTER_RENDERED'),
    _section(index: '05', title: 'Customer questionnaire',
        availability: 'WITHHELD',
        reason: 'REPORT_FINDINGS_WITHHELD_NO_AUTHORIZED_SOURCE',
        measurementState: 'WITHHELD_NOT_AUTHORIZED'),
    _section(index: '06', title: 'Additional questions',
        availability: items == null ? 'NOT_APPLICABLE' : 'PARTIAL',
        reason: items == null ? 'SECTION_B_EMPTY' : 'ADDITIONAL_ITEMS_UNMEASURED',
        items: items ?? const []),
    _section(index: '07', title: 'Evidence and scoring',
        availability: 'UNAVAILABLE', reason: 'NO_ANALYSED_LOCATION_EVIDENCE'),
    _section(index: '08', title: 'Report coverage',
        availability: 'ADMINISTRATIVE', reason: 'COVERAGE_COMPUTED'),
    _section(index: '09', title: 'Sources and limitations',
        availability: 'ADMINISTRATIVE', reason: 'SOURCE_TRAIL_RENDERED'),
  ],
};

Map<String, dynamic> _item() => {
  'candidate_id': 'cand-1',
  'objective_id': 'O1',
  'objective_admission_id': 'adm-1',
  'stem': 'How often would you buy fresh produce here?',
  'response_format': 'ENUM',
  'options': [
    {'code': 'DAILY', 'label': 'Daily'},
    {'code': 'WEEKLY', 'label': 'Weekly'},
  ],
  'owner_intended_options': ['WEEKLY'],
  'owner_intended_option_scope': 'ENTREPRENEUR_ONLY_METADATA',
  'review_decision': 'APPROVE_FOR_REVIEW',
  'admission_stage': 'CANDIDATE_SUBMITTED_FOR_REVIEW',
  'measurement_state': 'UNMEASURED',
  'measurement_level': null,
  'analysis_method': null,
  'denominator': null,
  'limitations': ['AI-generated question candidate, not respondent evidence.'],
};

AssessmentReportView _view({ReportComposition? composition}) => AssessmentReportView(
  report: _payload(),
  record: _record(),
  register: const [],
  decisions: const {},
  scope: const [],
  objective: 'Decide whether the area supports the concept.',
  extraQuestions: const [],
  composition: composition,
  onBack: () {},
);

void main() {
  group('Section 08 renders the composed state of every section', () {
    test('prints each section with a human state label', () {
      final composition = ReportComposition.tryParse(_compositionJson())!;
      expect(composition.sections.length, 9);
      expect(
        composition.sections.map((s) => s.availability),
        [
          'ADMINISTRATIVE', 'AVAILABLE', 'WITHHELD', 'ADMINISTRATIVE',
          'WITHHELD', 'NOT_APPLICABLE', 'UNAVAILABLE', 'ADMINISTRATIVE',
          'ADMINISTRATIVE',
        ],
      );
    });

    testComponents('renders the availability table and the instrument counts', (tester) {
      tester.pumpComponent(_view(
        composition: ReportComposition.tryParse(_compositionJson()),
      ));
      expect(find.text('Composed section availability'), findsOneComponent);
      expect(find.text('Withheld'), findsNComponents(2));
      expect(find.text('Not applicable'), findsOneComponent);
      expect(find.text('Composed by the backend: '), findsOneComponent);
      // The gate and decision counts are stated, not implied.
      expect(find.textContaining('closed 0'), findsOneComponent);
      expect(find.textContaining('decisions adopted 0 of 22'), findsOneComponent);
    });

    testComponents('states when the composition could not be read', (tester) {
      tester.pumpComponent(_view());
      expect(find.text('Composed section availability'), findsOneComponent);
      expect(find.text('Not read'), findsOneComponent);
      expect(
        find.textContaining('could not be read for this report'),
        findsOneComponent,
      );
    });
  });

  group('Section 06 renders Section B from the composition', () {
    testComponents('an admitted item is shown as unmeasured, not as a zero', (tester) {
      final composition = ReportComposition.tryParse(
        _compositionJson(items: [_item()]),
      );
      tester.pumpComponent(_view(composition: composition));
      expect(find.text('Additional research questions'), findsOneComponent);
      expect(
        find.text('How often would you buy fresh produce here?'),
        findsOneComponent,
      );
      expect(find.text('Not measured'), findsOneComponent);
      expect(find.textContaining('measurement level unestablished'),
          findsOneComponent);
      expect(find.textContaining('denominator unestablished'), findsOneComponent);
    });

    testComponents('the intended answer is labelled as an intention', (tester) {
      final composition = ReportComposition.tryParse(
        _compositionJson(items: [_item()]),
      );
      tester.pumpComponent(_view(composition: composition));
      expect(
        find.textContaining('Your intended answer (not a respondent answer)'),
        findsOneComponent,
      );
    });

    testComponents('an empty Section B says so and does not block', (tester) {
      final composition = ReportComposition.tryParse(_compositionJson());
      tester.pumpComponent(_view(composition: composition));
      expect(find.text('No additional questions were added'), findsOneComponent);
      expect(find.text('detail for 06'), findsOneComponent);
    });
  });

  group('The composition never poses as a release', () {
    test('releaseAuthorized is false when admission says so', () {
      final composition = ReportComposition.tryParse(_compositionJson())!;
      expect(composition.releaseAuthorized, isFalse);
      expect(composition.countsDisclosed, isFalse);
    });

    test('a payload without sections is refused rather than half-parsed', () {
      expect(
        ReportComposition.tryParse({'contract_version': 'report-composition/1'}),
        isNull,
      );
      expect(ReportComposition.tryParse(null), isNull);
    });
  });

  group('The rendered counts describe the document', () {
    test('every section state is counted, including the coverage section', () {
      final composition = ReportComposition.tryParse(_compositionJson())!;
      final total = composition.counts.values
          .fold<int>(0, (sum, value) => sum + (value as num).toInt());
      // Four ADMINISTRATIVE sections, not two: the tally covers 08 and 09 too.
      expect(total, composition.sections.length);
      expect(composition.counts['ADMINISTRATIVE'], 4);
    });

    testComponents('the coverage card prints the server tally', (tester) {
      tester.pumpComponent(_view(
        composition: ReportComposition.tryParse(_compositionJson()),
      ));
      expect(find.textContaining('of 9 sections'), findsOneComponent);
      expect(find.textContaining('4 administrative'), findsOneComponent);
    });

    testComponents('the two revision numbers are named separately', (tester) {
      tester.pumpComponent(_view(
        composition: ReportComposition.tryParse(_compositionJson()),
      ));
      expect(find.textContaining('form version 12'), findsOneComponent);
      expect(
        find.textContaining('not a revision counter'),
        findsOneComponent,
      );
      expect(find.textContaining('confirmed at revision 24'), findsOneComponent);
    });
  });

  group('Section 06 names the stage, not just a review decision', () {
    testComponents('a candidate submitted for review is not called admitted',
        (tester) {
      tester.pumpComponent(_view(
        composition: ReportComposition.tryParse(_compositionJson(items: [_item()])),
      ));
      expect(
        find.textContaining('submitted for review, not admitted'),
        findsOneComponent,
      );
    });

    test('an unknown stage is not guessed at', () {
      final json = _item()..['admission_stage'] = 'SOMETHING_NEW';
      final composition = ReportComposition.tryParse(
        _compositionJson(items: [json]),
      )!;
      expect(composition.byIndex('06')!.items.single.admissionStage,
          'SOMETHING_NEW');
    });
  });

  group('Section 03 renders the finding state it was given', () {
    testComponents('an unexecuted evaluation is not shown as no findings',
        (tester) {
      final json = _compositionJson();
      final section = (json['sections'] as List)
          .cast<Map<String, dynamic>>()
          .firstWhere((s) => s['index'] == '03');
      section['availability'] = 'PENDING_MEASUREMENT';
      section['reason_code'] = 'EVALUATION_NOT_EXECUTED';
      section['finding_state'] = 'EVALUATION_NOT_EXECUTED';
      section['detail'] = 'The finding evaluation has not run to a result.';
      tester.pumpComponent(
        _view(composition: ReportComposition.tryParse(json)),
      );
      expect(
        find.text('The findings evaluation has not run yet'),
        findsOneComponent,
      );
    });
  });
}
