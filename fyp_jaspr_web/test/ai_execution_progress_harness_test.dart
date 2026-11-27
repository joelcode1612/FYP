import 'dart:async';

import 'package:jaspr/jaspr.dart' show DomElement;
import 'package:jaspr_test/jaspr_test.dart';
import 'package:sitewise_jaspr_web/features/assessment/application/execution_status_poller.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/stage_four_five_api.dart';
import 'package:sitewise_jaspr_web/features/assessment/presentation/components/ai_execution_progress.dart';

import 'fixtures/execution_status_fixtures.dart';

/// The independent harness for the LLM execution progress component.
///
/// Every case below is driven by a *simulated status response* — a plain map in
/// the shape the route emits, parsed by the production parser. No test opens a
/// socket, and no fake service is introduced into the application: the polling
/// tests pass a closure over a scripted list of readings, which is the same
/// seam the production page uses for its HTTP client (CP-P05).
///
/// `STATE-nn` covers the seventeen execution states the brief enumerates.
/// `POLL-nn` covers the polling-lifecycle properties of CP-P03.

/// A reader whose answers the test supplies one at a time.
class _ScriptedReader {
  final List<Completer<AiExecutionReading?>> _pending = [];
  final List<String> requestedFor = [];

  Future<AiExecutionReading?> call(String assessmentId) {
    requestedFor.add(assessmentId);
    final completer = Completer<AiExecutionReading?>();
    _pending.add(completer);
    return completer.future;
  }

  int get calls => _pending.length;

  void answer(int index, AiExecutionReading? reading) =>
      _pending[index].complete(reading);

  void fail(int index) =>
      _pending[index].completeError(StateError('status read failed'));
}

/// A scheduler the test drives by hand.
///
/// Injectable rather than faked at the `Timer` level so the assertion is about
/// the delay the poller *asked for*, not about how long the test happened to
/// wait.
class _FakeSchedule {
  final List<({Duration delay, void Function() callback, bool cancelled})> ticks =
      [];

  void Function() schedule(Duration delay, void Function() callback) {
    final index = ticks.length;
    ticks.add((delay: delay, callback: callback, cancelled: false));
    return () => ticks[index] = (
      delay: ticks[index].delay,
      callback: ticks[index].callback,
      cancelled: true,
    );
  }

  List<Duration> get delays => [for (final tick in ticks) tick.delay];

  ({Duration delay, void Function() callback, bool cancelled}) get last =>
      ticks.last;

  void fireLast() {
    final tick = ticks.last;
    if (!tick.cancelled) tick.callback();
  }
}

