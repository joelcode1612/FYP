import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_logic/shared_logic.dart';

import 'package:fyp/presentation/mobile/entrepreneur/pages/m2_assessment_mobile_page.dart';

/// Frontend widget tests for the M2 assessment (FE-01 … FE-16).
///
/// Authorisation: `PROJECT1-M2-FRONTEND-TEST-ONLY-20261101`, receipt
/// `M2_FRONTEND_TEST_AUTH_20261101/01_TEST_AUTHORIZATION_RECEIPT.md`.
///
/// **Disposition discipline.** A test here only passes if it actually executes
/// and asserts. Behaviour that is not implemented is `skip`ped with a reason,
/// never faked. Backend save/resume, persistence and scientific admission do
/// not exist in this page and are therefore NOT_TESTED, not simulated.
///
/// All data is synthetic prototype fixture data (`PROTO-V4-2026-10-28`).
void main() {
  /// Pumps the assessment page with a very tall viewport so the lazy
  /// `ListView` builds all 21 items **and** the trailing submit control.
  /// (21 items ≈ 3.5k px + header/progress/actions; 6000 leaves headroom.)
  Future<ProviderContainer> pumpPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 6000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: M2AssessmentMobilePage()),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  group('FE — M2 assessment frontend', () {
    testWidgets('FE-01 screen loads without exceptions', (tester) async {
      await pumpPage(tester);
      expect(tester.takeException(), isNull);
      expect(find.text('M2 questionnaire'), findsOneWidget);
      expect(find.byType(M2AssessmentMobilePage), findsOneWidget);
    });

    testWidgets('FE-02 question rendering — fields and controls appear',
        (tester) async {
      await pumpPage(tester);
      // A choice item, a multi item and the single text item all render.
      expect(find.textContaining('Which best describes your role'),
          findsOneWidget);
      expect(find.byType(RadioListTile<String>), findsWidgets);
      expect(find.byType(FilterChip), findsWidgets);
      expect(find.byType(TextField), findsOneWidget);
    });

    testWidgets('FE-03 single-choice input updates state', (tester) async {
      final c = await pumpPage(tester);
      expect(c.read(m2AssessmentProvider).answers['M2-01'], 'Founder / owner');

      await tester.tap(find.text('Partner'));
      await tester.pumpAndSettle();

      expect(c.read(m2AssessmentProvider).answers['M2-01'], 'Partner');
    });

    testWidgets('FE-04 multiple-choice selections are preserved',
        (tester) async {
      final c = await pumpPage(tester);
      // M2-05 sample is 'Coffee, Pastries'.
      expect(c.read(m2AssessmentProvider).multi['M2-05'],
          containsAll(<String>['Coffee', 'Pastries']));

      await tester.tap(find.widgetWithText(FilterChip, 'Tea'));
      await tester.pumpAndSettle();

      final selected = c.read(m2AssessmentProvider).multi['M2-05']!;
      expect(selected, contains('Tea'));
      expect(selected, containsAll(<String>['Coffee', 'Pastries']),
          reason: 'adding a selection must not drop existing ones');
    });

    testWidgets('FE-05 text input is retained in state', (tester) async {
      final c = await pumpPage(tester);
      const typed = 'A takeaway kiosk near the campus gate.';

      await tester.enterText(find.byType(TextField), typed);
      await tester.pumpAndSettle();

      expect(c.read(m2AssessmentProvider).answers['M2-03'], typed);
    });

    testWidgets(
      'FE-06 previous/next navigation — NOT_IMPLEMENTED (no step navigation; '
      'single scrolling form)',
      (tester) async {
        // NOT IMPLEMENTED: this page is a single scrolling form. There is no
        // step navigation, so there is no draft-discard behaviour to assert.
        // Skipped rather than faked.
      },
      skip: true,
    );

    testWidgets('FE-07 progress uses 21 answer items, excluding governance',
        (tester) async {
      final c = await pumpPage(tester);
      final vm = c.read(m2AssessmentProvider.notifier);

      expect(vm.fieldCount, 21, reason: 'governance actions must not count');
      expect(kM2AnswerItems.length, 21);
      expect(kM2Actions.length, 2);
      expect(vm.fieldCount, isNot(23));

      // Seeded from samples → all 21 answered.
      expect(find.text('21 / 21'), findsOneWidget);
    });

    testWidgets('FE-08 required-field validation produces feedback',
        (tester) async {
      final c = await pumpPage(tester);
      final vm = c.read(m2AssessmentProvider.notifier);

      vm.clearAll();
      await tester.pumpAndSettle();
      expect(find.textContaining('required'), findsNothing,
          reason: 'no banner before a submit attempt');

      await tester.tap(find.text('Submit assessment'));
      await tester.pumpAndSettle();

      expect(c.read(m2AssessmentProvider).showErrors, isTrue);
      expect(c.read(m2AssessmentProvider).submitted, isFalse);
      expect(find.textContaining('required'), findsWidgets);
    });

    testWidgets('FE-09 error banner persists and shrinks as fields are filled',
        (tester) async {
      final c = await pumpPage(tester);
      final vm = c.read(m2AssessmentProvider.notifier);

      vm.clearAll();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Submit assessment'));
      await tester.pumpAndSettle();

      final before = vm.missingRequired.length;
      expect(before, greaterThan(0));

      // Fix one required field.
      vm.setAnswer('M2-01', 'Partner');
      await tester.pumpAndSettle();

      expect(c.read(m2AssessmentProvider).showErrors, isTrue,
          reason: 'banner must not vanish on the first keystroke');
      expect(vm.missingRequired.length, lessThan(before));
    });

    testWidgets('FE-10 reset restores the synthetic initial state',
        (tester) async {
      final c = await pumpPage(tester);
      final vm = c.read(m2AssessmentProvider.notifier);

      vm.clearAll();
      await tester.pumpAndSettle();
      expect(vm.answeredCount, 0);

      await tester.tap(find.text('Reset to sample'));
      await tester.pumpAndSettle();

      expect(vm.answeredCount, vm.fieldCount);
      expect(c.read(m2AssessmentProvider).answers['M2-01'], 'Founder / owner');
      expect(c.read(m2AssessmentProvider).submitted, isFalse);
    });

    testWidgets('FE-11 Riverpod state lifecycle — container owns the state',
        (tester) async {
      final c = await pumpPage(tester);
      expect(c.read(m2AssessmentProvider).answers, isNotEmpty);

      // A disposed container must release the Notifier.
      final probe = ProviderContainer();
      probe.read(m2AssessmentProvider.notifier).setAnswer('M2-01', 'Manager');
      expect(probe.read(m2AssessmentProvider).answers['M2-01'], 'Manager');
      probe.dispose();

      expect(
        () => probe.read(m2AssessmentProvider),
        throwsA(anything),
        reason: 'reading a disposed container must throw, not return stale state',
      );
    });

    testWidgets('FE-12 two assessments do not leak answers', (tester) async {
      // Container A — mutate.
      final a = ProviderContainer();
      addTearDown(a.dispose);
      a.read(m2AssessmentProvider.notifier).setAnswer('M2-01', 'Manager');

      // Container B — untouched.
      final b = ProviderContainer();
      addTearDown(b.dispose);

      expect(a.read(m2AssessmentProvider).answers['M2-01'], 'Manager');
      expect(b.read(m2AssessmentProvider).answers['M2-01'], 'Founder / owner',
          reason: 'state must not be shared between assessment instances');
    });

    testWidgets(
      'FE-13 loading/error presentation — NOT_IMPLEMENTED (no async work in '
      'this page; backend save/resume must not be simulated)',
      (tester) async {
        // NOT IMPLEMENTED: the page performs no asynchronous work. There is no
        // loading state and no error path to exercise. Skipped, not faked.
      },
      skip: true,
    );

    testWidgets('FE-14 essential controls usable on a small screen',
        (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final container = ProviderContainer();
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: M2AssessmentMobilePage()),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull,
          reason: 'no overflow or layout exception at 360x640');

      // The submit control exists and is reachable by scrolling.
      await tester.scrollUntilVisible(
        find.text('Submit assessment'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Submit assessment'), findsOneWidget);
    });

    testWidgets('FE-15 governance actions stay distinct from answer fields',
        (tester) async {
      final c = await pumpPage(tester);
      final vm = c.read(m2AssessmentProvider.notifier);

      expect(vm.fieldCount, 21);
      expect(kM2Actions.length, 2);

      // Governance events are rendered under their own heading.
      expect(find.text('REVIEW ACTIONS'), findsOneWidget);

      // They are never counted as answers.
      for (final action in kM2Actions) {
        expect(vm.missingRequired.map((i) => i.id), isNot(contains(action.id)));
      }
      expect(vm.answeredCount, 21);
    });

    testWidgets('FE-16 submission interaction — valid and invalid',
        (tester) async {
      final c = await pumpPage(tester);
      final vm = c.read(m2AssessmentProvider.notifier);

      // Invalid: clear everything, submit.
      vm.clearAll();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Submit assessment'));
      await tester.pumpAndSettle();
      // Invalid: clear everything, submit.
      // Both the persistent banner and the snackbar mention the gap, so this
      // asserts "at least one" rather than an exact count.
      expect(find.textContaining('still empty'), findsWidgets);
      expect(c.read(m2AssessmentProvider).submitted, isFalse);

      // Snackbars queue: let the failure snackbar expire so the success one
      // is not stuck behind it.
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();

      // Valid: restore samples, submit.
      vm.resetToSamples();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Submit assessment'));
      await tester.pumpAndSettle();

      expect(c.read(m2AssessmentProvider).submitted, isTrue);
      expect(find.textContaining('submitted (prototype'), findsOneWidget,
          reason: 'the confirmation must say nothing is stored');
    });
  });
}
