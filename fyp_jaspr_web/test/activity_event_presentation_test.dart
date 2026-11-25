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

  // --- Governance-history kinds (BDJ objectives, QG candidates/reviews) ---
  //
  // These sources are metadata-only projections. The assertions below pin the
  // two things that must never drift: a proposal is not an admission, and a
  // candidate is not an approved questionnaire item.

  test('a proposal is not presented as an established objective', () {
    final e = base('OBJECTIVE_PROPOSED')
      ..['status'] = 'CANDIDATE'
      ..['recommendation_status'] = 'SUGGESTED'
      ..['source_version'] = 'bdj-objective-proposal-bound/1';
    final p = presentActivityEvent(e);
    expect(p.title, 'Objective proposed');
    expect(p.summary, contains('CANDIDATE'));
    expect(p.summary, contains('only established once an admission'));
    expect(p.engineVersion, 'bdj-objective-proposal-bound/1');
    expect(p.summary, isNot(contains('admitted')));
  });

  test('an admission names its objective and stored disposition', () {
    final e = base('OBJECTIVE_ADMITTED', revision: 19)
      ..['status'] = 'WORTH_RESEARCHING'
      ..['objective_id'] = 'O1';
    final p = presentActivityEvent(e);
    expect(p.title, 'Objective admitted');
    expect(p.summary, contains('for O1'));
    expect(p.summary, contains('WORTH_RESEARCHING'));
  });

  test('a candidate is never rendered as an approved item', () {
    final e = base('QG_CANDIDATE_RECORDED', revision: 19)
      ..['status'] = 'VALIDATED'
      ..['structural_status'] = 'PASS'
      ..['semantic_status'] = 'PASS'
      ..['provenance_status'] = 'PASS'
      ..['objective_id'] = 'O1'
      ..['source_version'] = '0.1-SYNTH';
    final p = presentActivityEvent(e);
    expect(p.title, 'Question candidate recorded');
    // The stored state is reported verbatim...
    expect(p.summary, contains('VALIDATED'));
    // ...and the sentence that prevents misreading it as approval is present.
    expect(p.summary, contains('Not an approved questionnaire item.'));
    expect(p.summary, isNot(contains('is approved')));
  });

  test('a review with no stored decision says so instead of guessing', () {
    final e = base('QG_REVIEW_RECORDED', revision: 19)..['status'] = null;
    final p = presentActivityEvent(e);
    expect(p.title, 'Candidate review recorded');
    expect(p.summary, contains('with no stored decision'));
  });

  test('a review reports its decision and expected option', () {
    final e = base('QG_REVIEW_RECORDED', revision: 19)
      ..['status'] = 'REJECT'
      ..['expected_option_code'] = 'LIKELY'
      ..['objective_id'] = 'O1';
    final p = presentActivityEvent(e);
    expect(p.summary, contains('REJECT'));
    expect(p.summary, contains('LIKELY'));
  });

  test('a record from an earlier revision is marked historical', () {
    final e = base('OBJECTIVE_PROPOSED', revision: 21)
      ..['status'] = 'CANDIDATE'
      ..['source_is_current'] = false;
    final p = presentActivityEvent(e);
    expect(p.summary, contains('earlier revision'));
    // The stored status is still shown; the note is appended, not substituted.
    expect(p.summary, contains('CANDIDATE'));
  });

  test('a current record carries no historical suffix', () {
    final e = base('OBJECTIVE_ADMITTED', revision: 19)
      ..['status'] = 'WORTH_RESEARCHING'
      ..['source_is_current'] = true;
    expect(
      presentActivityEvent(e).summary,
      isNot(contains('earlier revision')),
    );
  });

  test('a publication names the release facts it actually stores', () {
    final e = base('QUESTIONNAIRE_PUBLISHED', revision: 23)
      ..['module'] = 'CQ'
      ..['status'] = 'PUBLISHED'
      ..['source_version'] = 'CQ-ENTREP-abc-r23-cq-manifest-1'
      ..['question_count'] = 13
      ..['authorized_question_count'] = 7
      ..['source_is_current'] = true;
    final p = presentActivityEvent(e);
    expect(p.title, 'Questionnaire published');
    expect(p.summary, contains('revision 23'));
    expect(p.summary, contains('CQ-ENTREP-abc-r23-cq-manifest-1'));
    expect(p.summary, contains('13 questions'));
    expect(p.summary, contains('7 authorized'));
    // Publication must never be presented as an open fielding authorization.
    expect(p.summary, contains('not an open fielding authorization'));
  });

  test('a publication with no stored counts does not invent them', () {
    final e = base('QUESTIONNAIRE_PUBLISHED', revision: 23)
      ..['module'] = 'CQ'
      ..['status'] = 'PUBLISHED';
    final p = presentActivityEvent(e);
    expect(p.summary, isNot(contains('questions')));
    expect(p.summary, isNot(contains('authorized')));
    expect(p.summary, contains('revision 23'));
  });

  test('a publication built for an earlier revision is marked historical', () {
    final e = base('QUESTIONNAIRE_PUBLISHED', revision: 23)
      ..['module'] = 'CQ'
      ..['source_is_current'] = false;
    expect(
      presentActivityEvent(e).summary,
      contains('earlier revision'),
    );
  });
}
