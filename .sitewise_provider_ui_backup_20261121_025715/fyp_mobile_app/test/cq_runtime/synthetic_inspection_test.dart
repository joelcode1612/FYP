import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_logic/shared_logic.dart';
import 'package:fyp/features/assessment/view/synthetic_inspection_page.dart';

class InspectionApi extends ApiClient {
  InspectionApi({this.reportable = false, this.denied = false});
  final bool reportable, denied;
  final paths = <String>[];
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async {
    paths.add(path);
    if (denied) throw const UnauthorizedFailure('Denied');
    return {
      'contract_version': 'synthetic-inspection/1',
      'origin': 'SYNTHETIC_TEST',
      'real_reportable': reportable,
      'participant_collection_enabled': false,
      'run_id': 'unit-test-run',
      'package_sha256': 'unit-test-package-hash',
      'sessions': <dynamic>[],
      'snapshots': <dynamic>[],
      'runs': <dynamic>[],
    };
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'shared contract rejects reportable data in the inspection transport',
    () async {
      final repo = ApiSyntheticInspectionRepository(
        InspectionApi(reportable: true),
      );
      await expectLater(repo.inspect('unit-test-run'), throwsFormatException);
    },
  );
  testWidgets(
    'inspection loads via API and labels the read-only synthetic boundary',
    (tester) async {
      final api = InspectionApi();
      await tester.pumpWidget(
        MaterialApp(
          home: SyntheticInspectionPage(
            runId: 'unit-test-run',
            repository: ApiSyntheticInspectionRepository(api),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(api.paths.first, '/api/v1/cq/developer-imports/unit-test-run');
      expect(find.textContaining('SYNTHETIC / NOT REPORTABLE'), findsOneWidget);
      expect(find.text('0 sessions · 0 diagnostic snapshots'), findsOneWidget);
      expect(
        find.textContaining('Interactive cases use the separately authorized'),
        findsOneWidget,
      );
      expect(find.text('Submit'), findsNothing);
    },
  );
  testWidgets(
    'denied inspection shows no cached records or synthetic fallback',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: SyntheticInspectionPage(
            runId: 'unit-test-run',
            repository: ApiSyntheticInspectionRepository(
              InspectionApi(denied: true),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('unavailable or not authorized'),
        findsOneWidget,
      );
      expect(find.text('Stored Dss records'), findsNothing);
    },
  );
}
