import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:shared_logic/shared_logic.dart';

void main() {
  Map<String, dynamic> fixture() =>
      jsonDecode(
            File('test/fixtures/cq_session_isolated.json').readAsStringSync(),
          )
          as Map<String, dynamic>;
  CqSession parse(Map<String, dynamic> d) =>
      CqSession.fromJson(d, allowIsolatedTesting: true);
  test(
    'actual private FastAPI fixture parses and matches Python canonical SHA256',
    () {
      final d = fixture(), s = parse(d);
      expect(cqDigest(s.manifest), s.manifestHash);
      expect(s.data['execution_scope'], 'ISOLATED_TEST');
      expect(s.data['production_fielding_authorized'], isFalse);
      expect(() => s.manifest['version'] = 'changed', throwsUnsupportedError);
      expect(() => s.manifest['questions'].clear(), throwsUnsupportedError);
    },
  );
  test('default production decoder rejects isolated authority', () {
    expect(() => CqSession.fromJson(fixture()), throwsFormatException);
  });
  for (final key in [
    'session_id',
    'campaign_id',
    'release_id',
    'manifest_hash',
  ]) {
    test('invalid binding $key is rejected', () {
      final d = fixture();
      d[key] = 'not-a-binding';
      expect(() => parse(d), throwsFormatException);
    });
  }
  test('wording tamper under unchanged version/hash is rejected', () {
    final d = fixture();
    d['manifest']['questions'][0]['wording']['EN'] = 'tampered';
    expect(() => parse(d), throwsFormatException);
  });
  test('unregistered or inconsistent server next slot is rejected', () {
    final d = fixture();
    d['next_slot_id'] = 'Q99';
    expect(() => parse(d), throwsFormatException);
  });
  test(
    'pending, skipped, non-substantive and refused states remain distinct',
    () {
      for (final state in [
        'PENDING',
        'SKIPPED',
        'ANSWERED_NON_SUBSTANTIVE',
        'REFUSED',
      ]) {
        final d = fixture();
        d['routing'][0]['state'] = state;
        d['next_slot_id'] = null;
        expect(parse(d).routing.first['state'], state);
      }
    },
  );
  test('presentation must match exact question version', () {
    final d = fixture();
    d['presentation'] = {
      'display_id': d['session_id'],
      'slot_id': 'Q01',
      'question_id': 'Q01',
      'question_version': 'WRONG',
      'context_digest': d['routing'][0]['context_digest'],
    };
    expect(() => parse(d), throwsFormatException);
  });
  test('submitted session needs a bound and verified receipt', () {
    final d = fixture();
    d['status'] = 'SUBMITTED';
    expect(() => parse(d), throwsFormatException);
  });
  test('candidate authority cannot impersonate production', () {
    final d = fixture();
    d['execution_scope'] = 'CANDIDATE';
    d['production_fielding_authorized'] = true;
    expect(() => parse(d), throwsFormatException);
  });
}
