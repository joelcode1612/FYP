/// Authenticated client for the governed BDJ objective-proposal endpoints.
///
/// Verified against Gate B/C evidence (`BDJ_GATEBC_HTTP_E2E_FRESH_20261122.json`):
///
/// * `POST /assessments/{id}/objective-proposals/evaluate` — governed run;
///   returns the persisted proposals plus the execution receipt.
/// * `GET  /assessments/{id}/objective-proposals` — persisted readback.
/// * `GET  /assessments/{id}/objective-proposals/{pid}` — single readback.
/// * `GET  /assessments/{id}/objective-proposals/{pid}/decision` — decision
///   plus the separately computed admission state.
/// * `POST /assessments/{id}/objective-proposals/{pid}/decision` — APPROVED or
///   REJECTED, append-only and idempotent for a repeated identical decision.
///
/// Every read requires `expected_revision` and `context_id` because the server
/// re-verifies that the M2 confirmation and the persisted business context are
/// still current. A stale pair is refused with 409 rather than served, so the
/// client cannot show proposals that no longer match the source.
///
/// Failures are returned as [ApiResult] values, matching the rest of the
/// assessment feature: the panel must distinguish "no proposals" from "the
/// source moved" from "the service is down", and Dart cannot read a status off
/// a thrown error.
library;

import 'package:sitewise_jaspr_web/features/assessment/data/assessment_api.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/bdj_objective_proposal.dart';
import 'package:sitewise_jaspr_web/features/authentication/data/auth_service.dart';

const String _base = '/api/v1/project1-workflow/assessments';

/// Refusal codes this client surfaces verbatim. The panel renders the server's
/// own sentence, so these are only used for branching, never for wording.
abstract final class BdjObjectiveCodes {
  static const sourceNotCurrent = 'BDJ_OBJECTIVE_SOURCE_NOT_CURRENT';
  static const contextNotCurrent = 'BDJ_OBJECTIVE_CONTEXT_NOT_CURRENT';
  static const contextNotFound = 'BDJ_OBJECTIVE_CONTEXT_NOT_FOUND';
  static const assessmentNotFound = 'BDJ_OBJECTIVE_ASSESSMENT_NOT_FOUND';
  static const proposalNotFound = 'BDJ_OBJECTIVE_PROPOSAL_NOT_FOUND';
  static const decisionNotFound = 'BDJ_OBJECTIVE_DECISION_NOT_FOUND';
  static const candidateRejected = 'BDJ_OBJECTIVE_CANDIDATE_REJECTED';
  static const executionHeld = 'BDJ_OBJECTIVE_EXECUTION_HELD';
  static const contractDisabled = 'BDJ_OBJECTIVE_CONTRACT_NOT_ENABLED';
}

/// The stale-source family: the M2 revision or the business context moved, so
/// the client must re-read rather than retry blindly.
bool isStaleSourceCode(String? code) =>
    code == BdjObjectiveCodes.sourceNotCurrent ||
    code == BdjObjectiveCodes.contextNotCurrent;

/// Transport port for the five governed objective-proposal operations.
///
/// This exists so the Stage 3 panel can be rendered against a recorded payload
/// in a component test. [BdjObjectiveProposalApi] is `final` and reaches the
/// network through the `WebAuth` static bridge, which only resolves in a web
/// build; the port lets a test substitute a fixed result without weakening the
/// production path. It adds no operations and changes no contract: every method
/// here is already implemented by [BdjObjectiveProposalApi].
abstract interface class BdjObjectiveProposalPort {
  Future<ApiResult<BdjObjectiveEvaluation>> evaluate({
    required String assessmentId,
    required int expectedRevision,
    required String contextId,
  });

  Future<ApiResult<BdjObjectiveProposalList>> list({
    required String assessmentId,
    required int expectedRevision,
    required String contextId,
  });

  Future<ApiResult<BdjProposalReadback>> read({
    required String assessmentId,
    required String proposalId,
    required int expectedRevision,
    required String contextId,
  });

  Future<ApiResult<BdjObjectiveDecision>> decide({
    required String assessmentId,
    required String proposalId,
    required int expectedRevision,
    required String contextId,
    required String decision,
  });

  Future<ApiResult<BdjObjectiveDecision>> readDecision({
    required String assessmentId,
    required String proposalId,
    required int expectedRevision,
    required String contextId,
  });
}

final class BdjObjectiveProposalApi implements BdjObjectiveProposalPort {
  const BdjObjectiveProposalApi();

