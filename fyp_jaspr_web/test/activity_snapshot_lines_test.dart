import 'package:jaspr_test/jaspr_test.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/activity_snapshot_lines.dart';

/// The Activity History "current state" section makes claims that are easy to
/// get wrong in a way no test would catch: reporting an absent count as zero,
/// presenting a computed measurement as accepted, or presenting developer
/// preview evidence as customer research. These tests pin the wording to the
/// payload, using fixtures shaped like the real `/activity` response.
void main() {
  Map<String, dynamic> published({
    Object? sessions = 122,
    Object? submitted = 82,
    Object? open = 40,
    Object? withdrawn = 0,
    Object? receipts = 82,
    bool? matches = true,
  }) => {
    'state': 'PUBLISHED',
    'campaign_id': 'de3121ff-8e96-46dc-9330-1cc438b143a5',
    'release_id': '577e61b0-84cf-529b-b581-2f21283f3629',
    'campaign_created_at': '2026-11-25T04:52:41+00:00',
    'bank_version': 'CQ-ENTREP-df15adf3-r23-cq-manifest-1',
    'question_count': 13,
    'authorized_question_count': 7,
    'source_class': 'SYNTHETIC_FIXTURE',
    'published_at_revision': 23,
    'current_revision': 23,
    'fielding_enabled': false,
    'session_count': sessions,
    'submitted_session_count': submitted,
    'open_session_count': open,
    'withdrawn_session_count': withdrawn,
    'receipt_count': receipts,
    'receipts_match_submitted_sessions': matches,
    'first_session_at': '2026-11-25T04:52:41+00:00',
    'last_session_at': '2026-11-25T06:37:28+00:00',
  };

  Map<String, dynamic> measurement({
    String state = 'MEASURED',
    String evidence = 'DEVELOPER_PREVIEW',
    int customer = 0,
    int preview = 3,
    String admission = 'REPORT_FINDINGS_WITHHELD_NO_AUTHORIZED_SOURCE',
  }) => {
    'state': state,
    'summary': {
      'snapshot_count': 3,
      'slot_count': 1,
      'slots': ['Q05'],
      'by_evidence_class': {evidence: preview},
      'customer_research_snapshot_count': customer,
      'latest_cutoff': '2026-11-25T05:55:05+00:00',
    },
    'measurements': [
      {
        'slot_id': 'Q05',
        'measurement_status': 'WITHHELD_NOT_AUTHORIZED',
        'evidence_class': evidence,
        'computation': 'COMPUTED',
        'scientific_acceptance': 'NOT_ACCEPTED',
        'report_authorization': 'NOT_AUTHORIZED',
        'admission_status': admission,
        'finding_count': 0,
        'cutoff': '2026-11-25T05:55:05+00:00',
        'snapshot_version': {
          'fingerprint': '06f86f87d8687006aabbccddeeff00112233445566778899aabbccddeeff0011',
          'rules_hash': 'a' * 64,
          'source_hash': 'b' * 64,
        },
        'gates': [
          'EXPLANATION_TEMPLATE_AUTHORITY_UNVERIFIED',
          'SYNTHETIC_DATA_NOT_REPORTABLE',
        ],
      },
    ],
  };

  group('publication', () {
    test('reports aggregate counts and a matching receipt count', () {
      final lines = publicationLines({'publication': published()});
      final response = lines.firstWhere((l) => l.startsWith('Responses:'));
      expect(response, contains('122 sessions'));
      expect(response, contains('82 submitted'));
      expect(response, contains('40 open'));
      expect(response, contains('0 withdrawn'));
      expect(response, contains('82 submission receipts'));
      expect(response, contains('matches submitted sessions'));
      expect(response, contains('2026-11-25'));
    });

    test('a receipt mismatch is stated, not reconciled', () {
      final lines = publicationLines({
        'publication': published(receipts: 79, matches: false),
      });
      final response = lines.firstWhere((l) => l.startsWith('Responses:'));
      expect(response, contains('does not match 82 submitted sessions'));
      expect(
        response,
        contains('duplicate submission handling is not confirmed'),
      );
    });

    test('an absent count is "not reported", never zero', () {
      final lines = publicationLines({
        'publication': published(sessions: null),
      });
      final response = lines.firstWhere((l) => l.startsWith('Response'));
      expect(response, contains('not reported'));
      expect(response, contains('not evidence that no responses exist'));
      expect(response, isNot(contains('0 sessions')));
    });

    test('publication is separated from fielding authorization', () {
      final lines = publicationLines({'publication': published()});
      expect(lines.first, contains('fielding disabled'));
      expect(lines.first, contains('built for the current revision 23'));
    });

    test('an unreadable source is not "not published"', () {
      final lines = publicationLines(const {});
      expect(lines.single, contains('NOT_VERIFIED'));
      expect(lines.single, isNot(contains('not published')));
    });

    test('a hash mismatch withholds the state instead of asserting it', () {
      final lines = publicationLines({
        'publication': {
          'state': 'INTEGRITY_FAILED',
          'detail': 'Stored manifest/policy hash does not match the stored body.',
        },
      });
      expect(lines.single, contains('cannot be asserted'));
    });
  });

  group('measurement', () {
    test('separates computation from acceptance and authorization', () {
      final lines = measurementLines({'measurement': measurement()});
      final detail = lines.firstWhere((l) => l.startsWith('Measurement Q05'));
      expect(detail, contains('executed COMPUTED'));
      expect(detail, contains('scientific acceptance NOT_ACCEPTED'));
      expect(detail, contains('report authorization NOT_AUTHORIZED'));
      expect(
        detail,
        contains('finding admission REPORT_FINDINGS_WITHHELD_NO_AUTHORIZED_SOURCE'),
      );
      expect(detail, contains('(0 finding(s) released)'));
    });

    test('labels developer-preview evidence and counts customer evidence', () {
      final lines = measurementLines({'measurement': measurement()});
      expect(lines.first, contains('0 from customer research evidence'));
      expect(lines.first, contains('3 from developer-preview evidence'));
      expect(lines.first, contains('No measurement value is shown'));
    });

    test('shows the snapshot version and the cutoff', () {
      final detail = measurementLines({
        'measurement': measurement(),
      }).firstWhere((l) => l.startsWith('Measurement Q05'));
      expect(detail, contains('snapshot 06f86f87d868…'));
      expect(detail, contains('cutoff 2026-11-25T05:55:05+00:00'));
      expect(detail, contains('SYNTHETIC_DATA_NOT_REPORTABLE'));
    });

    test('no campaign is a publication fact, not a measurement failure', () {
      final lines = measurementLines({
        'measurement': {'state': 'NO_CAMPAIGN'},
      });
      expect(lines.single, contains('none bound'));
      expect(lines.single, contains('not a measurement failure'));
    });

    test('an unreadable source is not "no measurement"', () {
      final lines = measurementLines(const {});
      expect(lines.single, contains('NOT_VERIFIED'));
      expect(
        lines.single,
        contains('not evidence that no measurement was taken'),
      );
    });

    test('never renders a measurement value', () {
      // The backend sends no q/s/a/v. If a future change starts sending them,
      // these lines must still not print them: the page is a history of the
      // measurement, not the measurement.
      final payload = measurement();
      (payload['measurements'] as List).first.addAll({
        'q': 2,
        's': 2,
        'a': 2,
        'v': 2,
      });
      final joined = measurementLines({'measurement': payload}).join(' ');
      expect(joined, isNot(matches(RegExp(r'\bq=|v=|counts'))));
    });
  });
}
