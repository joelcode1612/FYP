import 'package:jaspr_test/jaspr_test.dart';
import 'package:sitewise_jaspr_web/data/assessment_api.dart';
import 'package:sitewise_jaspr_web/pages/entrepreneur/assessment_report_selector_view.dart';

AssessmentRecord record(
  String assessment,
  String property, {
  bool available = false,
}) => AssessmentRecord.fromJson({
  'assessment_id': assessment,
  'property_id': property,
  'status': 'in_progress',
  'current_stage': 2,
  'current_stage_key': 'requirements',
  'completed_stages': 1,
  'total_stages': 5,
  'progress_percent': 20,
  'report_available': available,
});

void main() {
  test(
    'View Report uses the selected record property ID and existing ReportPage',
    () {
      final a = record('assessment-one', 'EP-001'),
          b = record('assessment-two', 'EP-002');
      expect(
        assessmentLocationReportHref([a, b], b.assessmentId),
        '/entrepreneur/report?id=EP-002',
      );
      expect(
        b.reportAvailable,
        isFalse,
        reason: 'Navigation cannot grant report admission.',
      );
    },
  );
  test(
    'missing, duplicate or unbound selected records do not invent a report target',
    () {
      final a = record('assessment-one', 'EP-001');
      expect(assessmentLocationReportHref([a], 'unknown'), isNull);
      expect(assessmentLocationReportHref([a, a], a.assessmentId), isNull);
      expect(
        assessmentLocationReportHref([record('unbound', '')], 'unbound'),
        isNull,
      );
    },
  );
  test('property ID remains one encoded query value', () {
    final a = record(
      'assessment-one',
      'catalogue id&assessment=other#fragment',
    );
    final uri = Uri.parse(assessmentLocationReportHref([a], a.assessmentId)!);
    expect(uri.path, '/entrepreneur/report');
    expect(uri.queryParameters, {'id': a.propertyId});
    expect(uri.fragment, isEmpty);
  });
}