  String _query(int expectedRevision, String contextId) =>
      '?expected_revision=$expectedRevision'
      '&context_id=${Uri.encodeQueryComponent(contextId)}';

  /// Runs the governed BDJ objective pass for the current confirmation.
  ///
  /// Repeat calls are safe: the append-only ledger refuses a second attempt on
  /// the same work identity and the server answers with the already-persisted
  /// proposals (`execution.reused == true`) instead of dispatching again.
  @override
  Future<ApiResult<BdjObjectiveEvaluation>> evaluate({
    required String assessmentId,
    required int expectedRevision,
    required String contextId,
  }) => _call(
    '$_base/${Uri.encodeComponent(assessmentId)}/objective-proposals/evaluate',
    method: 'POST',
    body: {'expected_revision': expectedRevision, 'context_id': contextId},
    parse: BdjObjectiveEvaluation.fromJson,
  );

  /// Persisted proposals for this assessment/context/revision.
  @override
  Future<ApiResult<BdjObjectiveProposalList>> list({
    required String assessmentId,
    required int expectedRevision,
    required String contextId,
  }) => _call(
    '$_base/${Uri.encodeComponent(assessmentId)}/objective-proposals'
    '${_query(expectedRevision, contextId)}',
    parse: BdjObjectiveProposalList.fromJson,
  );

  @override
  Future<ApiResult<BdjProposalReadback>> read({
    required String assessmentId,
    required String proposalId,
    required int expectedRevision,
    required String contextId,
  }) => _call(
    '$_base/${Uri.encodeComponent(assessmentId)}/objective-proposals/'
    '${Uri.encodeComponent(proposalId)}'
    '${_query(expectedRevision, contextId)}',
    parse: BdjProposalReadback.fromJson,
  );

  /// Records APPROVED or REJECTED. Repeating the same decision returns the
  /// existing row with `decisionCreated == false`; the opposite decision is
  /// refused by the server, which is why the panel disables the buttons once a
  /// decision exists.
  @override
  Future<ApiResult<BdjObjectiveDecision>> decide({
    required String assessmentId,
    required String proposalId,
    required int expectedRevision,
    required String contextId,
    required String decision,
    String? note,
  }) {
    assert(
      decision == 'APPROVED' || decision == 'REJECTED',
      'decision must be APPROVED or REJECTED',
    );
    return _call(
      '$_base/${Uri.encodeComponent(assessmentId)}/objective-proposals/'
      '${Uri.encodeComponent(proposalId)}/decision',
      method: 'POST',
      body: {
        'expected_revision': expectedRevision,
        'context_id': contextId,
        'decision': decision,
        if (note != null && note.isNotEmpty) 'note': note,
      },
      parse: BdjObjectiveDecision.fromJson,
    );
  }

  /// Decision plus admission. A 404 here is the normal state for a proposal the
  /// entrepreneur has not reviewed yet, not an error.
  @override
  Future<ApiResult<BdjObjectiveDecision>> readDecision({
    required String assessmentId,
    required String proposalId,
    required int expectedRevision,
    required String contextId,
  }) => _call(
    '$_base/${Uri.encodeComponent(assessmentId)}/objective-proposals/'
    '${Uri.encodeComponent(proposalId)}/decision'
    '${_query(expectedRevision, contextId)}',
    parse: BdjObjectiveDecision.fromJson,
  );

  static Future<ApiResult<T>> _call<T>(
    String path, {
    required T Function(Map<String, dynamic>) parse,
    String method = 'GET',
    Map<String, dynamic>? body,
  }) async {
    final response = await WebAuth.requestDetailed(
      path,
      method: method,
      body: body,
    );
    if (response['ok'] != true) {
      return ApiResult<T>.error(
        AssessmentFailure(
          status: response['status'] as int?,
          code: response['code'] as String?,
          message:
              response['message'] as String? ??
              'The objective-proposal service could not complete this request.',
        ),
      );
    }
    final payload = response['body'];
    if (payload is! Map<String, dynamic>) {
      return ApiResult<T>.error(
        const AssessmentFailure(
          code: 'unexpected_response',
          message: 'The server returned a response this page cannot read.',
        ),
      );
    }
    try {
      return ApiResult<T>.success(parse(payload));
    } on Object catch (error) {
      // A malformed proposal payload is reported, never rendered as if it were
      // a real proposal.
      return ApiResult<T>.error(
        AssessmentFailure(
          code: 'unexpected_response',
          message: 'The proposal response could not be read: $error',
        ),
      );
    }
  }
}
