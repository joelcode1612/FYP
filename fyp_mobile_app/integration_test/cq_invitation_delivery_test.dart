// Real device controls and HTTP, with explicit disposable-lab identities.
// No production authentication, policy, approval or response is substituted.
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_logic/shared_logic.dart';
import 'package:fyp/core/di/mobile_api_client.dart';
import 'package:fyp/core/routing/app_routes.dart';
import 'package:fyp/features/assessment/presentation/cq_invitations_page.dart';
import 'package:fyp/features/assessment/presentation/cq_session_page.dart';
import 'package:fyp/features/assessment/presentation/viewmodels/cq_view_model.dart';
import '../test/cq_runtime/cq_api_widget_test.dart'
    show cqTestValue, pumpNetwork;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  testWidgets('invitation delivery EN questionnaire and submission receipt', (
    tester,
  ) async {
    final base = cqTestValue('CQ_TEST_BASE')!;
    const campaign = String.fromEnvironment('CQ_TEST_CAMPAIGN_ID');
    expect(base, startsWith('http://127.0.0.1:62403'));
    expect(campaign, isNotEmpty);
    final repo = ApiCustomerQuestionnaireRepository(
      MobileApiClient(
        bearer: () => cqTestValue('CQ_TEST_TOKEN'),
        baseUrl: base,
      ),
      allowIsolatedTesting: true,
    );
    final container = ProviderContainer(
      overrides: [cqRepositoryProvider.overrideWithValue(repo)],
    );
    addTearDown(container.dispose);
    final deliveries = await pumpNetwork(tester, repo.invitations);
    expect(deliveries.state, 'ready');
    final invitation = deliveries.invitations.single;
    expect(invitation.campaignId, campaign);
    expect(
      invitation.sessionId,
      isNull,
      reason:
          'The customer must create the session through the existing Start action.',
    );
    Future<void> waitFor(Finder finder) async {
      for (var i = 0; i < 500 && finder.evaluate().isEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      expect(finder, findsOneWidget);
    }

    Future<void> marker(String name) async {
      // The host runner captures the actual screen with ADB at these markers.
      // No surface conversion, generated mockup or app UI change is involved.
      debugPrint(name);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(seconds: 3)),
      );
      await tester.pump();
    }

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: const Scaffold(body: CqInvitationsPage()),
          onGenerateRoute: (settings) {
            expect(settings.name, AppRoutes.assessmentQuestionnaire);
            return MaterialPageRoute<void>(
              settings: settings,
              builder: (_) => Scaffold(
                body: CqSessionPage(sessionId: settings.arguments! as String),
              ),
            );
          },
        ),
      ),
    );
    await waitFor(find.text('Start'));
    await marker('FLOW_INVITATION_SCREEN_READY');
    expect(find.byType(DropdownButton<String>), findsNothing);
    expect(find.text('Bahasa Melayu'), findsNothing);
    await tester.tap(find.text('Start'));
    await tester.pump();
    await waitFor(find.byType(CqSessionPage));
    final sid =
        (tester.widget(find.byType(CqSessionPage)) as CqSessionPage).sessionId;
    final subscription = container.listen(cqViewModelProvider(sid), (_, _) {});
    addTearDown(subscription.close);
    final vm = container.read(cqViewModelProvider(sid));
    Future<void> settle() async {
      for (var i = 0; i < 500; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
        if (!vm.busy && (vm.session != null || vm.error != null)) break;
      }
      expect(vm.busy, isFalse);
      expect(vm.error, isNull);
      expect(vm.session, isNotNull);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }

    Future<void> tap(Key key) async {
      final finder = find.byKey(key);
      // ListView lazily builds controls below long option lists. Scroll the
      // actual page before looking up the button, as the existing CQ test does.
      if (finder.evaluate().isEmpty) {
        await tester.scrollUntilVisible(finder, 220);
      }
      expect(finder, findsOneWidget);
      await tester.ensureVisible(finder);
      await tester.pumpAndSettle();
      await tester.tap(finder);
      await tester.pump();
      await settle();
    }

    await settle();
    expect(vm.session!.data['campaign_id'], campaign);
    expect(vm.session!.data['locale'], 'EN');
    await tap(const Key('cq-consent'));
    final presented = <String>[];
    var stimuli = 0;
    for (var i = 0; i < 40; i++) {
      final s = vm.session!;
      if (s.data['can_submit'] == true) break;
      if (s.data['next_stimulus_kind'] != null) {
        final kind = s.data['next_stimulus_kind'];
        expect(
          find.text(s.manifest['stimuli'][kind]['text']['EN'] as String),
          findsOneWidget,
        );
        await tap(const Key('cq-stimulus'));
        stimuli++;
        continue;
      }
      final p = s.presentation!,
          slot = p['slot_id'] as String,
          q = s.question(slot);
      expect(find.text(q['wording']['EN'] as String), findsOneWidget);
      if (presented.isEmpty) await marker('FLOW_QUESTION_SCREEN_READY');
      final code = q['id'] == 'Q01'
          ? 'LIVE'
          : q['id'] == 'Q04'
          ? 'ONE'
          : q['validation']['substantive_codes'][0] as String;
      await tap(ValueKey('cq-option-$code'));
      await tap(const Key('cq-answer'));
      presented.add(slot);
    }
    expect(presented.length, 14);
    expect(presented.toSet().length, 14);
    expect(stimuli, 5);
    await tap(const Key('cq-submit'));
    expect(find.byKey(const Key('cq-submitted')), findsOneWidget);
    final saved = await pumpNetwork(tester, () => repo.read(sid));
    expect(saved.data['status'], 'SUBMITTED');
    expect(saved.data['receipt'], vm.session!.data['receipt']);
    debugPrint(
      'FLOW_RECEIPT session=$sid receipt=${saved.data['receipt']['receipt_id']}',
    );
    await marker('FLOW_RECEIPT_SCREEN_READY');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 16));
  });
}
