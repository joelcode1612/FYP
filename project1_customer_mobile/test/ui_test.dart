import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project1_customer_mobile/data/questionnaire_repository.dart';
import 'package:project1_customer_mobile/model/question.dart';
import 'package:project1_customer_mobile/view/project1_app.dart';
import 'package:project1_customer_mobile/viewmodel/questionnaire_viewmodel.dart';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final font = FontLoader('ProjectRoboto')
      ..addFont(rootBundle.load('assets/fonts/roboto-regular.ttf'))
      ..addFont(rootBundle.load('assets/fonts/roboto-bold.ttf'));
    await font.load();
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
  });
  Future<void> mount(
    WidgetTester tester,
    ProviderContainer container, {
    Size size = const Size(390, 844),
    double scale = 1,
    GlobalKey? boundary,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: RepaintBoundary(
          key: boundary,
          child: MediaQuery(
            data: MediaQueryData(
              size: size,
              textScaler: TextScaler.linear(scale),
            ),
            child: const Project1App(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> snapshot(WidgetTester tester, GlobalKey key, String name) async {
    // Test-renderer PNG evidence; not a substitute for Android/iOS testing.
    await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final dir = Directory('artifacts');
      await dir.create(recursive: true);
      await File(
        '${dir.path}/$name.png',
      ).writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  void goToQ05(QuestionnaireViewModel vm) {
    vm.setConsent(true);
    vm.start();
    for (final code in ['LIVE', 'DAYS_4_10', 'HOME', 'ZERO']) {
      vm.select(code);
      vm.next();
    }
    vm.select('PROB_YES');
  }

  void goToReview(QuestionnaireViewModel vm) {
    goToQ05(vm);
    vm.next();
    for (final code in ['COFFEE_ESPRESSO', 'SOMEWHAT_ACCEPTABLE', 'SOCIAL']) {
      vm.select(code);
      vm.next();
    }
    for (final feature in QuestionnaireRepository.features) {
      vm.rate(feature.id, 'VERY_IMPORTANT');
    }
    vm.next();
    vm.skipOptional();
    vm.skipOptional();
    vm.skipOptional();
  }

  testWidgets(
    'welcome consent gate, bilingual labels and question selection work',
    (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await mount(tester, container);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('start')))
            .onPressed,
        isNull,
      );
      await tester.ensureVisible(find.byKey(const ValueKey('consent')));
      await tester.tap(find.byKey(const ValueKey('consent')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('start')));
      await tester.pumpAndSettle();
      expect(find.text('Q01'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('option_Q01_LIVE')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('language_bm')));
      await tester.pumpAndSettle();
      expect(find.text('Saya tinggal di kawasan ini'), findsOneWidget);
      expect(container.read(questionnaireProvider).answers['Q01']!.codes, {
        'LIVE',
      });
      await tester.tap(find.byKey(const ValueKey('next')));
      await tester.pumpAndSettle();
      expect(find.text('Q02'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('Q05 styled selected option and route-aware review screenshots', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final key = GlobalKey();
    final vm = container.read(questionnaireProvider.notifier);
    await mount(tester, container, boundary: key);
    await snapshot(tester, key, '01_welcome');
    goToQ05(vm);
    await tester.pumpAndSettle();
    expect(find.text('Q05'), findsOneWidget);
    expect(find.text('Step 5 of 12'), findsOneWidget);
    await snapshot(tester, key, '02_q05');
    vm.next();
    for (final code in ['COFFEE_ESPRESSO', 'SOMEWHAT_ACCEPTABLE', 'SOCIAL']) {
      vm.select(code);
      vm.next();
    }
    for (final feature in QuestionnaireRepository.features) {
      vm.rate(feature.id, 'VERY_IMPORTANT');
    }
    vm.next();
    vm.skipOptional();
    vm.skipOptional();
    vm.skipOptional();
    await tester.pumpAndSettle();
    expect(find.textContaining('9 answered of 12 shown'), findsOneWidget);
    expect(find.text('13 of 13'), findsNothing);
    expect(find.text('You have answered all 13 questions.'), findsNothing);
    await snapshot(tester, key, '03_review');
    await tester.tap(find.byKey(const ValueKey('review_group_Q07')));
    await tester.pumpAndSettle();
    expect(find.text('Not shown · outside route'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('submit')));
    await tester.pumpAndSettle();
    expect(find.text('Thank you for trying Project1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  for (final language in AppLanguage.values) {
    for (final page in ['welcome', 'q05', 'review', 'matrix']) {
      testWidgets(
        '$page at 320x568 with 200% text in ${language.name} has no overflow',
        (tester) async {
          final container = ProviderContainer();
          addTearDown(container.dispose);
          final vm = container.read(questionnaireProvider.notifier);
          if (page == 'q05') goToQ05(vm);
          if (page == 'review') goToReview(vm);
          if (page == 'matrix') {
            goToQ05(vm);
            vm.next();
            for (final code in ['NONE', 'CANNOT_JUDGE', 'NONE']) {
              vm.select(code);
              vm.next();
            }
          }
          vm.setLanguage(language);
          await mount(tester, container, size: const Size(320, 568), scale: 2);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