Future<void> _settle() async {
  for (var i = 0; i < 6; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// A poller wired to a scripted reader and a hand-driven scheduler.
({ExecutionStatusPoller poller, _ScriptedReader reader, _FakeSchedule clock})
_harness({int maxConsecutiveFailures = 5}) {
  final reader = _ScriptedReader();
  final clock = _FakeSchedule();
  late final ExecutionStatusPoller poller;
  poller = ExecutionStatusPoller(
    read: reader.call,
    onChanged: (_) {},
    maxConsecutiveFailures: maxConsecutiveFailures,
    schedule: clock.schedule,
  );
  return (poller: poller, reader: reader, clock: clock);
}

void main() {
  // ==========================================================================
  // STATE — the seventeen execution states
  // ==========================================================================

  testComponents('STATE-01 · no execution started proves nothing', (tester) async {
    tester.pumpComponent(
      AiExecutionProgressPanel(
        title: 'Business review status',
        execution: simulatedExecution(state: 'BLOCKED', reason: 'NO_ATTEMPT_RESERVED'),
      ),
    );
    await tester.pump();

    // Four milestones, all unproven. The rail must not imply that an attempt
    // was made and failed.
    expect(find.text('Pending'), findsNComponents(4));
    expect(find.text('Completed'), findsNothing);
    expect(find.text('Dispatched'), findsNothing);
    expect(find.textContaining('%'), findsNothing);
  });

  testComponents('STATE-02 · a reserved attempt proves the first step only', (
    tester,
  ) async {
    tester.pumpComponent(
      AiExecutionProgressPanel(
        title: 'Business review status',
        execution: simulatedExecution(
          state: 'PROCESSING',
          reason: 'RESERVED_AWAITING_RECEIPT',
          attemptNo: 1,
          attemptsReserved: 1,
          reservedAt: '2026-11-26T09:00:00Z',
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Completed'), findsOneComponent); // Reserved
    expect(find.text('In progress'), findsOneComponent); // Returned
    expect(find.text('Pending'), findsNComponents(2));
  });

  testComponents('STATE-03 · processing is indeterminate, never a fraction', (
    tester,
  ) async {
    tester.pumpComponent(
      AiExecutionProgressPanel(
        title: 'Question generation status',
        purposeKey: 'qg',
        execution: simulatedExecution(
          purpose: 'QG',
          state: 'PROCESSING',
          reason: 'RESERVED_AWAITING_RECEIPT',
          attemptNo: 2,
          attemptsReserved: 2,
        ),
      ),
    );
    await tester.pump();

    // The moving element is a pulse on the step whose evidence has not arrived.
    expect(find.text('In progress'), findsOneComponent);
    // No percentage, and no second bar that could be read as one.
    expect(find.textContaining('%'), findsNothing);
    expect(find.textContaining('of 4'), findsNothing);
  });

  testComponents('STATE-04 · a returned answer does not prove validation', (
    tester,
  ) async {
    tester.pumpComponent(
      AiExecutionProgressPanel(
        title: 'Business review status',
        execution: simulatedExecution(
          state: 'RETURNED',
          reason: 'PERSISTENCE_UNATTRIBUTABLE',
          attemptNo: 2,
          attemptsReserved: 2,
          receiptOutcome: 'returned',
          receiptAt: '2026-11-26T09:00:11Z',
          attributable: false,
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Completed'), findsNComponents(2)); // Reserved, Returned
    expect(find.text('In progress'), findsOneComponent); // Validated
    expect(find.text('Pending'), findsOneComponent); // Persisted
  });

  testComponents('STATE-05 · validation in flight holds at Validated', (
    tester,
  ) async {
    tester.pumpComponent(
      AiExecutionProgressPanel(
        title: 'Question generation status',
        purposeKey: 'qg',
        execution: simulatedExecution(
          purpose: 'QG',
          state: 'VALIDATING',
          reason: 'PERSISTED_PENDING_VALIDATION',
          attemptNo: 1,
          attemptsReserved: 1,
          persisted: 3,
          pendingValidation: 3,
        ),
      ),
    );
    await tester.pump();

    expect(find.text('In progress'), findsOneComponent);
    expect(find.text('Completed'), findsNComponents(2));

    await tester.click(find.tag('button').at(2)); // Validated
    await tester.pump();
    expect(
      find.textContaining('3 record(s) still awaiting validation'),
      findsOneComponent,
    );
  });

  testComponents('STATE-06 · a persisted result completes all four', (
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
          persisted: 6,
          attributable: true,
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Completed'), findsNComponents(4));
    expect(find.text('In progress'), findsNothing);
    expect(find.text('Not current'), findsNothing);
  });

  testComponents('STATE-07 · a refused attempt is not an unknown outcome', (
    tester,
  ) async {
    tester.pumpComponent(
      AiExecutionProgressPanel(
        title: 'Business review status',
        execution: simulatedExecution(
          state: 'FAILED',
          reason: 'RECEIPT_REFUSED',
          attemptNo: 3,
          attemptsReserved: 3,
          receiptOutcome: 'refused',
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Failed'), findsOneComponent); // Returned is the failure
    expect(find.textContaining('refused'), findsOneComponent);
    expect(find.textContaining('not retried automatically'), findsOneComponent);
  });

  testComponents('STATE-08 · a returned answer with no stored row is not Persisted', (
    tester,
  ) async {
    tester.pumpComponent(
      AiExecutionProgressPanel(
        title: 'Business review status',
        execution: simulatedExecution(
          state: 'RETURNED',
          reason: 'RETURNED_NOT_PERSISTED',
          attemptNo: 2,
          attemptsReserved: 2,
          persisted: 0,
          attributable: true,
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Pending'), findsOneComponent); // Persisted
    expect(find.text('Completed'), findsNComponents(2));
  });

  testComponents('STATE-09 · an unknown outcome is not reported as a failure', (
    tester,
  ) async {
    tester.pumpComponent(
      AiExecutionProgressPanel(
        title: 'Business review status',
        execution: simulatedExecution(
          state: 'UNKNOWN_OUTCOME',
          reason: 'RESERVED_PAST_DISPATCH_WINDOW',
          attemptNo: 1,
          attemptsReserved: 1,
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Outcome unknown'), findsOneComponent);
    // The wording must not claim the provider refused, because it may have been
    // reached and answered after the window closed.
    expect(find.textContaining('Whether the provider was reached is unknown'),
        findsOneComponent);
    expect(find.text('Failed'), findsNothing);
  });

  testComponents('STATE-10 · a failed read is not a failed execution', (
    tester,
  ) async {
    tester.pumpComponent(
      const AiExecutionProgressPanel(
        title: 'Business review status',
        execution: null,
        readState: RailReadState.failed,
      ),
    );
    await tester.pump();

    expect(find.textContaining('Execution status is unavailable'),
        findsOneComponent);
    expect(find.textContaining('not the same as'), findsOneComponent);
    // Nothing on screen may claim an attempt was refused or that none ran.
    expect(find.text('Failed'), findsNothing);
    expect(find.textContaining('nothing has run'), findsOneComponent);
  });

  testComponents('STATE-11 · a superseded execution is marked, not erased', (
    tester,
  ) async {
    tester.pumpComponent(
      AiExecutionProgressPanel(
        title: 'Business review status',
        execution: simulatedExecution(
          state: 'PERSISTED',
          reason: 'PERSISTED_AND_VALIDATED',
          stale: true,
          assessmentRevision: 32,
          attemptNo: 1,
          attemptsReserved: 1,
          persisted: 5,
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Not current'), findsOneComponent);
    // The historical evidence is retained: the owner can still see what ran.
    expect(find.text('Completed'), findsNComponents(4));
  });

  testComponents('STATE-12 · unattributable persistence cannot complete Persisted', (
    tester,
  ) async {
    tester.pumpComponent(
      AiExecutionProgressPanel(
        title: 'Business review status',
        execution: simulatedExecution(
          state: 'RETURNED',
          reason: 'PERSISTENCE_UNATTRIBUTABLE',
          attemptNo: 3,
          attemptsReserved: 3,
          persisted: 0,
          attributable: false,
          assessmentWidePersisted: 6,
        ),
      ),
    );
    await tester.pump();

    // The Persisted milestone must remain unproven even though six rows exist.
    expect(find.text('Pending'), findsOneComponent);
    expect(find.text('Completed'), findsNComponents(2));

    await tester.click(find.tag('button').at(3)); // Persisted
    await tester.pump();
    expect(
      find.textContaining('6 record(s) stored for this assessment, none '
          'attributable to this attempt'),
      findsOneComponent,
    );
  });

  testComponents(
    'STATE-13 · a zero-result completion cannot be proven, so it is not claimed',
    (tester) async {
      // The brief asks for "valid zero-result completion". Today the ledger
      // records that the provider answered and the domain table has no row, and
      // those two facts cannot be told apart from "the write failed". The rail
      // therefore stops at Returned. Migration 20261126_02 (write acknowledgment)
      // is what will let this case complete, and until it is applied claiming
      // completion would be a fabrication.
      tester.pumpComponent(
        AiExecutionProgressPanel(
          title: 'Business review status',
          execution: simulatedExecution(
            state: 'RETURNED',
            reason: 'RETURNED_NOT_PERSISTED',
            attemptNo: 4,
            attemptsReserved: 4,
            persisted: 0,
            attributable: true,
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Pending'), findsOneComponent);
      expect(find.text('Completed'), findsNComponents(2));
      expect(find.textContaining('Persisted'), findsOneComponent);
    },
  );

  test('STATE-14 · two objectives never answer for each other', () {
    final forA = simulatedReading(
      objectiveId: 'proposal:aaaa',
      objectiveScoped: true,
      purpose: simulatedPurpose(
        purpose: 'QG',
        state: 'PROCESSING',
        attemptNo: 1,
        attemptsReserved: 1,
      ),
    );
    final forB = simulatedReading(
      objectiveId: 'proposal:bbbb',
      objectiveScoped: true,
      purpose: simulatedPurpose(
        purpose: 'QG',
        state: 'PERSISTED',
        attemptNo: 2,
        attemptsReserved: 2,
        persisted: 4,
      ),
    );

    expect(forA.objectiveId, 'proposal:aaaa');
    expect(forA.answersObjective('proposal:aaaa'), isTrue);
    // The whole point: a response for B must be rejected while polling A.
    expect(forA.answersObjective('proposal:bbbb'), isFalse);
    expect(forB.answersObjective('proposal:aaaa'), isFalse);
    expect(forB.forPurpose('QG')!.state, 'PERSISTED');
    expect(forA.forPurpose('QG')!.state, 'PROCESSING');

    // A stage-wide reading is not an answer to an objective-scoped question: it
    // reports the newest attempt whichever objective produced it.
    final stageWide = simulatedReading(
      purpose: simulatedPurpose(purpose: 'QG', state: 'PERSISTED'),
    );
    expect(stageWide.objectiveScoped, isFalse);
    expect(stageWide.answersObjective('proposal:aaaa'), isFalse);
  });

  // ==========================================================================
  // POLL — the polling lifecycle (CP-P03)
  // ==========================================================================

  test('POLL-01 · the first read starts immediately and claims nothing', () async {
    final h = _harness();
    expect(h.poller.view.readState, RailReadState.pending);

    h.poller.start('assessment-a');
    await _settle();

    expect(h.reader.calls, 1);
    expect(h.reader.requestedFor.single, 'assessment-a');
    expect(h.poller.view.inFlight, isTrue);
    expect(h.poller.view.readState, RailReadState.pending);
    expect(h.poller.view.reading, isNull);
  });

  test('POLL-02 · polling continues every two seconds while work is in flight', () async {
    final h = _harness();
    h.poller.start('assessment-a');
    await _settle();
    h.reader.answer(
      0,
      simulatedReading(
        purpose: simulatedPurpose(
          state: 'PROCESSING',
          attemptNo: 1,
          attemptsReserved: 1,
        ),
      ),
    );
    await _settle();

    expect(h.clock.delays, [const Duration(seconds: 2)]);
    h.clock.fireLast();
    await _settle();
    expect(h.reader.calls, 2);

    h.reader.answer(
      1,
      simulatedReading(
        purpose: simulatedPurpose(
          state: 'PROCESSING',
          attemptNo: 1,
          attemptsReserved: 1,
        ),
      ),
    );
    await _settle();
    expect(h.clock.delays, [
      const Duration(seconds: 2),
      const Duration(seconds: 2),
    ]);
  });

  test('POLL-03 · two reads for one assessment never overlap', () async {
    final h = _harness();
    h.poller.start('assessment-a');
    await _settle();

    // A second start, and a manual refresh, while the first is outstanding.
    h.poller.start('assessment-a');
    await h.poller.refresh();
    await _settle();

    expect(h.reader.calls, 1, reason: 'a second request would stack up');
    expect(h.poller.view.inFlight, isTrue);
  });

  test('POLL-04 · a failing read backs off and then stops', () async {
    final h = _harness();
    h.poller.start('assessment-a');
    await _settle();

    for (var i = 0; i < 5; i++) {
      h.reader.fail(i);
      await _settle();
      if (i < 4) h.clock.fireLast();
      await _settle();
    }
    // 2 s, 4 s, 8 s, 16 s, 16 s.
    expect(h.clock.delays, [
      const Duration(seconds: 2),
      const Duration(seconds: 4),
      const Duration(seconds: 8),
      const Duration(seconds: 16),
      const Duration(seconds: 16),
    ]);

    // The sixth failure exceeds the ceiling and schedules nothing further.
    final before = h.clock.ticks.length;
    h.clock.fireLast(); // the last 16 s tick, which starts the sixth read
    await _settle();
    expect(h.reader.calls, 6);
    h.reader.fail(5);
    await _settle();
    expect(h.clock.ticks.length, before);
  });

  test('POLL-05 · a terminal state stops the loop', () async {
    final h = _harness();
    h.poller.start('assessment-a');
    await _settle();
    h.reader.answer(
      0,
      simulatedReading(
        purpose: simulatedPurpose(state: 'PERSISTED', attemptNo: 1, persisted: 6),
      ),
    );
    await _settle();

    expect(h.clock.ticks, isEmpty, reason: 'nothing can change without a new attempt');

    // BLOCKED is equally terminal for polling: nothing is in flight.
    final blocked = _harness();
    blocked.poller.start('assessment-a');
    await _settle();
    blocked.reader.answer(0, simulatedReading());
    await _settle();
    expect(blocked.clock.ticks, isEmpty);
  });

  test('POLL-06 · disposing cancels the tick and ignores the late answer', () async {
    var notifications = 0;
    final reader = _ScriptedReader();
    final clock = _FakeSchedule();
    final poller = ExecutionStatusPoller(
      read: reader.call,
      onChanged: (_) => notifications += 1,
      schedule: clock.schedule,
    );

    poller.start('assessment-a');
    await _settle();
    final afterStart = notifications;
    poller.dispose();
    reader.answer(0, simulatedReading(purpose: simulatedPurpose(state: 'PERSISTED')));
    await _settle();

    expect(notifications, afterStart, reason: 'a disposed poller must stay silent');
    expect(poller.view.reading, isNull);

    // And nothing was scheduled on the way out.
    expect(clock.ticks, isEmpty);
  });

  test('POLL-07 · a failed poll keeps the reading already on screen', () async {
    final h = _harness();
    h.poller.start('assessment-a');
    await _settle();
    h.reader.answer(
      0,
      simulatedReading(
        purpose: simulatedPurpose(state: 'RETURNED', attemptNo: 1, receiptOutcome: 'returned'),
      ),
    );
    await _settle();
    expect(h.poller.view.readState, RailReadState.loaded);
    final onScreen = h.poller.view.reading;

    h.clock.fireLast();
    await _settle();
    h.reader.fail(1);
    await _settle();

    // Stale data, not an unknown execution: the facts the server returned are
    // preserved and the card must not switch to "unavailable".
    expect(h.poller.view.reading, same(onScreen));
    expect(h.poller.view.readState, RailReadState.loaded);
    expect(h.poller.view.consecutiveFailures, 1);
  });

  test('POLL-08 · the first failed read is reported as a failed read', () async {
    final h = _harness();
    h.poller.start('assessment-a');
    await _settle();
    h.reader.fail(0);
    await _settle();

    expect(h.poller.view.reading, isNull);
    expect(h.poller.view.readState, RailReadState.failed);
  });

  test('STATE-15 · navigating away discards the previous assessment', () async {
    final h = _harness();
    h.poller.start('assessment-a');
    await _settle();
    h.poller.start('assessment-b');
    await _settle();

    // The new assessment is read without waiting for the old one to answer.
    expect(h.reader.calls, 2);
    expect(h.reader.requestedFor, ['assessment-a', 'assessment-b']);

    // A answers last; it is not evidence about B and must be dropped.
    h.reader.answer(
      1,
      simulatedReading(
        purpose: simulatedPurpose(state: 'PROCESSING', attemptNo: 1),
      ),
    );
    await _settle();
    h.reader.answer(
      0,
      simulatedReading(purpose: simulatedPurpose(state: 'PERSISTED')),
    );
    await _settle();

    expect(h.poller.view.reading!.forPurpose('BDJ')!.state, 'PROCESSING');
  });

  test('STATE-17 · concurrent responses cannot overwrite each other', () async {
    final h = _harness();
    h.poller.start('assessment-a');
    await _settle();
    h.poller.start('assessment-b');
    await _settle();

    // B resolves first and is applied.
    h.reader.answer(
      1,
      simulatedReading(
        purpose: simulatedPurpose(state: 'RETURNED', attemptNo: 2),
      ),
    );
    await _settle();
    expect(h.poller.view.reading!.forPurpose('BDJ')!.state, 'RETURNED');

    // A resolves afterwards; the stale response must be rejected.
    h.reader.answer(
      0,
      simulatedReading(purpose: simulatedPurpose(state: 'PERSISTED')),
    );
    await _settle();
    expect(h.poller.view.reading!.forPurpose('BDJ')!.state, 'RETURNED');
    expect(h.poller.view.readState, RailReadState.loaded);
  });

  // ==========================================================================
  // STATE-16 — presentation survives a rebuild
  // ==========================================================================

  testComponents('STATE-16 · More details stays open across a rebuild', (
    tester,
  ) async {
    Finder disclosure({required bool open}) => find.byElementPredicate(
      (element) =>
          element is DomElement &&
          (element.component.classes ?? '').split(' ').contains('aip__more') &&
          (element.component.attributes?.containsKey('open') ?? false) == open,
      description: 'the disclosure, ${open ? 'open' : 'closed'}',
    );

    tester.pumpComponent(
      AiExecutionProgressPanel(
        title: 'Business review status',
        execution: simulatedExecution(
          state: 'RETURNED',
          attemptNo: 1,
          attemptsReserved: 1,
          receiptOutcome: 'returned',
        ),
        detailFacts: const [
          (label: 'Execution state', value: 'RETURNED · RETURNED_NOT_PERSISTED'),
        ],
      ),
    );
    await tester.pump();
    expect(disclosure(open: false), findsOneComponent);

    await tester.click(find.tag('summary'));
    await tester.pump();
    expect(disclosure(open: true), findsOneComponent);

    // Expanding a milestone rebuilds the component from the same State, exactly
    // as an arriving status reading does.
    await tester.click(find.tag('button').first);
    await tester.pump();
    expect(disclosure(open: true), findsOneComponent);
  });
}
