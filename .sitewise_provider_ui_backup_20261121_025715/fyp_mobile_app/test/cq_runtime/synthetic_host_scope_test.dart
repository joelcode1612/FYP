import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_logic/shared_logic.dart';
import 'package:fyp/features/assessment/view/synthetic_session_host.dart';
import 'package:fyp/features/assessment/viewmodel/cq_view_model.dart';
import 'package:fyp/features/assessment/view/cq_session_page.dart';

class HostApi extends ApiClient {
  HostApi(this.dto);
  final Map<String, dynamic> dto;
  final paths = <String>[];
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async {
    paths.add(path);
    return dto;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets(
    'nested developer host cannot inherit the ordinary parent session controller',
    (tester) async {
      final d =
          jsonDecode(
                File(
                  '../shared_logic/test/fixtures/cq_synthetic_completed.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      final sid = d['session_id'] as String,
          run = d['synthetic_run_id'] as String;
      final ordinary = HostApi(d), developer = HostApi(d);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            cqRepositoryProvider.overrideWithValue(
              ApiCustomerQuestionnaireRepository(ordinary),
            ),
          ],
          child: MaterialApp(
            home: Consumer(
              builder: (context, ref, child) {
                // Reproduce the persistent normal app's parent family instance.
                ref.read(cqViewModelProvider(sid));
                return SyntheticSessionHost(
                  runId: run,
                  sessionId: sid,
                  repository: ApiCustomerQuestionnaireRepository.synthetic(
                    developer,
                    runId: run,
                  ),
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(ordinary.paths, isEmpty);
      expect(developer.paths, [
        '/api/v1/cq/developer-imports/$run/sessions/$sid',
      ]);
      final vm = tester
          .widget<CqSessionPage>(find.byType(CqSessionPage))
          .viewModel!;
      expect(vm.error, isNull);
      expect(vm.session?.data['lifecycle_status'], 'COMPLETED');
      expect(find.byKey(const Key('cq-completed')), findsOneWidget);
    },
  );
}
