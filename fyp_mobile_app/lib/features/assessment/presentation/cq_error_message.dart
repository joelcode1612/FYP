import 'package:flutter/foundation.dart';
import 'package:shared_logic/shared_logic.dart';

/// The single place that turns a failure into respondent-safe text.
///
/// Screens and view models must never render [AppFailure.message]. That string
/// is whatever the server, the HTTP client or the JSON decoder produced — it can
/// carry SQL, host names, tokens, file paths or stack fragments. Only two things
/// are allowed to influence the copy:
///
///  * [AppFailure.backendCode], a stable enum-like token chosen by the API, and
///  * the failure *class*, which tells us whether it was transport or auth.
///
/// Anything else falls back to [fallback]. The technical detail still reaches
/// [logCqFailure], which writes to the debug console only.
const _byBackendCode = <String, String>{
  // Availability.
  'CQ_RUNTIME_DISABLED':
      'Questionnaires are not available right now. Please try again later.',
  'PRODUCTION_FIELDING_HOLD':
      'Questionnaires are not open yet. They will appear here once they have '
          'been approved.',
  // Session identity and lifecycle.
  'CQ_CAMPAIGN_NOT_FOUND': 'This questionnaire is no longer available.',
  'CQ_SESSION_NOT_FOUND': 'This questionnaire is no longer available.',
  'CQ_SESSION_CLOSED': 'This questionnaire has already been completed.',
  'CQ_SESSION_INCOMPLETE':
      'Some questions still need an answer before this can be submitted.',
  'CQ_SESSION_PAUSED': 'This questionnaire is paused. Open it again to continue.',
  'CQ_SESSION_ALREADY_PINNED_TO_LOCALE':
      'This questionnaire was started in a different language. Open it again '
          'to continue.',
  'CQ_LIFECYCLE_ACTION_INVALID':
      'That action is not available for this questionnaire.',
  'CQ_LIFECYCLE_ALREADY_APPLIED': 'That has already been applied.',
  // Consent and question sequencing.
  'CQ_CONSENT_REQUIRED':
      'Please review and accept the consent statement before continuing.',
  'CQ_CURRENT_PRESENTATION_REQUIRED':
      'Open the current question before answering.',
  'CQ_QUESTION_NOT_APPLICABLE': 'That question is not part of this questionnaire.',
  'CQ_STIMULUS_NOT_APPLICABLE':
      'That material is not part of this questionnaire.',
  // Staleness and idempotency. These are safe to describe: nothing was lost.
  'CQ_STALE_MANIFEST':
      'This questionnaire has been updated. Open it again to continue.',
  'CQ_STALE_REVISION':
      'Your answers were updated somewhere else. Open it again to continue.',
  'CQ_ROUTING_SNAPSHOT_CHANGED':
      'This questionnaire changed while you were answering. Open it again to '
          'continue.',
  'CQ_QUALIFICATION_SOURCE_CHANGED':
      'This questionnaire changed while you were answering. Open it again to '
          'continue.',
  'CQ_IDEMPOTENCY_CONFLICT':
      'That request had already been sent. Nothing was duplicated.',
  // Consent and participation.
  'CQ_CONSENT_VERSION_INVALID':
      'The consent wording has changed. Reload and review it again.',
  'CQ_USE_WITHDRAWAL_ENDPOINT':
      'To stop taking part, use the withdraw option.',
  'CQ_LOCALE_NOT_AUTHORIZED':
      'This language is not available for this questionnaire.',
  // Integrity. Never explain the mechanism to a respondent.
  'CQ_RECEIPT_INTEGRITY_INVALID':
      'This submission could not be verified. Please contact support.',
  'CQ_RECEIPT_ROUTING_MISMATCH':
      'This submission could not be verified. Please contact support.',
};

/// Respondent-safe text for [failure], or [fallback] when nothing is known.
String cqErrorMessage(AppFailure failure, {required String fallback}) {
  final mapped = _byBackendCode[failure.backendCode];
  if (mapped != null) return mapped;
  // `userMessage` is defined per failure class and is already free of SDK, HTTP
  // and stack detail, so it is safe for the classes we know.
  if (failure is UnauthorizedFailure) return failure.userMessage;
  if (failure is NetworkFailure) return failure.userMessage;
  if (failure is ThrottledFailure) {
    return 'The service is busy. Try again later; no automatic retry was made.';
  }
  return fallback;
}

/// Same mapping for a parse failure. A [FormatException] carries decoder text
/// such as "Unexpected character at offset 812", which must never be shown, so
/// this deliberately ignores the exception body.
String cqParseErrorMessage({required String fallback}) => fallback;

/// Backend codes that mean "this answer was rejected", not "the service broke".
///
/// `CustomerQuestionnaireService.answer` refuses with HTTP 422 and one of these
/// codes (`reason or 'CQ_ANSWER_REQUIRED'`). Because the client already knows
/// which slot it just submitted, a rejection can name the question even though
/// the error body carries no slot identifier.
const _answerRejectionCodes = <String>{
  'E_UNKNOWN_CODE',
  'E_DUPLICATE_CODE',
  'E_EXCLUSIVE_CODE_CONFLICT',
  'E_MAX_SELECTIONS',
  'E_MIXED_RESPONSE_STATES',
  'CQ_ANSWER_REQUIRED',
};

/// True when the failure is a refused answer rather than a transport or
/// authorization problem, so the caller may attach question context.
bool cqIsAnswerRejection(AppFailure failure) =>
    _answerRejectionCodes.contains(failure.backendCode);

/// Respondent-safe text that names the question needing attention.
///
/// `slotId` is the slot the client submitted (`Q04`, or `Q10:SYN-F1` for a
/// feature slot). Falls back to [fallback] when the slot cannot be read, so an
/// unexpected identifier never produces a half-built sentence.
String cqAnswerRejectionMessage(String slotId, {required String fallback}) {
  final match = RegExp(r'^Q(\d{1,2})(?::|$)').firstMatch(slotId);
  if (match == null) return fallback;
  final number = int.tryParse(match.group(1)!);
  if (number == null || number < 1) return fallback;
  return 'Question $number needs attention. Check your selection and try again.';
}

/// Development-only diagnostics. Logs the code, the status and the class —
/// never headers, tokens, request bodies or the raw server message.
void logCqFailure(String where, Object error, {StackTrace? stack}) {
  if (!kDebugMode) return;
  if (error is AppFailure) {
    debugPrint(
      '[cq] $where failed: ${error.runtimeType} '
      'status=${error.statusCode ?? '-'} code=${error.backendCode ?? '-'} '
      'outcomeUnknown=${error.outcomeUnknown}',
    );
    return;
  }
  debugPrint('[cq] $where failed: ${error.runtimeType}');
}
