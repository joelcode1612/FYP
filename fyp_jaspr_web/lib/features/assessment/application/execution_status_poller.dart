import 'dart:async';

import 'package:sitewise_jaspr_web/features/assessment/data/stage_four_five_api.dart';

// The constructor's parameters are named, and a named parameter cannot be an
// initializing formal for a private field (`this._read` is only legal for
// positional parameters). The initializer list is therefore the only spelling
// available, so the lint that asks for the impossible form is disabled here
// rather than worked around by renaming public parameters after private fields.
// ignore_for_file: prefer_initializing_formals

/// What the reader is allowed to conclude about the status *read*, as distinct
/// from the execution the read describes.
///
/// These were once one state: a null reading meant "not asked yet", "asked and
/// refused" and "the server said nothing" simultaneously, so a page that was
/// still loading printed "the ledger could not be read" — a claim it had no
/// evidence for (CP-PROG-05).
///
/// The name is kept because it is the published vocabulary of
/// `AiExecutionProgressPanel`, which re-exports this enum. It describes a rail's
/// read state, and the rail is the only consumer.
enum RailReadState {
  /// The status request has not answered yet. Nothing is claimed about the
  /// ledger, because nothing is known about it.
  pending,

  /// A reading arrived. The reading may still carry no entry for the purpose
  /// being displayed, which is reported as pending rather than as a failure.
  loaded,

  /// The read was attempted and did not produce a reading. This is the only
  /// state in which the card may say the ledger could not be read.
  failed,
}

/// One immutable view of [ExecutionStatusPoller].
///
/// A snapshot rather than a live getter so a listener cannot observe a reading
/// and a read-state that were set at different moments.
class ExecutionStatusView {
  const ExecutionStatusView({
    this.reading,
    this.readState = RailReadState.pending,
    this.inFlight = false,
    this.consecutiveFailures = 0,
  });

  /// The last reading that arrived, or null if none has.
  ///
  /// A failed poll does **not** clear this. Once a reading is on screen, a
  /// failed re-read is stale data, not an unknown execution, and replacing it
  /// with "unavailable" would destroy facts the server already returned.
  final AiExecutionReading? reading;

  final RailReadState readState;

  /// True while a read for the current assessment is outstanding.
  final bool inFlight;

  final int consecutiveFailures;
}

/// Schedules [callback] after [delay] and returns a canceller.
///
/// Injectable so the polling lifecycle can be exercised deterministically:
/// a test can record the delay of every scheduled tick, fire it by hand, and
/// assert the backoff sequence without waiting in real time.
typedef ScheduleFn = void Function() Function(
  Duration delay,
  void Function() callback,
);

/// Whether this purpose is still producing evidence.
///
/// Only these three states justify polling: `BLOCKED` means nothing is in
/// flight, and the terminal states cannot change without a new attempt, which a
/// poll must never cause.
bool purposeIsActive(AiExecutionPurpose purpose) =>
    purpose.state == 'PROCESSING' ||
    purpose.state == 'RETURNED' ||
    purpose.state == 'VALIDATING';

/// Reads one assessment's AI execution status and re-reads it while any purpose
/// is still producing evidence.
///
/// Why this is a class and not four fields on the page
/// --------------------------------------------------
/// The lifecycle has eight properties that must all hold at once — initial
/// read, two-second cadence, one request at a time, backoff after failure,
/// stop at a terminal state, cancellation on dispose, rejection of obsolete
/// responses, and preservation of the last good reading. Those were previously
/// spread across the Stage 3/4 page state, where they could only be tested by
/// mounting a 4 000-line component against a server. Extracting them makes each
/// property directly assertable (CP-P03 / CP-P05) without changing what the page
/// does.
///
/// It is a *read*
/// ---------------
/// The constructor takes a reader, not a service: it has no reference to the
/// BDJ or Direct-QG dispatch path, no way to reserve an attempt, and no way to
/// retry one. Polling this can never start an execution (CP-PROG-04). The
/// production caller passes a closure over the existing HTTP client; tests pass
/// a closure over a scripted list of readings. No fake service is introduced
/// into the application.
class ExecutionStatusPoller {
  ExecutionStatusPoller({
    required Future<AiExecutionReading?> Function(String assessmentId) read,
    required void Function(ExecutionStatusView view) onChanged,
    Duration interval = const Duration(seconds: 2),
    int maxConsecutiveFailures = 5,
    ScheduleFn? schedule,
  }) : _read = read,
       _onChanged = onChanged,
       _interval = interval,
       _maxConsecutiveFailures = maxConsecutiveFailures,
       _schedule = schedule ?? _timerSchedule;

