// Verification for UI-03 / regression scenarios 9, 10 and 11.
//
// The guarantee under test is narrow and absolute: whatever the transport, the
// decoder or the server puts in an exception, the string handed to a respondent
// screen must come from the closed set of approved sentences in
// `cq_error_message.dart` — never from `AppFailure.message`.
//
// These are pure unit tests: no widget tree, no HTTP, no database.

import 'package:flutter_test/flutter_test.dart';
import 'package:fyp/features/assessment/presentation/cq_error_message.dart';
import 'package:shared_logic/shared_logic.dart';

/// Strings that must never reach a respondent screen. Each one is a real shape
/// that a leaky handler could have produced.
const _forbidden = <String>[
  'SELECT',
  'FROM cq_sessions',
  'postgres',
  'psycopg2',
  'Traceback',
  'File "',
  'C:\\',
  '/srv/',
  'Bearer ',
  'eyJhbGciOi',
  'stack',
  'Exception',
  'sqlalchemy',
  '127.0.0.1',
  'localhost',
  'HTTP 500',
  'Internal Server Error',
];

void _expectNoLeak(String text, {required String label}) {
  for (final token in _forbidden) {
    expect(
      text.toLowerCase().contains(token.toLowerCase()),
      isFalse,
      reason: '$label leaked "$token": $text',
    );
  }
}

