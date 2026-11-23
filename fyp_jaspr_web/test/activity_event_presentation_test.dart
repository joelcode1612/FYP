import 'package:sitewise_jaspr_web/features/assessment/data/activity_event_presentation.dart';
// `jaspr_test` re-exports the `test` API and is already a declared dev
// dependency of this package, so the test does not add an undeclared one.
import 'package:jaspr_test/jaspr_test.dart';

/// Unit evidence for the Activity History format corrections.
///
/// Each case corresponds to a defect found by walking the chain
/// PostgreSQL → repository → API → Dart → display. The assertions are about
/// what the record *is*, so they fail if an identifier is ever shown as a
/// title again, or a version as a reason.
void main() {
  Map<String, dynamic> base(String kind, {int revision = 3}) => {
    'kind': kind,
    'event_id': '11111111-1111-4111-8111-111111111111',
    'assessment_revision': revision,
    'occurred_at': '2026-11-17T04:00:00Z',
    'module': 'M2',
  };

  test('an answered item reports its stored outcome, not "not supplied"', () {
    final e = base('ANSWER_SAVED')
      ..['status'] = 'ANSWERED'
      ..['item_key'] = 'M2V1-04';
    final p = presentActivityEvent(e);
    expect(p.title, 'Answer saved');
    expect(p.summary, 'Answer for M2V1-04 recorded at revision 3.');
    // No version is stored on an answer row; the mapping must not invent one.
    expect(p.engineVersion, isNull);
  });

  test('an answer without a resolvable item still reads as an answer', () {
    final e = base('ANSWER_SAVED')..['status'] = 'NOT_PROVIDED';
    final p = presentActivityEvent(e);
    expect(p.summary, 'Answer recorded at revision 3.');
  });

  test('a ruleset version is a version, never a reason', () {
    final e = base('BDJ_EVALUATED')..['evaluator_version'] = 'BDJ-RULESET-0.2';
    final p = presentActivityEvent(e);
    expect(p.title, 'Candidate rule evaluation');
    expect(p.engineVersion, 'BDJ-RULESET-0.2');
    expect(p.summary, contains('by BDJ-RULESET-0.2'));
    expect(p.summary, isNot(contains('reason')));
  });

  test('a candidate finding names its rule and review state', () {
    final e = base('CANDIDATE_FINDING_RECORDED')
      ..['status'] = 'UNREVIEWED'
      ..['rule_id'] = 'BDJ-M2V1-R03'
      ..['rule_version'] = '0.1';
    final p = presentActivityEvent(e);
    expect(p.title, 'Candidate finding recorded');
    expect(p.summary, contains('BDJ-M2V1-R03'));
    expect(p.summary, contains('0.1'));
    expect(p.summary, contains('UNREVIEWED'));
  });

  test('a confirmation shows a digest prefix, not a fabricated result', () {
    final e = base('CONTEXT_CONFIRMED')
      ..['snapshot_digest'] =
          'abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789';
    final p = presentActivityEvent(e);
    expect(p.summary, contains('abcdef012345'));
    expect(p.summary, isNot(contains('confirmed successfully')));
  });

  test('a confirmation without a digest says only that it was recorded', () {
    final p = presentActivityEvent(base('CONTEXT_CONFIRMED'));
    expect(
      p.summary,
      'Confirmation snapshot recorded at revision 3.',
    );
  });

  test('a persisted context surfaces its builder version and status', () {
    final e = base('CONTEXT_PERSISTED')
      ..['status'] = 'PERSISTED'
      ..['builder_version'] = 'bcb-builder-1.4';
    final p = presentActivityEvent(e);
    expect(p.title, 'Business context persisted');
    expect(p.engineVersion, 'bcb-builder-1.4');
    expect(p.summary, contains('PERSISTED'));
  });

  test('a finding decision names the decision and its finding', () {
    final e = base('CLARIFICATION_RECORDED')
      ..['status'] = 'KEEP_ORIGINAL'
      ..['source_id'] = '22222222-2222-4222-8222-222222222222';
    final p = presentActivityEvent(e);
    expect(p.title, 'Finding decision recorded');
    expect(p.summary, contains('KEEP_ORIGINAL'));
    expect(p.summary, contains('22222222-2222-4222-8222-222222222222'));
  });

  test('an unmapped kind keeps its raw code instead of borrowing a label', () {
    final p = presentActivityEvent(base('SOMETHING_NEW'));
    expect(p.title, 'SOMETHING_NEW');
    expect(p.summary, contains('Persisted M2 metadata at revision 3.'));
  });
}
