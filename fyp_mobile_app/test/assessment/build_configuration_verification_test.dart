// Normal application entry points, separate from preserved preview fixtures.
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_logic/shared_logic.dart';
import 'package:fyp/application/providers.dart';
import 'package:fyp/core/config/mobile_config.dart';
import 'package:fyp/core/config/dev_auth_bypass.dart';
import 'package:fyp/features/assessment/view/home_screen.dart';
import 'package:fyp/features/assessment/view/questionnaire_screen.dart';
import 'package:fyp/features/assessment/view/review_screen.dart';
import 'package:fyp/features/assessment/viewmodel/cq_view_model.dart';
import 'package:fyp/features/assessment/model/service/questionnaire_routing_service.dart';
import 'package:fyp/presentation/mobile/shell/entrepreneur_tab_scope.dart';
import 'package:fyp/data/repositories/mobile_api_client.dart';

class HeldApi implements ApiClient {
  int calls = 0;
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async {
    calls++;
    if (path == '/api/v1/cq/invitations')
      return {
        'contract_version': 'cq-invitations/1',
        'state': 'held',
        'invitations': [],
      };
    throw const ServiceFailure('Customer participation is held.');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  tearDown(() => MobileConfig.overrideUsesLiveApi = null);
  Widget shell(Widget child, HeldApi api) => ProviderScope(
    overrides: [
      cqRepositoryProvider.overrideWithValue(
        ApiCustomerQuestionnaireRepository(api),
      ),
    ],
    child: MaterialApp(
      home: EntrepreneurTabScope(onTabSelected: (_) {}, child: child),
    ),
  );
  for (final live in [false, true]) {
    test('local preview routing is held for live=$live', () {
      MobileConfig.overrideUsesLiveApi = live;
      final c = ProviderContainer();
      addTearDown(c.dispose);
      expect(
        c.read(questionnaireRoutingServiceProvider),
        isA<HeldQuestionnaireRoutingService>(),
      );
    });
    testWidgets('normal Home uses the held API for live=$live', (tester) async {
      MobileConfig.overrideUsesLiveApi = live;
      final api = HeldApi();
      await tester.pumpWidget(shell(const HomeScreen(), api));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('held pending scientific review'),
        findsOneWidget,
      );
      expect(find.text('Start Assessment'), findsNothing);
      expect(find.textContaining('DEMO BUILD'), findsNothing);
      expect(api.calls, 1);
    });
  }
  for (final page in [
    const QuestionnaireScreen(assessmentId: 'PROP-42'),
    const ReviewScreen(assessmentId: 'demo-cafe'),
  ]) {
    testWidgets('legacy/property identifier cannot open ${page.runtimeType}', (
      tester,
    ) async {
      final api = HeldApi();
      await tester.pumpWidget(shell(page, api));
      await tester.pumpAndSettle();
      expect(
        find.text('A saved customer questionnaire session is required.'),
        findsOneWidget,
      );
      expect(find.text('Continue with demo consent'), findsNothing);
      expect(api.calls, 0);
    });
  }
  test(
    'mobile UI bypass does not supply an authenticated API session',
    () async {
      expect(devAuthBypassEnabled, isFalse);
      final api = MobileApiClient(bearer: () => null);
      await expectLater(
        api.get('/api/v1/cq/invitations'),
        throwsA(isA<UnauthorizedFailure>()),
      );
    },
  );
  test('authentication release gate remains fail closed', () {
    final source = File(
      'lib/core/config/dev_auth_bypass.dart',
    ).readAsStringSync().replaceAll(RegExp(r'//[^\n]*'), '');
    expect(source.contains('kDebugMode'), isTrue);
    expect(source.contains('defaultValue: false'), isTrue);
  });
  test('property entry points do not manufacture questionnaire identifiers', () {
    for (final name in [
      'entrepreneur_ai_recommendations_mobile_page',
      'entrepreneur_assessment_summary_mobile_page',
      'entrepreneur_property_detail_mobile_page',
      'entrepreneur_recommendations_mobile_page',
    ]) {
      final s = File(
        'lib/presentation/mobile/entrepreneur/pages/$name.dart',
      ).readAsStringSync();
      expect(s.contains('AppRoutes.assessmentHome'), isTrue);
      expect(
        RegExp(
          r'AppRoutes\.assessment(?:Home|Questionnaire|Review)[^;]{0,200}arguments\s*:',
          dotAll: true,
        ).hasMatch(s),
        isFalse,
      );
    }
  });
}
