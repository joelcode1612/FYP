import 'package:jaspr_test/jaspr_test.dart';
import 'package:jaspr/jaspr.dart' show DomElement;
import 'package:sitewise_jaspr_web/features/assessment/data/stage_four_five_api.dart';
import 'package:sitewise_jaspr_web/features/assessment/presentation/components/ai_execution_progress.dart';

/// A purpose whose four milestones the server has all marked completed.
AiExecutionPurpose _persisted() => AiExecutionPurpose(
  purpose: 'BDJ',
  state: 'PERSISTED',
  reason: 'PERSISTED_AND_VALIDATED',
  attemptNo: 2,
  attemptsReserved: 2,
  reservedAt: '2026-11-26T09:00:00Z',
  receiptOutcome: 'returned',
  receiptAt: '2026-11-26T09:00:11Z',
  persisted: 6,
  attributable: true,
  milestones: const [
    AiMilestone(name: 'RESERVED', status: 'COMPLETED'),
    AiMilestone(name: 'RETURNED', status: 'COMPLETED'),
    AiMilestone(name: 'VALIDATED', status: 'COMPLETED'),
    AiMilestone(name: 'PERSISTED', status: 'COMPLETED'),
  ],
);

void main() {
  test('a purpose parses the attempt identity it was given', () {
    final purpose = AiExecutionPurpose.fromJson({
      'purpose': 'BDJ',
      'state': 'RETURNED',
      'reason': 'PERSISTENCE_UNATTRIBUTABLE',
      'attempt_no': 3,
      'assessment_revision': 33,
      'stale': true,
      'domain_store': 'public.m2_bdj_objective_proposals',
      'domain': {'persisted': 0, 'pending_validation': 0, 'attributable': false},
      'domain_assessment_wide': {'persisted': 6, 'run_bound': 0},
      'milestones': [
        {'milestone': 'RESERVED', 'status': 'COMPLETED'},
        {'milestone': 'RETURNED', 'status': 'COMPLETED'},
        {'milestone': 'VALIDATED', 'status': 'ACTIVE'},
        {'milestone': 'PERSISTED', 'status': 'PENDING'},
      ],
    });
    expect(purpose.assessmentRevision, 33);
    expect(purpose.stale, isTrue);
    expect(purpose.attributable, isFalse);
    expect(purpose.assessmentWidePersisted, 6);
    expect(purpose.milestones.length, 4);
    expect(purpose.milestones.last.status, 'PENDING');
  });

  test('a reading exposes the timing policy instead of a hardcoded budget', () {
    final reading = AiExecutionReading.fromJson({
      'contract': 'sitewise-ai-execution-status/2',
      'current_revision': 33,
      'progress_percent': null,
      'milestones': ['RESERVED', 'RETURNED', 'VALIDATED', 'PERSISTED'],
      'unprovable_milestones': ['DISPATCHED'],
      'timing': {'provider_timeout_seconds': 90, 'grace_seconds': 120},
      'purposes': const [],
    });
    expect(reading.contract, 'sitewise-ai-execution-status/2');
    expect(reading.providerTimeoutSeconds, 90);
    expect(reading.graceSeconds, 120);
    expect(reading.progressPercent, isNull);
    expect(reading.unprovableMilestones, ['DISPATCHED']);
  });

  testComponents('the rail draws four milestones and never a fifth', (tester) async {
    tester.pumpComponent(
      AiExecutionProgressPanel(title: 'Business review status', execution: _persisted()),
    );
    await tester.pump();
    expect(find.text('Reserved'), findsOneComponent);
    expect(find.text('Returned'), findsOneComponent);
    expect(find.text('Validated'), findsOneComponent);
    expect(find.text('Persisted'), findsOneComponent);
    // The milestone the ledger cannot prove must not be drawn as a step.
    expect(find.text('Dispatched'), findsNothing);
    expect(find.text('Completed'), findsNComponents(4));
  });

  testComponents('no percentage is shown anywhere on the rail', (tester) async {
    tester.pumpComponent(
      AiExecutionProgressPanel(title: 'Business review status', execution: _persisted()),
    );
    await tester.pump();
    expect(find.textContaining('%'), findsNothing);
  });

  testComponents('an unreadable status is not an execution that never ran', (
    tester,
  ) async {
    tester.pumpComponent(
      const AiExecutionProgressPanel(
        title: 'Business review status',
        execution: null,
        // "Unreadable" is now an explicit read state. A null execution alone no
        // longer means the read failed, because it also means "not asked yet"
        // and "the response carried no entry for this purpose".
        readState: RailReadState.failed,
      ),
    );
    await tester.pump();
    expect(find.textContaining('unavailable'), findsOneComponent);
    expect(find.textContaining('nothing has run'), findsOneComponent);
    expect(find.text('Check again'), findsNothing); // no callback supplied
  });

  testComponents('a response with no entry for this purpose is not a failure', (
    tester,
  ) async {
    tester.pumpComponent(
      const AiExecutionProgressPanel(
        title: 'Business review status',
        execution: null,
      ),
    );
    await tester.pump();
    // The server answered. It simply did not carry this purpose, which is a gap
    // in the contract — saying "could not be read" here would be a claim the
    // read has no evidence for (CP-PROG-05).
    expect(find.textContaining('did not include'), findsOneComponent);
    expect(find.textContaining('could not be read'), findsNothing);
  });

  testComponents('a status that has not answered yet claims nothing', (
    tester,
  ) async {
    tester.pumpComponent(
      const AiExecutionProgressPanel(
        title: 'Business review status',
        execution: null,
        readState: RailReadState.pending,
      ),
    );
    await tester.pump();
    expect(find.textContaining('Reading execution status'), findsOneComponent);
    // A pending read knows nothing about the ledger, so it must not borrow
    // either of the other two sentences.
    expect(find.textContaining('nothing has run'), findsNothing);
    expect(find.textContaining('could not be read'), findsNothing);
  });

  testComponents('a superseded execution keeps its evidence but is marked stale', (
    tester,
  ) async {
    final purpose = AiExecutionPurpose(
      purpose: 'BDJ',
      state: 'PERSISTED',
      reason: 'PERSISTED_AND_VALIDATED',
      stale: true,
      assessmentRevision: 33,
      milestones: _persisted().milestones,
    );
    tester.pumpComponent(
      AiExecutionProgressPanel(title: 'Business review status', execution: purpose),
    );
    await tester.pump();
    expect(find.text('Not current'), findsOneComponent);
    // The historical completion is retained, not erased.
    expect(find.text('Completed'), findsNComponents(4));
  });

  testComponents('expanding a milestone reveals detail without changing state', (
    tester,
  ) async {
    tester.pumpComponent(
      AiExecutionProgressPanel(title: 'Business review status', execution: _persisted()),
    );
    await tester.pump();
    expect(find.textContaining('durably reserved'), findsNothing);

    // The first button on the rail is the Reserved milestone's toggle.
    await tester.click(find.tag('button').first);
    await tester.pump();

    expect(find.textContaining('durably reserved'), findsOneComponent);
    // Still four completed: expanding is read-only.
    expect(find.text('Completed'), findsNComponents(4));
  });

  testComponents('More details survives the next status reading', (tester) async {
    // `open` is an attribute the browser would normally own. This card is
    // rebuilt whenever a reading arrives, and a rebuild re-applies the
    // attribute set the component was given — which had no `open` in it. The
    // panel the reader had just opened therefore snapped shut. The component
    // holds the flag now, so the assertion below is what stops that returning.
    Finder disclosure({required bool open}) => find.byElementPredicate(
      (element) =>
          element is DomElement &&
          (element.component.classes ?? '')
              .split(' ')
              .contains('aip__more') &&
          (element.component.attributes?.containsKey('open') ?? false) == open,
      description: 'the disclosure, ${open ? 'open' : 'closed'}',
    );

    var refreshes = 0;
    tester.pumpComponent(
      AiExecutionProgressPanel(
        title: 'Business review status',
        execution: _persisted(),
        detailFacts: const [(label: 'Execution state', value: 'PERSISTED')],
        onRefresh: () => refreshes += 1,
      ),
    );
    await tester.pump();
    expect(find.text('More details'), findsOneComponent);
    expect(disclosure(open: false), findsOneComponent);
    expect(disclosure(open: true), findsNothing);

    await tester.click(find.tag('summary'));
    await tester.pump();
    // The old markup left this to the browser, so nothing here would have
    // carried `open` at all — the element only ever had it in the DOM, which
    // is exactly what a re-render discarded.
    expect(disclosure(open: true), findsOneComponent);

    // Expanding a milestone rebuilds this card from the same State, the way a
    // status reading does. The disclosure is still open afterwards.
    await tester.click(find.tag('button').first);
    await tester.pump();
    expect(disclosure(open: true), findsOneComponent);
    // Opening it contacted nothing, before or after the rebuild.
    expect(refreshes, 0);
  });

  testComponents('source facts survive a ledger read that failed', (
    tester,
  ) async {
    // The source evaluation and the execution rail are read from different
    // endpoints. A failed rail read must not erase a source fact that was read
    // successfully: that would turn one endpoint's failure into another
    // endpoint's answer, and it would hide the only account of why the stage is
    // held.
    tester.pumpComponent(
      AiExecutionProgressPanel(
        title: 'Business review status',
        readState: RailReadState.failed,
        execution: null,
        detailFacts: const [
          (
            label: 'BDJ source evaluation',
            value: 'No current result (NO_CURRENT_RESULT)',
          ),
        ],
      ),
    );
    await tester.pump();
    expect(
      find.textContaining('Execution status is unavailable'),
      findsOneComponent,
    );
    expect(find.text('BDJ source evaluation'), findsOneComponent);
    expect(find.text('More details'), findsOneComponent);
  });

  testComponents('a contract gap does not hide the source facts', (
    tester,
  ) async {
    // `missing` means the reading arrived without this purpose. That says
    // nothing about the source the stage reads, so the disclosure still renders.
    tester.pumpComponent(
      AiExecutionProgressPanel(
        title: 'Business review status',
        readState: RailReadState.loaded,
        execution: null,
        detailFacts: const [
          (label: 'BDJ source evaluation', value: 'Not recorded'),
        ],
      ),
    );
    await tester.pump();
    expect(find.textContaining('did not include'), findsOneComponent);
    expect(find.text('BDJ source evaluation'), findsOneComponent);
  });

  testComponents('the footnote states what the block actually contains', (
    tester,
  ) async {
    // The default wording says "one attempt". A caller that also passes source
    // facts supplies its own sentence, so the footnote never describes a source
    // fact as an attempt fact — the two come from different stores (DD-124).
    tester.pumpComponent(
      AiExecutionProgressPanel(
        title: 'Business review status',
        execution: _persisted(),
        detailFacts: const [
          (label: 'BDJ source evaluation', value: 'Not recorded'),
        ],
        detailScope: 'These are recorded facts: the confirmed source.',
      ),
    );
    await tester.pump();
    expect(
      find.textContaining('These are recorded facts: the confirmed source.'),
      findsOneComponent,
    );
    expect(find.textContaining('about one attempt'), findsNothing);
  });
}
