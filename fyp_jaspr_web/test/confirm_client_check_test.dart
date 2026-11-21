import 'dart:convert';
import 'dart:io';

import 'package:jaspr_test/jaspr_test.dart';
import 'package:crypto/crypto.dart';
import 'package:shared_logic/shared_logic.dart';

/// CP-10 P0-06 diagnosis: the M2 panel's "Record review + confirmation" set
/// its refusal error even though POST /confirm answered 200 with a snapshot.
/// This test replays ApiM2Repository.confirm()'s exact post-200 checks against
/// the real response body captured from the server (persisted snapshot row)
/// to identify which check, if any, rejects it.
void main() {
  final file = File(
    '../artifacts/cp10_m2_e2e/20261118T030912Z/logs/confirm_response_body.json',
  );
  final body = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  const draftRevision = 11;
  const draftId = 'd11a7d3d-46e3-44d5-a89c-5dfb7509d864';

  test('DEF-05 diagnosis: confirm() post-200 checks against the real body', () {
    var stage = 'source identity';
    try {
      if (body['assessment_id'] != draftId ||
          body['assessment_revision'] != draftRevision ||
          !(body['id'] as String).contains('-')) {
        fail('check failed at stage: $stage');
      }
      stage = 'snapshot map';
      final snapshot = body['snapshot_json'] as Map<String, dynamic>;
      stage = 'snapshot identity';
      if (snapshot['assessment_id'] != draftId ||
          snapshot['assessment_revision'] != draftRevision ||
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
