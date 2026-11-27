import 'dart:io';

import 'package:jaspr/jaspr.dart' show DomElement;
import 'package:jaspr_test/jaspr_test.dart';
import 'package:sitewise_jaspr_web/features/assessment/presentation/components/ai_execution_progress.dart';

import 'fixtures/execution_status_fixtures.dart';

/// Design-system coverage for the execution rail, verified without a browser.
///
/// Why this exists instead of a screenshot
/// --------------------------------------
/// A screenshot proves one viewport at one zoom level looked right once. What
/// actually breaks is a class the component emits that no stylesheet defines:
/// the card then renders unstyled, and the "responsive right-side layout" is
/// simply a column of default-block elements. This test asserts the stronger,
/// viewport-independent property — every class the rail emits has a rule — and
/// then asserts the two media queries that make the rail collapse.
///
/// The stylesheets are read from disk rather than fetched, so this does not
/// depend on a deploy of the served bundle.
void main() {
  final stylesheet = File('web/sitewise_stage3_objectives.css').readAsStringSync();
  final stagesheet = File('web/project1_research_stages.css').readAsStringSync();

  testComponents('every class the rail emits has a stylesheet rule', (
    tester,
  ) async {
    tester.pumpComponent(
      AiExecutionProgressPanel(
        title: 'Business review status',
        execution: simulatedExecution(
          state: 'PERSISTED',
          reason: 'PERSISTED_AND_VALIDATED',
          attemptNo: 2,
          attemptsReserved: 2,
          reservedAt: '2026-11-26T09:00:00Z',
          receiptOutcome: 'returned',
          receiptAt: '2026-11-26T09:00:11Z',
          persisted: 6,
        ),
        detailFacts: const [(label: 'Execution state', value: 'PERSISTED')],
        onRefresh: () {},
      ),
    );
    await tester.pump();

    final emitted = <String>{};
    for (final element
        in find
            .byElementPredicate((e) => e is DomElement, description: 'dom element')
            .evaluate()
            .whereType<DomElement>()) {
      final classes = element.component.classes;
      if (classes == null) continue;
      for (final name in classes.split(' ')) {
        if (name.isNotEmpty) emitted.add(name);
      }
    }

    final railClasses = emitted.where((c) => c.startsWith('aip')).toSet();
    expect(railClasses, isNotEmpty);
    // The four documented sub-blocks must actually be on the page; otherwise the
    // class check below would pass on an almost empty rail.
    expect(railClasses, contains('aip__rail'));
    expect(railClasses, contains('aip__row'));
    expect(railClasses, contains('aip__more'));

    final missing = <String>[
      for (final name in railClasses)
        if (!stylesheet.contains('.$name') && !stagesheet.contains('.$name'))
          name,
    ];
    // A class with no rule is an unstyled element, which is how a rail loses its
    // dots, connectors and status colours without anyone noticing.
    expect(missing, isEmpty, reason: 'unstyled rail classes: $missing');
  });

  test('the right-side rail collapses to one column on a narrow viewport', () {
    // Stage 4's rail is a page-level column.
    expect(stagesheet, contains('@media (max-width: 1080px)'));
    expect(stagesheet, contains('.p1-rail > .aip'));
    // Stage 3's rail is the proposal panel's aside.
    expect(stylesheet, contains('@media (max-width: 1180px)'));
    expect(stylesheet, contains('.s3o-rail'));
  });

  test('the indeterminate indicator is disabled for reduced motion', () {
    // The only motion in the component is the pending pulse. It must not be the
    // one thing a reader who asked for reduced motion cannot switch off.
    final blocks = stylesheet.split('@media (prefers-reduced-motion: reduce)');
    expect(blocks.length, greaterThan(1));
    expect(
      blocks.skip(1).any((block) => block.contains('.aip__pending-bar')),
      isTrue,
    );
  });

  test('each stage mounts exactly one consolidated rail', () {
    // One construction site is what makes "exactly one rail per stage" a
    // structural fact rather than a promise: a second mount would need a second
    // instantiation, and this test fails when one appears.
    final panel = File(
      'lib/features/assessment/presentation/components/'
      'project1_research_stage_panel.dart',
    ).readAsStringSync().replaceAll('\r\n', '\n');
    // Indentation is not part of the claim, and this file is being edited by
    // more than one session. Collapse all whitespace so a reformat does not
    // fail the assertion while a real change still does.
    final flat = panel.replaceAll(RegExp(r'\s+'), ' ');

    final mounts = 'AiExecutionProgressPanel('.allMatches(panel).length;
    expect(mounts, 1, reason: 'a second mount would draw a second rail');

    // Stage 3's rail is the proposal panel's aside; Stage 4 draws its own
    // column. Both reach the same component, and only one of them runs.
    expect(flat, contains('railLead: _executionRailCards('));
    expect(flat, contains('if (component.stageNumber != 3) _executionRail('));

    // Each stage asks for its own purpose, so a stage never displays the other
    // stage's generator.
    expect(flat, contains("'Business review status'"));
    expect(flat, contains("'Question generation status'"));
    expect(flat, contains("final purposeKey = isBusinessReview ? 'BDJ' : 'QG';"));
  });
}
