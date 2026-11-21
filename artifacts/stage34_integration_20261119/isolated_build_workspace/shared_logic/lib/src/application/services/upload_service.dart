import 'dart:async';
import 'dart:math';

/// Browser-safe upload lifecycle primitives shared by both apps.
///
/// The backend currently exposes **no image-upload endpoint** (photos live in
/// `fyp.property_photos` as URL rows and `/virtual-tours` accepts JSON
/// records only — verified 2026-11-09), so no repository here performs a file
/// transfer. These primitives define the lifecycle every future upload — and
/// the mobile capture pipeline — must follow, so the state machine cannot
/// diverge between platforms:
///
/// ```text
/// initial → validating → loading ⇄ retrying → success
///                     ↘            ↘ failed   ↘ cancelled
/// ```
///
/// Rules encoded once, here:
///  * retries are BOUNDED with exponential backoff + jitter (no loops);
///  * [PermanentUploadFailure] stops retries immediately — unsupported
///    formats, size limits and permission denials must surface to the user
///    as validation messages, not disappear into a retry storm;
///  * a submit while an attempt is already in flight is a no-op (double-tap
///    can never duplicate a non-idempotent upload);
///  * cancellation is cooperative and leaves the caller's draft untouched;
///  * failure messages are caller-supplied SAFE sentences — no exception
///    text, status code or provider detail ever reaches [UploadTaskState].

/// Why an upload could not proceed. `retryable` failures (network, timeout,
/// 5xx-equivalent) are retried; anything else must stop and ask the user.
class UploadFailure implements Exception {
  final bool retryable;
  final String safeMessage;

  const UploadFailure(this.safeMessage, {this.retryable = true});

  @override
  String toString() => safeMessage;
}

/// A failure that must NOT be retried: unsupported format, over the size
/// limit, permission denied. Throwing this from the upload task ends the
/// lifecycle in [UploadStatus.failed] on the first attempt.
class PermanentUploadFailure extends UploadFailure {
  const PermanentUploadFailure(super.safeMessage)
    : super(retryable: false);
}

/// The immutable state of one upload operation.
class UploadTaskState {
  final UploadStatus status;

  /// 1-based attempt number the [status] describes.
  final int attempt;

  /// Total attempts allowed before the state settles on failed.
  final int maxAttempts;

  /// 0..1 when the transport reports progress; null when unknown.
  final double? progress;

  /// User-safe sentence, non-null in `failed`/`cancelled`. Never contains
  /// raw exception text or transport details.
  final String? message;

  /// Monotonic token so a caller can detect that this state instance belongs
  /// to the attempt it started rather than an older, delayed publication.
  final int generation;

  const UploadTaskState({
    this.status = UploadStatus.initial,
    this.attempt = 0,
    this.maxAttempts = 3,
    this.progress,
    this.message,
    this.generation = 0,
  });

  bool get isInFlight =>
      status == UploadStatus.loading || status == UploadStatus.retrying;

  bool get isSuccess => status == UploadStatus.success;

  bool get isFailed => status == UploadStatus.failed;

  bool get isCancelled => status == UploadStatus.cancelled;

  /// "Image not uploaded yet. Retry"-style status for honest UI.
  String? get statusLine => switch (status) {
    UploadStatus.initial => null,
    UploadStatus.validating => 'Checking image…',
    UploadStatus.loading => 'Uploading…',
    UploadStatus.retrying =>
      'Connection interrupted — retrying (${attempt + 1} of $maxAttempts)…',
    UploadStatus.success => 'Uploaded',
    UploadStatus.failed => message ?? 'Image not uploaded yet.',
    UploadStatus.cancelled => message ?? 'Upload cancelled.',
  };

  UploadTaskState copyWith({
    UploadStatus? status,
    int? attempt,
    double? progress,
    bool clearProgress = false,
    String? message,
    bool clearMessage = false,
    int? generation,
  }) => UploadTaskState(
    status: status ?? this.status,
    attempt: attempt ?? this.attempt,
    maxAttempts: maxAttempts,
    progress: clearProgress ? null : (progress ?? this.progress),
    message: clearMessage ? null : (message ?? this.message),
    generation: generation ?? this.generation,
  );
}

enum UploadStatus { initial, validating, loading, retrying, success, failed, cancelled }

/// Runs one upload operation with the bounded-recovery policy above.
///
/// Framework-free (pure Dart): the platform supplies the actual transfer as
/// the [task] closure and reports progress through [onProgress]. Listeners
/// receive every [UploadTaskState] transition synchronously.
class ResilientUploader {
  ResilientUploader({
    this.maxAttempts = 3,
    this.baseDelay = const Duration(milliseconds: 600),
    this.maxDelay = const Duration(milliseconds: 2400),
    Random? jitter,
  }) : _random = jitter ?? Random();

  final int maxAttempts;
  final Duration baseDelay;
  final Duration maxDelay;
  final Random _random;

  UploadTaskState _state = const UploadTaskState(maxAttempts: 3);
  final List<void Function(UploadTaskState next)> _listeners = [];
  Completer<void>? _inFlight;
  bool _cancelRequested = false;
  int _generation = 0;
  Timer? _backoffTimer;
  bool _disposed = false;

  UploadTaskState get state => _state;

  bool get isBusy => _inFlight != null;

  void addListener(void Function(UploadTaskState next) listener) {
    assert(!_disposed, 'Listener added to a disposed $runtimeType');
    _listeners.add(listener);
  }

