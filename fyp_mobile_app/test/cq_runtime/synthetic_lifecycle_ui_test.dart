import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_logic/shared_logic.dart';
import 'package:fyp/features/assessment/view/cq_session_page.dart';
import 'package:fyp/features/assessment/viewmodel/cq_view_model.dart';

/// Captured clone API DTOs only. These tests are not connected-phone evidence.
class CapturedApi extends ApiClient {
  CapturedApi(this.dto);
  final Map<String, dynamic> dto;
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async => dto;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  Future<void> open(WidgetTester tester, String kind) async {
    final d =
        jsonDecode(
              File(
                '../shared_logic/test/fixtures/cq_synthetic_$kind.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          cqRepositoryProvider.overrideWithValue(
            ApiCustomerQuestionnaireRepository.synthetic(
              CapturedApi(d),
              runId: d['synthetic_run_id'] as String,
            ),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: CqSessionPage(sessionId: d['session_id'] as String),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'COMPLETED lifecycle displays while DTO and receipt retain SUBMITTED',
    (tester) async {
      await open(tester, 'completed');
      expect(find.byKey(const Key('cq-completed')), findsOneWidget);
      expect(find.byKey(const Key('cq-submitted')), findsOneWidget);
      expect(find.byKey(const Key('cq-submit')), findsNothing);
      expect(find.byKey(const Key('cq-pause')), findsNothing);
    },
  );
  testWidgets(
    'hypothetical screenout displays independently and offers no further answers',
    (tester) async {
      await open(tester, 'screened_out');
      expect(find.text('SCREENED_OUT'), findsOneWidget);
      expect(
        find.textContaining('hypothetical eligibility fixture'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('cq-submit')), findsNothing);
      expect(find.byKey(const Key('cq-pause')), findsNothing);
      expect(find.text('I agree to participate'), findsNothing);
    },
  );
  testWidgets('synthetic withdrawal asks before changing a saved session', (
    tester,
  ) async {
    await open(tester, 'completed');
    await tester.ensureVisible(find.byKey(const Key('cq-withdraw')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('cq-withdraw')));
    await tester.pumpAndSettle();
    expect(find.text('End this synthetic session?'), findsOneWidget);
    await tester.tap(find.text('Keep answering'));
    await tester.pumpAndSettle();
    expect(find.text('End this synthetic session?'), findsNothing);
    // CapturedApi has no mutation handler: an accidental withdrawal would fail.
    expect(find.byKey(const Key('cq-completed')), findsOneWidget);
  });
}
