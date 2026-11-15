// Actual Flutter controls -> MobileApiClient -> FastAPI -> disposable PG.
// The runner supplies short-lived signed TEST tokens, never user credentials.
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_logic/shared_logic.dart';
import 'package:fyp/data/repositories/mobile_api_client.dart';
import 'package:fyp/features/assessment/viewmodel/cq_view_model.dart';
import 'package:fyp/features/assessment/view/cq_session_page.dart';
import 'package:fyp/core/config/mobile_runtime_config.dart';
import 'package:fyp/core/config/cq_development_access.dart';

String? cqTestValue(String key) {
  const compiled = {
    'CQ_TEST_BASE': String.fromEnvironment('CQ_TEST_BASE'),
    'CQ_TEST_TOKEN': String.fromEnvironment('CQ_TEST_TOKEN'),
    'CQ_TEST_SESSION': String.fromEnvironment('CQ_TEST_SESSION'),
    'CQ_TEST_C1_SESSION': String.fromEnvironment('CQ_TEST_C1_SESSION'),
  };
  final value = compiled[key];
  return value != null && value.isNotEmpty ? value : Platform.environment[key];
}

// Widget-originated HTTP connections complete in Flutter's fake async zone.
// Keep pumping that zone while waiting for a real socket; runAsync alone can
// deadlock when it reuses a connection opened by a widget callback.
Future<T> pumpNetwork<T>(
  WidgetTester tester,
  Future<T> Function() operation,
) async {
  var done = false;
  T? value;
  Object? error;
  operation().then(
    (v) {
      value = v;
      done = true;
    },
    onError: (Object e, StackTrace s) {
      error = e;
      done = true;
    },
  );
  for (var i = 0; i < 800 && !done; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
  if (error != null) throw error!;
  expect(done, isTrue, reason: 'Actual loopback HTTP did not finish.');
  return value as T;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // This explicitly isolated test needs actual loopback HTTP, not the default
  // flutter_test network interceptor. No production server address is accepted.
  HttpOverrides.global = null;
  final base = cqTestValue('CQ_TEST_BASE');
  setUpAll(() async {
    if (const bool.fromEnvironment('SITEWISE_ISOLATED_CQ_TEST')) {
      // Exercise the same packaged settings load as app startup. The private
      // CQ client must keep its explicit origin even when that asset uses 8090.
      await MobileRuntimeConfig.load();
      expect(CqDevelopmentAccess.enabled, isTrue);
      expect(CqDevelopmentAccess.apiBaseUrl, base);
    }
  });
  testWidgets(
    'exact server manifest, answers, next decision, revision, resume and receipt',
    (tester) async {
      expect(base, startsWith('http://127.0.0.1:'));
      final sid = cqTestValue('CQ_TEST_SESSION')!;
      final client = MobileApiClient(
        bearer: () => cqTestValue('CQ_TEST_TOKEN'),
        baseUrl: base,
      );
      final repo = ApiCustomerQuestionnaireRepository(
        client,
        allowIsolatedTesting: true,
      );
      final original = await pumpNetwork(tester, () => repo.read(sid));
      expect(
        () => CqSession.fromJson(original.data),
        throwsFormatException,
        reason: 'Production composition must reject an isolated authority.',
      );
      final container = ProviderContainer(
        overrides: [
          if (!const bool.fromEnvironment('SITEWISE_ISOLATED_CQ_TEST'))
            cqRepositoryProvider.overrideWithValue(repo),
        ],
      );
      addTearDown(container.dispose);
      // Keep the exact view model observed by this test alive across the first
      // native frame; an unobserved autoDispose read can otherwise be replaced.
      final subscription = container.listen(
        cqViewModelProvider(sid),
        (_, _) {},
      );
      addTearDown(subscription.close);
      if (const bool.fromEnvironment('SITEWISE_ISOLATED_CQ_TEST')) {
        expect(
          container.read(cqRepositoryProvider).allowIsolatedTesting,
          isTrue,
        );
      }
      final vm = container.read(cqViewModelProvider(sid));
      Future<void> settle() async {
        for (var i = 0; i < 300; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump();
          if (!vm.busy && (vm.session != null || vm.error != null)) break;
        }
        await tester.pumpAndSettle();
        expect(vm.busy, isFalse);
        expect(vm.error, isNull);
        expect(tester.takeException(), isNull);
      }

      Future<void> tap(Key key) async {
        final finder = find.byKey(key);
        if (finder.evaluate().isEmpty) {
          await tester.scrollUntilVisible(finder, 220);
        }
        await tester.ensureVisible(finder);
        await tester.pumpAndSettle();
        await tester.tap(finder);
        await tester.pump();
        await settle();
      }

      final previewDir = Platform.environment['CQ_PREVIEW_EVIDENCE'];
      if (previewDir != null) {
        await tester.runAsync(() async {
          final font = await File(Platform.environment['CQ_PREVIEW_FONT']!).readAsBytes();
          await (FontLoader('PreviewText')..addFont(Future.value(ByteData.sublistView(font)))).load();
        });
      }
      final boundary = GlobalKey();
      Future<void> capture(String name) async {
        if (previewDir == null) return;
        await tester.runAsync(() async {
        final image = await (boundary.currentContext!.findRenderObject() as RenderRepaintBoundary).toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('$previewDir/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
        });
      }
      await tester.pumpWidget(
        RepaintBoundary(key: boundary, child: UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: previewDir == null ? null : ThemeData(fontFamily: 'PreviewText'),
            home: Scaffold(body: CqSessionPage(sessionId: sid)),
          ),
        )),
      );
      await settle();
      await tap(const Key('cq-consent'));
      for (final step in [
        ('Q01', 'LIVE'),
        ('Q02', 'DAYS_1_3'),
        ('Q04', 'ONE'),
      ]) {
        final s = vm.session!;
        expect(s.presentation!['slot_id'], step.$1);
        final exact = (s.question(step.$1)['wording'] as Map)['EN'] as String;
        expect(find.text(exact), findsOneWidget);
        expect(s.manifest, original.manifest);
        if (step.$1 == 'Q04') await capture('before-extra');
        await tap(ValueKey('cq-option-${step.$2}'));
        await tap(const Key('cq-answer'));
      }
      if (previewDir != null) {
        final q = vm.session!.question('Q14');
        expect(vm.session!.presentation!['slot_id'], 'Q14');
        expect(find.text(q['wording']['EN']), findsOneWidget);
        expect(find.text(q['labels']['EN']['I']), findsOneWidget);
        expect(find.text(q['labels']['EN']['U']), findsOneWidget);
        await capture('last-question');
        await tap(const ValueKey('cq-option-I'));
        await tap(const Key('cq-answer'));
        await capture('final-review');
      }
      expect(vm.session!.data['can_submit'], isTrue);
      await tap(const ValueKey('cq-edit-Q04'));
      await tap(const ValueKey('cq-option-ZERO'));
      await tap(const Key('cq-answer'));
      await pumpNetwork(tester, vm.load);
      await tester.pump();
      expect(
        vm.session!.routing.firstWhere((r) => r['slot_id'] == 'Q04')['value'],
        'ZERO',
      );
      final history = await pumpNetwork(tester, () => repo.history(sid));
      expect((history['answers'] as List).length, previewDir == null ? 4 : 5);
      await tap(const Key('cq-submit'));
      expect(find.byKey(const Key('cq-submitted')), findsOneWidget);
      await capture('receipt');
      final saved = await pumpNetwork(tester, () => repo.read(sid));
      expect(saved.data['receipt'], vm.session!.data['receipt']);
      expect(saved.data['status'], 'SUBMITTED');
      print(
        'Verified real HTTP manifest ${saved.manifestHash}; saved receipt ${saved.data['receipt']['receipt_id']}.',
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(
        const Duration(seconds: 16),
      ); // expire HTTP keep-alive timers
    },
    skip: base == null,
  );
  testWidgets(
    'C1 BM manifest, every supported question type, stimuli and receipt',
    (tester) async {
      final sid = cqTestValue('CQ_TEST_C1_SESSION')!;
      final repo = ApiCustomerQuestionnaireRepository(
        MobileApiClient(
          bearer: () => cqTestValue('CQ_TEST_TOKEN'),
          baseUrl: base,
        ),
        allowIsolatedTesting: true,
      );
      final container = ProviderContainer(
        overrides: [
          if (!const bool.fromEnvironment('SITEWISE_ISOLATED_CQ_TEST'))
            cqRepositoryProvider.overrideWithValue(repo),
        ],
      );
      addTearDown(container.dispose);
      final subscription = container.listen(
        cqViewModelProvider(sid),
        (_, _) {},
      );
      addTearDown(subscription.close);
      if (const bool.fromEnvironment('SITEWISE_ISOLATED_CQ_TEST')) {
        expect(
          container.read(cqRepositoryProvider).allowIsolatedTesting,
          isTrue,
        );
      }
      final vm = container.read(cqViewModelProvider(sid));
      Future<void> settle() async {
        for (var i = 0; i < 300; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump();
          if (!vm.busy && (vm.session != null || vm.error != null)) break;
        }
        await tester.pumpAndSettle();
        expect(vm.busy, isFalse);
        expect(vm.error, isNull);
        expect(tester.takeException(), isNull);
      }

      Future<void> tap(Key key) async {
        final f = find.byKey(key);
        if (f.evaluate().isEmpty) await tester.scrollUntilVisible(f, 220);
        await tester.ensureVisible(f);
        await tester.pumpAndSettle();
        await tester.tap(f);
        await tester.pump();
        await settle();
      }

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(body: CqSessionPage(sessionId: sid)),
          ),
        ),
      );
      await settle();
      expect(
        vm.session,
        isNotNull,
        reason: 'Native questionnaire source did not finish loading.',
      );
      expect(identical(vm, container.read(cqViewModelProvider(sid))), isTrue);
      final binding = WidgetsBinding.instance;
      if (binding is IntegrationTestWidgetsFlutterBinding &&
          Platform.isAndroid) {
        await binding.convertFlutterSurfaceToImage();
        await tester.pump();
        final bytes = await binding.takeScreenshot('cq_before_consent');
        File(
          '${Directory.systemTemp.path}/cq_before_consent.png',
        ).writeAsBytesSync(bytes);
        print(
          'Native CQ consent screen captured; revision ${vm.session!.revision}.',
        );
      }
      await tap(const Key('cq-consent'));
      final presented = <String>[];
      var stimuli = 0;
      for (var i = 0; i < 40; i++) {
        final s = vm.session!;
        expect(s.data['locale'], 'BM');
        if (s.data['can_submit'] == true) break;
        if (s.data['next_stimulus_kind'] != null) {
          final kind = s.data['next_stimulus_kind'];
          final text = s.manifest['stimuli'][kind]['text']['BM'] as String;
          expect(find.text(text), findsOneWidget);
          await tap(const Key('cq-stimulus'));
          stimuli++;
          continue;
        }
        final p = s.presentation!,
            slot = p['slot_id'] as String,
            q = s.question(slot);
        expect(find.text(q['wording']['BM'] as String), findsOneWidget);
        final code = q['id'] == 'Q01'
            ? 'LIVE'
            : q['id'] == 'Q04'
            ? 'ONE'
            : q['validation']['substantive_codes'][0] as String;
        final label = q['labels']['BM'][code] as String;
        await tap(ValueKey('cq-option-$code'));
        expect(find.text(label), findsOneWidget);
        await tap(const Key('cq-answer'));
        presented.add(slot);
      }
      expect(presented.length, 14);
      expect(presented.toSet().length, 14);
      expect(stimuli, 5);
      await tap(const Key('cq-submit'));
      expect(find.byKey(const Key('cq-submitted')), findsOneWidget);
      final saved = await pumpNetwork(tester, () => repo.read(sid));
      expect(saved.data['receipt'], vm.session!.data['receipt']);
      print(
        'C1 BM: 14 distinct question cells, five delivered test stimuli, receipt ${saved.data['receipt']['receipt_id']}.',
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 16));
    },
    skip: base == null,
  );
}
