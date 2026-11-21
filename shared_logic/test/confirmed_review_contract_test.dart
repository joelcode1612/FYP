import 'dart:convert';
import 'dart:io';
import 'package:shared_logic/shared_logic.dart';
import 'package:test/test.dart';

const aid = '00000000-0000-4000-8000-000000000001';
const cid = '00000000-0000-4000-8000-000000000002';
const answerId = '00000000-0000-4000-8000-000000000003';
Map<String, dynamic> reviewFixture() => {
  'contract_version': 'project1-confirmed-review/1',
  'assessment_id': aid,
  'confirmation_id': cid,
  'assessment_revision': 1,
  'snapshot_digest': 'a' * 64,
  'source_status': 'CURRENT_CONFIRMED_SOURCE',
  'trust_class': 'T2_AUTHENTICATED_ENTREPRENEUR_DECLARATION',
  'evaluation_state': 'EVALUATED_CANDIDATE',
  'rule_version': 'SYNTHETIC-TEST',
  'activity_scope': 'M2_RECORDS_THROUGH_CONFIRMED_REVISION',
  'activity_truncated': false,
  'fielding_authorized': false,
  'qj_handoff_authorized': false,
  'report_release_authorized': false,
  'answers': [
    {
      'item_key': 'M2-04',
      'question': 'Synthetic question',
      'answer_state': 'ANSWERED',
      'value': 'Synthetic declaration',
      'source_answer_revision_id': answerId,
      'source_item_version_id': cid,
    },
  ],
  'findings': [
    {
      'id': aid,
      'rule_id': 'TEST',
      'issue_type': 'TEST',
      'explanation': 'Test interpretation',
      'not_proven': 'Unverified',
      'next_action': 'Review',
      'review_state': 'CANDIDATE',
      'source_answer_ids': [answerId],
    },
  ],
  'activity': [
    {
      'event_id': cid,
      'kind': 'ANSWER_SAVED',
      'assessment_revision': 1,
      'occurred_at': '2026-11-13T00:00:00Z',
      'actor_id': null,
    },
  ],
};

class ReviewClient extends ApiClient {
  Map<String, dynamic> data;
  Object? failure;
  String? path;
  Map<String, String>? query;
  ReviewClient(this.data);
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async {
    this.path = path;
    this.query = query;
    if (failure != null) throw failure!;
    return data;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected mutation.');
}

void main() {
  test('declaration-only confirmation accepts no fabricated BDJ findings', () {
    final unevaluated = {...reviewFixture(), 'evaluation_state': 'NOT_EVALUATED',
      'rule_version': 'NOT_EVALUATED', 'findings': <Object>[]};
    expect(ConfirmedBusinessReview.fromJson(unevaluated).evaluationState, 'NOT_EVALUATED');
    expect(() => ConfirmedBusinessReview.fromJson({...unevaluated, 'findings': reviewFixture()['findings']}), throwsFormatException);
    expect(() => ConfirmedBusinessReview.fromJson({...unevaluated, 'rule_version': 'unverified'}), throwsFormatException);
  });
  test(
    'review pins all three requested references in the shared transport',
    () async {
      final client = ReviewClient(reviewFixture());
      final data = await ApiConfirmedReviewRepository(
        client,
      ).read(assessmentId: aid, confirmationId: cid, revision: 1);
      expect(data.answers.single.displayValue, 'Synthetic declaration');
      expect(client.path, '/api/v1/m2/assessments/$aid/confirmed-review');
      expect(client.query, {'confirmation_id': cid, 'expected_revision': '1'});
      expect(() => data.answers.clear(), throwsUnsupportedError);
    },
  );
  for (final key in [
    'fielding_authorized',
    'qj_handoff_authorized',
    'report_release_authorized',
  ]) {
    test('rejects promoted authority: $key', () {
      expect(
        () => ConfirmedBusinessReview.fromJson({...reviewFixture(), key: true}),
        throwsFormatException,
      );
    });
  }
  test('rejects missing, duplicate and unbound source references', () {
    final data = reviewFixture();
    (data['findings'] as List).first['source_answer_ids'] = [cid];
    expect(() => ConfirmedBusinessReview.fromJson(data), throwsFormatException);
    final duplicate = reviewFixture();
    (duplicate['answers'] as List).add((duplicate['answers'] as List).first);
    expect(
      () => ConfirmedBusinessReview.fromJson(duplicate),
      throwsFormatException,
    );
  });
  test('rejects activity from a future revision and missing timezone', () {
    final data = reviewFixture();
    data['activity'][0]['assessment_revision'] = 2;
    expect(() => ConfirmedBusinessReview.fromJson(data), throwsFormatException);
    data['activity'][0]['assessment_revision'] = 1;
    data['activity'][0]['occurred_at'] = '2026-11-13T00:00:00';
    expect(() => ConfirmedBusinessReview.fromJson(data), throwsFormatException);
  });
  test(
    'refuses mismatched requested confirmation or revision without fallback',
    () async {
      final client = ReviewClient(reviewFixture());
      await expectLater(
        ApiConfirmedReviewRepository(
          client,
        ).read(assessmentId: aid, confirmationId: aid, revision: 1),
        throwsFormatException,
      );
      await expectLater(
        ApiConfirmedReviewRepository(
          client,
        ).read(assessmentId: aid, confirmationId: cid, revision: 2),
        throwsFormatException,
      );
      client.failure = StateError('Unavailable source');
      await expectLater(
        ApiConfirmedReviewRepository(
          client,
        ).read(assessmentId: aid, confirmationId: cid, revision: 1),
        throwsStateError,
      );
    },
  );
  test('parses the actual isolated FastAPI projection when provided', () {
    final path = Platform.environment['P1_CONFIRMED_CONTRACT'];
    if (path == null) return;
    final data = ConfirmedBusinessReview.fromJson(
      jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>,
    );
    expect(data.activity, isNotEmpty);
    expect(
      data.answers.single.displayValue,
      'Original synthetic café declaration.',
    );
  });
}