  void removeListener(void Function(UploadTaskState next) listener) =>
      _listeners.remove(listener);

  /// Starts [task] unless one is already running — the double-submit guard.
  /// Returns the same in-flight attempt instead of launching a duplicate.
  ///
  /// [validate] runs before any transfer; throwing [PermanentUploadFailure]
  /// there lands in `failed` on attempt 0 with no network touched.
  Future<void> submit(
    Future<void> Function() task, {
    Future<void> Function()? validate,
    void Function(double progress)? onProgress,
  }) {
    if (_disposed) throw StateError('$runtimeType is disposed');
    final existing = _inFlight;
    if (existing != null) return existing.future;
    _cancelRequested = false;
    final completer = Completer<void>();
    _inFlight = completer;
    _generation++;
    _run(task, validate, onProgress, _generation)
        .whenComplete(() {
          if (identical(_inFlight, completer)) _inFlight = null;
          if (!completer.isCompleted) completer.complete();
        });
    return completer.future;
  }

  /// Cooperative cancellation: the CURRENT attempt finishes (transports
  /// cannot always be aborted mid-flight), no retry is scheduled, and the
  /// state settles on cancelled. The caller's draft is untouched by design.
  void cancel() {
    if (!isBusy) return;
    _cancelRequested = true;
    _backoffTimer?.cancel();
    _publish(
      UploadTaskState(
        status: UploadStatus.cancelled,
        message: 'Upload cancelled.',
        generation: _generation,
      ),
    );
  }

  Future<void> _run(
    Future<void> Function() task,
    Future<void> Function()? validate,
    void Function(double progress)? onProgress,
    int generation,
  ) async {
    if (_cancelled(generation)) return;
    _publish(
      UploadTaskState(
        status: UploadStatus.validating,
        attempt: 0,
        maxAttempts: maxAttempts,
        generation: generation,
      ),
    );
    if (validate != null) {
      try {
        await validate();
      } on PermanentUploadFailure catch (failure) {
        _settleFailed(failure.safeMessage, 0, generation);
        return;
      } on UploadFailure catch (failure) {
        _settleFailed(failure.safeMessage, 0, generation);
        return;
      }
      if (_cancelled(generation)) return;
    }

    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      _publish(
        UploadTaskState(
          status: attempt == 1 ? UploadStatus.loading : UploadStatus.retrying,
          attempt: attempt,
          maxAttempts: maxAttempts,
          generation: generation,
        ),
      );
      try {
        if (onProgress != null) {
          _progressSink = onProgress;
        }
        await task();
        if (_cancelled(generation)) return;
        _publish(
          UploadTaskState(
            status: UploadStatus.success,
            attempt: attempt,
            maxAttempts: maxAttempts,
            generation: generation,
          ),
        );
        return;
      } on PermanentUploadFailure catch (failure) {
        _settleFailed(failure.safeMessage, attempt, generation);
        return;
      } on Object {
        // Recoveryable transport/server failure: bounded backoff, then retry.
        if (_cancelled(generation)) return;
        if (attempt >= maxAttempts) {
          _settleFailed('Image not uploaded yet. Retry', attempt, generation);
          return;
        }
        _publish(
          UploadTaskState(
            status: UploadStatus.retrying,
            attempt: attempt,
            maxAttempts: maxAttempts,
            generation: generation,
          ),
        );
        await _backoff(attempt, generation);
        if (_cancelled(generation)) return;
      } finally {
        _progressSink = null;
      }
    }
    _settleFailed('Image not uploaded yet. Retry', maxAttempts, generation);
  }

  void Function(double progress)? _progressSink;

  /// Progress hook the running task calls; ignored after settle/cancel.
  void reportProgress(double value) {
    final sink = _progressSink;
    if (sink == null || _disposed) return;
    sink(value.clamp(0, 1).toDouble());
  }

  Future<void> _backoff(int attemptAfterFailure, int generation) {
    final exponential =
        baseDelay * (1 << (attemptAfterFailure - 1).clamp(0, 2));
    final delay = exponential < maxDelay
        ? exponential * (0.85 + 0.30 * _random.nextDouble())
        : maxDelay;
    final completer = Completer<void>();
    _backoffTimer = Timer(delay, () {
      if (!completer.isCompleted) completer.complete();
    });
    return completer.future;
  }

  bool _cancelled(int generation) =>
      _disposed || _cancelRequested || generation != _generation;

  void _settleFailed(String message, int attempt, int generation) {
    if (_cancelRequested || _disposed || generation != _generation) return;
    _publish(
      UploadTaskState(
        status: UploadStatus.failed,
        attempt: attempt,
        maxAttempts: maxAttempts,
        message: message,
        generation: generation,
      ),
    );
  }

  void _publish(UploadTaskState next) {
    if (_disposed) return;
    _state = next;
    for (final listener in List.of(_listeners)) {
      listener(next);
    }
  }

  /// Terminal cleanup: pending backoff timers die, listeners clear, and any
  /// in-flight attempt settles as cancelled rather than publishing after
  /// disposal (the stale-publication guard).
  void dispose() {
    _disposed = true;
    _backoffTimer?.cancel();
    _listeners.clear();
    _progressSink = null;
    final inFlight = _inFlight;
    _state = UploadTaskState(
      status: UploadStatus.cancelled,
      message: 'Upload cancelled.',
      generation: _generation,
    );
    inFlight?.complete();
    _inFlight = null;
  }
}
