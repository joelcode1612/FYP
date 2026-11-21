import 'package:jaspr_test/jaspr_test.dart';
import 'package:shared_logic/shared_logic.dart';

void main() {
  const assessment = '00000000-0000-4000-8000-000000000001';
  const confirmation = '00000000-0000-4000-8000-000000000002';
  Map<String, dynamic> response() => {
    'contract_version': 'sitewise-bdj-current/1',
    'assessment_id': assessment,
    'confirmation_id': confirmation,
    'assessment_revision': 7,
    'source_fingerprint': 'a' * 64,
    'status': 'COMPLETED_WITH_FINDINGS',
    'result': {
      'assessment_id': assessment,
      'assessment_revision': 7,
      'source_fingerprint': 'a' * 64,
      'validation_status': 'valid',
      'finding_authority': 'candidate_only',
      'finding_count': 1,
      'findings': [
        {'rule_id': 'SYNTHETIC', 'observed_condition': 'A test observation'},
      ],
    },
  };

  test('accepts a correctly bound validated synthetic result', () {
    final result = CurrentBdjResult.parse(
      response(),
      assessment,
      confirmation,
      7,
    );
    expect(result.findings.single['rule_id'], 'SYNTHETIC');
  });
  test('rejects foreign confirmation and mismatched source fingerprint', () {
    expect(
      () => CurrentBdjResult.parse(response(), assessment, assessment, 7),
      throwsFormatException,
    );
    final data = response();
    (data['result'] as Map)['source_fingerprint'] = 'b' * 64;
    expect(
      () => CurrentBdjResult.parse(data, assessment, confirmation, 7),
      throwsFormatException,
    );
  });
  test('never presents an unavailable response as zero findings', () {
    final data = response()
      ..['status'] = 'RESULT_UNAVAILABLE'
      ..['result'] = null;
    final result = CurrentBdjResult.parse(data, assessment, confirmation, 7);
    expect(result.status, 'RESULT_UNAVAILABLE');
    expect(result.findings, isEmpty);
  });
}