  static void Function() _timerSchedule(
    Duration delay,
    void Function() callback,
  ) {
    final timer = Timer(delay, callback);
    return timer.cancel;
  }

  final Future<AiExecutionReading?> Function(String assessmentId) _read;
  final void Function(ExecutionStatusView view) _onChanged;
  final Duration _interval;
  final int _maxConsecutiveFailures;
  final ScheduleFn _schedule;

  String? _assessmentId;
  AiExecutionReading? _reading;
  RailReadState _readState = RailReadState.pending;
  int _failures = 0;

  /// Which assessment a read is currently outstanding for.
  ///
  /// Keyed by assessment rather than a bare boolean so that switching to a new
  /// assessment while a read is in flight does not deadlock: the old read is
  /// allowed to finish (its answer is discarded) while the new one starts.
  /// Two reads for the *same* assessment can never overlap.
  String? _inFlightFor;

  void Function()? _cancelTick;

  /// Incremented whenever the target changes. A response carrying an older
  /// generation is not evidence about the assessment now on screen.
  int _generation = 0;

  bool _disposed = false;

  ExecutionStatusView get view => ExecutionStatusView(
    reading: _reading,
    readState: _readState,
    inFlight: _inFlightFor != null,
    consecutiveFailures: _failures,
  );

  /// Begins (or continues) reading [assessmentId].
  ///
  /// A new assessment clears the previous reading rather than leaving it on
  /// screen under the new heading: a reading taken for another assessment is not
  /// evidence about this one.
  void start(String assessmentId) {
    if (_disposed) return;
    if (_assessmentId != assessmentId) {
      _generation += 1;
      _assessmentId = assessmentId;
      _reading = null;
      _readState = RailReadState.pending;
      _failures = 0;
      _cancelTick?.call();
      _cancelTick = null;
    }
    unawaited(_poll(assessmentId));
  }

  /// A manual re-read, exposed to the "status unavailable" state.
  ///
  /// Returns immediately when a read is already outstanding, so the button
  /// cannot stack requests.
  Future<void> refresh() async {
    final id = _assessmentId;
    if (_disposed || id == null) return;
    if (_inFlightFor == id) return;
    _cancelTick?.call();
    _cancelTick = null;
    _failures = 0;
    await _poll(id);
  }

  /// Stops polling and makes every outstanding response a no-op.
  ///
  /// Without the `_disposed` flag a late response would call `onChanged` after
  /// the widget is gone, which is a crash rather than a leak.
  void dispose() {
    _disposed = true;
    _cancelTick?.call();
    _cancelTick = null;
  }

  Future<void> _poll(String assessmentId) async {
    if (_disposed) return;
    if (_inFlightFor == assessmentId) return; // never overlap two reads
    _inFlightFor = assessmentId;
    final generation = _generation;
    _notify();

    AiExecutionReading? reading;
    var failed = false;
    try {
      reading = await _read(assessmentId);
    } catch (_) {
      // A transport failure is a failed *read*, never a failed execution.
      failed = true;
    } finally {
      if (_inFlightFor == assessmentId) _inFlightFor = null;
    }

    if (_disposed) return;
    // A response for an assessment we have since left is not evidence about the
    // current one. Discard it rather than letting it overwrite the rail.
    if (generation != _generation || _assessmentId != assessmentId) {
      _notify();
      return;
    }

    if (failed) {
      _failures += 1;
      // Only the first read can leave the card with nothing to show. Once a
      // reading is on screen, a failed poll is stale data, not an unknown
      // execution, and must not overwrite facts the server already returned.
      if (_reading == null) _readState = RailReadState.failed;
      _notify();
      if (_failures <= _maxConsecutiveFailures) _scheduleTick(assessmentId);
      return;
    }

    _failures = 0;
    _reading = reading;
    // The server answered. A reading with no entry for the displayed purpose is
    // a statement about the contract, not a failed read.
    _readState = RailReadState.loaded;
    _notify();

    if (reading != null && reading.purposes.any(purposeIsActive)) {
      _scheduleTick(assessmentId);
    } else {
      _cancelTick?.call();
      _cancelTick = null;
    }
  }

  void _scheduleTick(String assessmentId) {
    _cancelTick?.call();
    // Bounded exponential backoff after failures: 2 s, 4 s, 8 s, 16 s, 16 s.
    final factor = _failures == 0
        ? 1
        : 1 << (_failures - 1).clamp(0, 3);
    final delay = Duration(seconds: _interval.inSeconds * factor);
    _cancelTick = _schedule(delay, () {
      if (_disposed || _assessmentId != assessmentId) return;
      unawaited(_poll(assessmentId));
    });
  }

  void _notify() {
    if (_disposed) return;
    _onChanged(view);
  }
}
