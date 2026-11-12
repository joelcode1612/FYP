import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_logic/shared_logic.dart';
import 'package:fyp/core/config/mobile_config.dart';
import 'package:fyp/features/assessment/view/collection_availability_page.dart';
import 'package:fyp/features/assessment/model/service/questionnaire_routing_service.dart';
import 'package:fyp/features/assessment/model/entities/assessment_draft.dart';
import 'fixtures/questionnaire_fixtures.dart';

class ReadClient extends ApiClient {
  int reads = 0;
  Object? failure;
  @override
  Future<Map<String, dynamic>> get(String path, {Map<String, String>? query}) async {
    reads++;
    if (failure != null) throw failure!;
    return {
      'contract_version': 'project1-readiness/1', 'assessment_id': null, 'property_id': null,
      for (final key in ['review', 'questionnaire', 'report', 'activity'])
        key: {'state': 'held', 'code': 'TEST_HOLD', 'message': 'Verified server hold for $key.'},
      'fielding_authorized': false, 'report_release_authorized': false,
    };
  }
  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError('Unexpected write.');
}

void main() {
  tearDown(() => MobileConfig.overrideUsesLiveApi = null);
  Widget app(ReadClient client) => ProviderScope(
    overrides: [project1ReadRepositoryProvider.overrideWithValue(ApiProject1ReadRepository(client))],
    child: const MaterialApp(home: CollectionAvailabilityPage()),
  );

  test('production routing never exposes fixture questions', () {
    expect(const HeldQuestionnaireRoutingService().resolve(AssessmentDraft.start(demoAssessmentOffers.first)), isEmpty);
  });
  testWidgets('live build shows held message and no consent or sample invitations', (tester) async {
    MobileConfig.overrideUsesLiveApi = true;
    final client = ReadClient();
    await tester.pumpWidget(app(client));
    await tester.pumpAndSettle();
    expect(find.text('Questionnaire held'), findsOneWidget);
    expect(find.text('Verified server hold for questionnaire.'), findsOneWidget);
    expect(find.text('Continue with demo consent'), findsNothing);
    expect(find.text('Start Assessment'), findsNothing);
    expect(client.reads, 1);
  });
  testWidgets('failure offers retry without local questionnaire fallback', (tester) async {
    MobileConfig.overrideUsesLiveApi = true;
    final client = ReadClient()..failure = StateError('Offline');
    await tester.pumpWidget(app(client));
    await tester.pumpAndSettle();
    expect(find.text('Availability could not be verified'), findsOneWidget);
    client.failure = null;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Questionnaire held'), findsOneWidget);
    expect(client.reads, 2);
  });
  testWidgets('unconfigured build makes no request', (tester) async {
    MobileConfig.overrideUsesLiveApi = false;
    final client = ReadClient();
    await tester.pumpWidget(app(client));
    await tester.pumpAndSettle();
    expect(find.textContaining('Questionnaire service unavailable'), findsOneWidget);
    expect(client.reads, 0);
  });
}