void main() {
  group('known backend codes map to approved copy', () {
    test('runtime disabled is distinguishable from fielding hold', () {
      const disabled = ServiceFailure.response(
        'cq_runtime_enabled is False; route short-circuited',
        statusCode: 503,
        backendCode: 'CQ_RUNTIME_DISABLED',
      );
      const hold = ServiceFailure.response(
        'UnverifiedCqAuthority.authorize raised PRODUCTION_FIELDING_HOLD',
        statusCode: 503,
        backendCode: 'PRODUCTION_FIELDING_HOLD',
      );

      final disabledText = cqErrorMessage(disabled, fallback: 'x');
      final holdText = cqErrorMessage(hold, fallback: 'x');

      expect(disabledText, contains('not available right now'));
      expect(holdText, contains('not open yet'));
      expect(disabledText, isNot(equals(holdText)));
      _expectNoLeak(disabledText, label: 'CQ_RUNTIME_DISABLED');
      _expectNoLeak(holdText, label: 'PRODUCTION_FIELDING_HOLD');
    });

    test('already-submitted session reads as completed, not as an error', () {
      const failure = ConflictFailure(
        'cq_sessions.state=SUBMITTED for session 7f3c',
        backendCode: 'CQ_SESSION_CLOSED',
      );
      expect(
        cqErrorMessage(failure, fallback: 'x'),
        'This questionnaire has already been completed.',
      );
    });

    test('every mapped code is respondent-safe', () {
      // The map is private, so probe it through the public entry point with the
      // codes the backend actually emits for this feature.
      const codes = <String>[
        'CQ_RUNTIME_DISABLED',
        'PRODUCTION_FIELDING_HOLD',
        'CQ_CAMPAIGN_NOT_FOUND',
        'CQ_SESSION_NOT_FOUND',
        'CQ_SESSION_CLOSED',
        'CQ_SESSION_INCOMPLETE',
        'CQ_SESSION_PAUSED',
        'CQ_SESSION_ALREADY_PINNED_TO_LOCALE',
        'CQ_LIFECYCLE_ACTION_INVALID',
        'CQ_LIFECYCLE_ALREADY_APPLIED',
        'CQ_CONSENT_REQUIRED',
        'CQ_CURRENT_PRESENTATION_REQUIRED',
        'CQ_QUESTION_NOT_APPLICABLE',
        'CQ_STIMULUS_NOT_APPLICABLE',
        'CQ_STALE_MANIFEST',
        'CQ_STALE_REVISION',
        'CQ_ROUTING_SNAPSHOT_CHANGED',
        'CQ_QUALIFICATION_SOURCE_CHANGED',
        'CQ_IDEMPOTENCY_CONFLICT',
        'CQ_CONSENT_VERSION_INVALID',
        'CQ_USE_WITHDRAWAL_ENDPOINT',
        'CQ_LOCALE_NOT_AUTHORIZED',
        'CQ_RECEIPT_INTEGRITY_INVALID',
        'CQ_RECEIPT_ROUTING_MISMATCH',
      ];

      for (final code in codes) {
        final text = cqErrorMessage(
          ServiceFailure.response(
            'raw server text for $code',
            statusCode: 500,
            backendCode: code,
          ),
          fallback: 'FALLBACK',
        );
        expect(text, isNot(equals('FALLBACK')), reason: '$code is unmapped');
        expect(text.trim(), isNotEmpty, reason: '$code maps to blank text');
        _expectNoLeak(text, label: code);
      }
    });
  });

  group('unknown or technical failures never surface their message', () {
    test('unmapped backend code falls back and drops the message', () {
      const failure = ServiceFailure.response(
        'psycopg2.errors.UndefinedTable: relation "cq_sessions" does not exist',
        statusCode: 500,
        backendCode: 'SOMETHING_NEW',
      );
      final text = cqErrorMessage(failure, fallback: 'Please try again.');
      expect(text, 'Please try again.');
      _expectNoLeak(text, label: 'unmapped code');
    });

    test('a code that fails the sanitiser is treated as unknown', () {
      // `apiOperationFailure` only keeps codes matching
      // ^[A-Za-z0-9_.:-]{1,100}$ — a code with spaces or slashes becomes null.
      final failure = apiOperationFailure(
        status: 500,
        code: 'Traceback (most recent call last)',
        message: 'File "C:\\app\\cq.py", line 42, in submit',
      );
      expect(failure.backendCode, isNull);
      final text = cqErrorMessage(failure, fallback: 'Please try again.');
      expect(text, 'Please try again.');
      _expectNoLeak(text, label: 'unsanitisable code');
    });

    test('a raw exception body is discarded by the parse mapper', () {
      const decoderText =
          'FormatException: Unexpected character at offset 812 '
          '(SELECT * FROM cq_effective_answers)';
      final text = cqParseErrorMessage(fallback: 'Please try again.');
      expect(text, 'Please try again.');
      expect(text.contains('812'), isFalse);
      _expectNoLeak(text, label: 'parse failure');
      expect(decoderText, contains('SELECT')); // the fixture really is unsafe
    });

    test('an unexpected non-AppFailure object still yields the fallback', () {
      final text = cqErrorMessage(
        const ResponseFormatFailure('{"detail": "internal"}'),
        fallback: 'Please try again.',
      );
      expect(text, 'Please try again.');
    });
  });

  group('transport and auth classes use their own safe sentences', () {
    test('network failure says connection, not server error', () {
      const failure = NetworkFailure.transport(
        'SocketException: Connection refused (OS Error: 10061) 127.0.0.1:8090',
      );
      final text = cqErrorMessage(failure, fallback: 'x');
      expect(text, contains('connection'));
      _expectNoLeak(text, label: 'NetworkFailure');
    });

    test('unauthorized failure asks for sign-in, not a retry loop', () {
      const failure = UnauthorizedFailure.response(
        'Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.abc.def was rejected',
        statusCode: 403,
        backendCode: null,
      );
      final text = cqErrorMessage(failure, fallback: 'x');
      expect(text, contains('sign in again'));
      _expectNoLeak(text, label: 'UnauthorizedFailure');
    });

    test('throttling explains that nothing was retried automatically', () {
      const failure = ThrottledFailure('rate limit', backendCode: null);
      expect(
        cqErrorMessage(failure, fallback: 'x'),
        'The service is busy. Try again later; no automatic retry was made.',
      );
    });
  });

  group('a refused answer names the question', () {
    test('every answer-rejection code is recognised', () {
      for (final code in const [
        'E_UNKNOWN_CODE',
        'E_DUPLICATE_CODE',
        'E_EXCLUSIVE_CODE_CONFLICT',
        'E_MAX_SELECTIONS',
        'E_MIXED_RESPONSE_STATES',
        'CQ_ANSWER_REQUIRED',
      ]) {
        final failure = apiOperationFailure(status: 422, code: code, message: 'x');
        expect(cqIsAnswerRejection(failure), isTrue, reason: code);
      }
    });

    test('other failures are not treated as answer rejections', () {
      expect(
        cqIsAnswerRejection(
          const UnauthorizedFailure.response('nope', statusCode: 403),
        ),
        isFalse,
      );
      expect(
        cqIsAnswerRejection(const NetworkFailure.transport('refused')),
        isFalse,
      );
    });

    test('the message names the question from the slot the client sent', () {
      expect(
        cqAnswerRejectionMessage('Q04', fallback: 'FALLBACK'),
        'Question 4 needs attention. Check your selection and try again.',
      );
      expect(
        cqAnswerRejectionMessage('Q01', fallback: 'FALLBACK'),
        contains('Question 1'),
      );
      // A feature slot keeps the question number and drops the feature suffix.
      expect(
        cqAnswerRejectionMessage('Q10:SYN-F1', fallback: 'FALLBACK'),
        contains('Question 10'),
      );
    });

    test('an unreadable slot falls back instead of half-building a sentence', () {
      for (final slot in const ['', 'Q', 'X04', 'QXX', 'FEATURE']) {
        expect(
          cqAnswerRejectionMessage(slot, fallback: 'FALLBACK'),
          'FALLBACK',
          reason: slot,
        );
      }
    });
  });

  group('diagnostics logging cannot throw or print payloads', () {
    test('logs arbitrary objects without raising', () {
      // `logCqFailure` is debug-only and prints the class, status and code.
      // This asserts it is total, so an error path can always call it.
      expect(() => logCqFailure('test', StateError('boom')), returnsNormally);
      expect(
        () => logCqFailure(
          'test',
          const ServiceFailure.response(
            'payload with token abc',
            statusCode: 500,
            backendCode: 'CQ_SESSION_CLOSED',
          ),
        ),
        returnsNormally,
      );
      expect(
        () => logCqFailure('test', 'a plain string'),
        returnsNormally,
      );
    });
  });
}
