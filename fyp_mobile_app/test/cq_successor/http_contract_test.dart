// Isolated HTTP contract test (CP10-R16 / P0-04) — host: `fyp_mobile_app`.
//
// Full served-endpoint Flutter<->FastAPI integration is BLOCKED_BY_AUTHORIZATION
// (no wiring into the app, no running server, pubspec unchanged). This test
// verifies wire-compatibility WITHOUT a live network: it (a) asserts the Dart
// RoutePreviewRequest serializes to exactly the FastAPI JSON keys, and (b)
// parses a real backend response payload (captured from the Python TestClient
// cycle) into the Dart RoutePreviewResponse and asserts routing decisions,
// states, reasons and the three authorization flags.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fyp/cq_successor/route_contract.dart';

const String kBackendSampleResponse = '''
{
  "mode": "SYNTHETIC_ONLY",
  "assessment_id": "SYN-A1",
  "instrument_version": "SYN-CUST03-SUCCESSOR-1",
  "routing_policy_version": "SD-CQ-AREA-01-SYNTHETIC-PROPOSAL-1",
  "connection_group": "NO_CURRENT_CONNECTION",
  "route_state": "IN_PROGRESS",
  "next_question_id": null,
  "preview_permissions": [
    {"item_id": "Q05", "state": "ELIGIBLE_TO_SHOW", "reason": "APPROVED_FUTURE_INTENT_STIMULUS_FIXTURE"},
    {"item_id": "Q08", "state": "NOT_SHOWN", "reason": "Q04_NOT_SUBSTANTIVE_NONZERO"},
    {"item_id": "Q09", "state": "NOT_SHOWN", "reason": "SCIENTIFIC_GATE_UNAPPROVED"}
  ],
  "q10_feature_ids": [],
  "packet_digest": "deadbeef",
  "actual_display_logged": false,
  "production_fielding_authorized": false,
  "report_release_authorized": false
}
''';

void main() {
  test('request serializes to the exact FastAPI JSON key set', () {
    final req = RoutePreviewRequest(
      assessmentId: 'SYN-A1',
      tenantId: 'SYN-T',
      q01Codes: const ['NO_CURRENT_CONNECTION'],
      q02Code: 'NONE',
      q04Code: 'ZERO',
    );
    final json = req.toJson();
    for (final key in const [
      'assessment_id',
      'tenant_id',
      'q01_codes',
      'q02_code',
      'q04_code',
      'q05_code',
      'instrument_version',
      'routing_policy_version',
      'question_bank_version',
      'concept_version',
      'm2_context_version',
      'expected_revision',
    ]) {
      expect(json.containsKey(key), isTrue, reason: 'missing key: $key');
    }
    expect(json.containsKey('viewer_authorized'), isFalse);
    expect(json.containsKey('completed_ids'), isFalse);
    expect(json.containsKey('consented'), isFalse);
    expect(json['q01_codes'], const ['NO_CURRENT_CONNECTION']);
  });

  test('response parses backend JSON with correct routing decisions', () {
    final resp = RoutePreviewResponse.fromJson(
        jsonDecode(kBackendSampleResponse) as Map<String, Object?>);

    expect(resp.mode, 'SYNTHETIC_ONLY');
    expect(resp.connectionGroup, 'NO_CURRENT_CONNECTION');
    expect(resp.routeState, 'IN_PROGRESS');

    final q08 = resp.permission('Q08');
    expect(q08, isNotNull);
    expect(routeItemStateName(q08!.state), 'NOT_SHOWN');
    expect(q08.reason, 'Q04_NOT_SUBSTANTIVE_NONZERO');

    final q05 = resp.permission('Q05');
    expect(q05, isNotNull);
    expect(routeItemStateName(q05!.state), 'ELIGIBLE_TO_SHOW');

    final q09 = resp.permission('Q09');
    expect(q09, isNotNull);
    expect(q09!.reason, 'SCIENTIFIC_GATE_UNAPPROVED');

    expect(resp.actualDisplayLogged, isFalse);
    expect(resp.productionFieldingAuthorized, isFalse);
    expect(resp.reportReleaseAuthorized, isFalse);
  });
}