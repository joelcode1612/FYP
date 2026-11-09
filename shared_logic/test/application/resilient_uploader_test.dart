import 'dart:async';

import 'package:test/test.dart';
import 'package:shared_logic/shared_logic.dart';

/// Regression tests for the shared upload lifecycle (Task B §3).
///
/// Deliberately written but NOT executed — the brief forbids running tests in
/// this task. They pin the policy so a future change cannot silently reintroduce
/// unbounded retries, duplicate submits or raw error leakage.
void main() {
  // Real (tiny) delays: the backoff timers in [ResilientUploader] are real
  // dart Timers; a 1 ms base keeps the suite fast without fake_async.
  ResilientUploader uploader() => ResilientUploader(
        maxAttempts: 3,
        baseDelay: const Duration(milliseconds: 1),
        maxDelay: const Duration(milliseconds: 2),
      );

  test('success on the first attempt publishes validating -> loading -> success',
      () async {
    final u = uploader();
    final statuses = <UploadStatus>[];
    u.addListener((s) => statuses.add(s.status));

    await u.submit(() async {});
    expect(u.state.isSuccess, isTrue);
    expect(statuses, containsAll([UploadStatus.validating, UploadStatus.loading, UploadStatus.success]));
    expect(u.state.attempt, 1);
  });

  test('a retryable failure is retried with a BOUNDED number of attempts',
      () async {
    final u = uploader();
    var calls = 0;
    await u.submit(() async {
      calls++;
      throw const UploadFailure('Network dropped.');
    });
    expect(calls, 3, reason: 'maxAttempts must bound the retry loop');
    expect(u.state.isFailed, isTrue);
    expect(u.state.statusLine, 'Image not uploaded yet. Retry');
  });

  test('a recovery mid-way succeeds without launching further attempts',
      () async {
    final u = uploader();
    var calls = 0;
    await u.submit(() async {
      calls++;
      if (calls < 2) throw const UploadFailure('Network dropped.');
    });
    expect(calls, 2);
    expect(u.state.isSuccess, isTrue);
  });

  test('a PERMANENT failure (or rejected validation) never reaches the task',
      () async {
    final u = uploader();
    var calls = 0;
    await u.submit(
      () async => calls++,
      validate: () async =>
          throw const PermanentUploadFailure('Format is not supported.'),
    );
    expect(calls, 0, reason: 'validation failure must not start a transfer');
    expect(u.state.isFailed, isTrue);
    expect(u.state.attempt, 0);
    expect(u.state.message, 'Format is not supported.');
  });

  test('double submit is deduplicated: one transfer, one shared future',
      () async {
    final u = uploader();
    var calls = 0;
    final gate = Completer<void>();
    final first = u.submit(() async {
      calls++;
      await gate.future;
    });
    final second = u.submit(() async => calls++);
    expect(identical(first, second), isTrue,
        reason: 'the second tap must await the first attempt');
    gate.complete();
    await Future.wait([first, second]);
    expect(calls, 1, reason: 'a repeat submit must never duplicate the upload');
  });

  test('cancel is cooperative: no further retry is scheduled and the state '
      'settles on cancelled', () async {
    final u = uploader();
    var calls = 0;
    final attempt = u.submit(() async {
      calls++;
      throw const UploadFailure('Network dropped.');
    });
    u.cancel();
    await attempt;
    expect(calls, lessThan(3), reason: 'cancellation must stop the retry loop');
    expect(u.state.isCancelled, isTrue);
  });

  test('cancel before submit is a no-op (nothing to cancel)', () {
    final u = uploader();
    u.cancel();
    expect(u.state.isCancelled, isFalse);
    expect(u.state.status, UploadStatus.initial);
  });

  test('listener messages are the caller-supplied SAFE sentences — no raw '
      'exception text is published', () async {
    final u = uploader();
    final messages = <String?>[];
    u.addListener((s) => messages.add(s.message));
    await u.submit(() async =>
        throw Exception('SocketException: raw host 10.0.2.2:8000 (internal)'));
    for (final m in messages) {
      if (m == null) continue;
      expect(m.contains('SocketException'), isFalse,
          reason: 'raw transport details must never reach the UI state');
      expect(m.contains('10.0.2.2'), isFalse);
    }
    expect(u.state.statusLine, 'Image not uploaded yet. Retry');
  });

  test('dispose settles an in-flight attempt as cancelled and stops publishing',
      () async {
    final u = uploader();
    final publications = <UploadTaskState>[];
    u.addListener(publications.add);
    final gate = Completer<void>();
    final attempt = u.submit(() => gate.future);
    u.dispose();
    gate.complete();
    await attempt;
    expect(u.state.isCancelled, isTrue);
    final after = publications.length;
    expect(
      () => u.submit(() async {}),
      throwsStateError,
      reason: 'a disposed uploader must refuse new work',
    );
    expect(publications.length, after,
        reason: 'no state may be published after dispose');
  });
}
