import 'dart:convert';
import 'dart:io';

import 'package:jaspr_test/jaspr_test.dart';
import 'package:crypto/crypto.dart';
import 'package:shared_logic/shared_logic.dart';

/// CP-10 P0-06 diagnosis: the M2 panel's "Record review + confirmation" set
/// its refusal error even though POST /confirm answered 200 with a snapshot.
/// This test replays ApiM2Repository.confirm()'s exact post-200 checks against
/// a controlled synthetic response body. The original machine-local artifact
/// was `../artifacts/cp10_m2_e2e/20261118T030912Z/logs/confirm_response_body.json`;
/// it is no longer required for a clean checkout. To replay a preserved artifact,
/// set SITEWISE_CONFIRM_DIAGNOSTIC_BODY to its path.
const syntheticFixture = 'test/fixtures/confirm_response_body.synthetic.json';
const syntheticDraftRevision = 11;
const syntheticDraftId = '11111111-2222-4333-8444-555555555555';

Map<String, dynamic> loadDiagnosticBody() {
  final override = Platform.environment['SITEWISE_CONFIRM_DIAGNOSTIC_BODY'];
  final file = override == null || override.isEmpty
      ? File(syntheticFixture)
      : File(override);
  return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
}

void main() {
  final body = loadDiagnosticBody();

  test('DEF-05 diagnosis: confirm() post-200 checks against the controlled body', () {
    var stage = 'source identity';
    try {
      if (body['assessment_id'] != syntheticDraftId ||
          body['assessment_revision'] != syntheticDraftRevision ||
          !(body['id'] as String).contains('-')) {
        fail('check failed at stage: $stage');
      }
      stage = 'snapshot map';
      final snapshot = body['snapshot_json'] as Map<String, dynamic>;
      stage = 'snapshot identity';
      if (snapshot['assessment_id'] != syntheticDraftId ||
          snapshot['assessment_revision'] != syntheticDraftRevision ||
          snapshot['qj_handoff_authorized'] != false) {
        fail(
          'check failed at stage: $stage '
          '(qj_handoff_authorized=${snapshot['qj_handoff_authorized']})',
        );
      }
      stage = 'snapshot digest';
      final recomputed = sha256
          .convert(utf8.encode(canonicalSourceJson(snapshot)))
          .toString();
      if (body['snapshot_digest'] != recomputed) {
        fail(
          'check failed at stage: $stage '
          '(stored=${body['snapshot_digest']} recomputed=$recomputed)',
        );
      }
    } on FormatException catch (e) {
      fail('FormatException at stage "$stage": ${e.message}');
    } on TypeError catch (e) {
      fail('TypeError at stage "$stage": $e');
    }
  });

  test('DEF-05 diagnosis: canonicalSourceJson is callable on the snapshot', () {
    final snapshot = body['snapshot_json'] as Map<String, dynamic>;
    final canonical = canonicalSourceJson(snapshot);
    expect(canonical.length, greaterThan(0));
  });
}
