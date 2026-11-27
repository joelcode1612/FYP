/// Transport for the single governed Direct-QG generation step.
///
/// The route this calls performs eligibility, authorization issuance and
/// generation as one attempt. The client therefore sends only the objective the
/// owner approved: it never sends an admission id, an authorization id or a
/// measurement id, because those are the server's conclusions rather than the
/// caller's assertions.
library;

import 'package:sitewise_jaspr_web/features/assessment/data/assessment_api.dart';
import 'package:sitewise_jaspr_web/features/authentication/data/auth_service.dart';

const String _base = '/api/v1/m2/assessments';

/// Refusal codes the panel branches on. Wording always comes from the server.
abstract final class QgGenerationCodes {
  /// Contract 2.1 persistence is additive and lives in migration
  /// `20261124_05_objective_authority`. Until a deployment applies it, this is
  /// the honest answer instead of a server error.
  static const schemaNotAdopted = 'QG_AUTHORITY_SCHEMA_NOT_ADOPTED';
  static const consentAbsent = 'AI_PROCESSING_QG_CONSENT_ABSENT';
  static const providerNotConfigured = 'PROVIDER_NOT_CONFIGURED';
  static const measurementNotFound = 'MEASUREMENT_NOT_FOUND';
  static const proposedFormatRequired = 'QG_PROPOSED_MEASUREMENT_FORMAT_REQUIRED';

  /// The one attempt this objective is allowed has already been taken. Unlike
  /// the codes above this is not a malfunction and not a missing permission: the
  /// attempt happened and consumed both the authorization and the grant, so the
  /// only lawful next step is a recovery the owner authorises explicitly.
  static const alreadySpent = 'QG_AUTHORIZATION_ALREADY_SPENT';
  static const authorizationConsumed = 'QG_AUTHORIZATION_CONSUMED';
  static const consentConsumed = 'QG_CONSENT_ALREADY_CONSUMED';

  /// True when the refusal means "this objective has used its one attempt".
  static bool isSpent(String? code) =>
      code == alreadySpent ||
      code == authorizationConsumed ||
      code == consentConsumed;
}

/// Whether a separately authorised recovery of one objective is possible.
///
/// Read-only: fetching this grants nothing and reserves nothing. It exists so the
/// interface can show the exact act it is about to ask the owner to authorise,
/// instead of offering a "try again" button that the server would refuse.
final class QgRecoveryState {
  final bool available;
  final String? priorAuthorizationId;
  final bool alreadyRequested;
  final bool consentGrantAvailable;

  /// The first unmet precondition, in the order dispatch would meet it.
  final String? blockedBy;

  /// The body to POST to the generate route, or null when nothing may be
  /// requested right now.
  final Map<String, dynamic>? request;

  const QgRecoveryState({
    required this.available,
    this.priorAuthorizationId,
    this.alreadyRequested = false,
    this.consentGrantAvailable = false,
    this.blockedBy,
    this.request,
  });

  /// The server could not describe a recovery for this objective.
  static const unavailable = QgRecoveryState(available: false);

  factory QgRecoveryState.fromJson(Map<String, dynamic> json) {
    final request = json['request'];
    return QgRecoveryState(
      available: json['recovery_available'] == true,
      priorAuthorizationId: json['prior_authorization_id'] as String?,
      alreadyRequested: json['already_requested'] == true,
      consentGrantAvailable: json['consent_grant_available'] == true,
      blockedBy: json['blocked_by'] as String?,
      request: request is Map<String, dynamic> ? request : null,
    );
  }
}

/// What one governed attempt produced.
final class QgGenerationResult {
  /// Null when the adapter abstained or held before persisting anything.
  final String? candidateId;
  final String outcome;
  final bool dispatched;
  final String? authorizationId;

  /// The refusal/hold reason the adapter itself reported, if any. Distinct from
  /// a transport failure: this is a governed outcome, not a broken request.
  final String? abstentionReason;

  const QgGenerationResult({
    required this.outcome,
    required this.dispatched,
    this.candidateId,
    this.authorizationId,
    this.abstentionReason,
  });

  factory QgGenerationResult.fromJson(Map<String, dynamic> json) =>
      QgGenerationResult(
        candidateId: json['candidate_id'] as String?,
        outcome: (json['outcome'] ?? 'UNKNOWN') as String,
        dispatched: json['dispatched'] == true,
        authorizationId: json['authorization_id'] as String?,
        abstentionReason: json['abstention_reason'] as String?,
      );
}

/// One objective's row inside a batch response.
final class QgBatchOutcome {
  final String proposalId;

  /// `COMPLETED` or `REFUSED`. There is no third state: an objective either
  /// produced its governed outcome or it was refused with a code.
  final String status;
  final String? code;
  final String? message;
  final String? checkId;

  /// True when the refusal means the one attempt was taken. A plain retry would
  /// be refused again, so the interface must not offer one.
  final bool attemptSpent;
  final String? candidateId;
  final String? outcome;
  final bool dispatched;

  const QgBatchOutcome({
    required this.proposalId,
    required this.status,
    required this.attemptSpent,
    required this.dispatched,
    this.code,
    this.message,
    this.checkId,
    this.candidateId,
    this.outcome,
  });

  bool get completed => status == 'COMPLETED';

  factory QgBatchOutcome.fromJson(Map<String, dynamic> json) => QgBatchOutcome(
    proposalId: (json['proposal_id'] ?? '') as String,
    status: (json['status'] ?? 'REFUSED') as String,
    attemptSpent: json['attempt_spent'] == true,
    dispatched: json['dispatched'] == true,
    code: json['code'] as String?,
    message: json['message'] as String?,
    checkId: json['check_id'] as String?,
    candidateId: json['candidate_id'] as String?,
    outcome: json['outcome'] as String?,
  );
}

/// What one owner action produced across every selected objective.
final class QgBatchResult {
  final String contractVersion;
  final List<QgBatchOutcome> results;
  final int requested;
  final int completed;
  final int refused;
  final int persisted;

  /// False by contract: the batch is a loop over per-objective attempts, never
  /// one merged prompt. Carried in the payload so the interface can state it
  /// rather than assume it.
  final bool combinedPrompt;

  const QgBatchResult({
    required this.contractVersion,
    required this.results,
    required this.requested,
    required this.completed,
    required this.refused,
    required this.persisted,
    required this.combinedPrompt,
  });

  QgBatchOutcome? forProposal(String proposalId) {
    for (final row in results) {
      if (row.proposalId == proposalId) return row;
    }
    return null;
  }

  factory QgBatchResult.fromJson(Map<String, dynamic> json) {
    final summary = json['summary'] is Map
        ? Map<String, dynamic>.from(json['summary'] as Map)
        : const <String, dynamic>{};
    final raw = json['results'];
    return QgBatchResult(
      contractVersion: (json['contract_version'] ?? '') as String,
      results: raw is List
          ? [
              for (final row in raw)
                if (row is Map) QgBatchOutcome.fromJson(
                  Map<String, dynamic>.from(row),
                ),
            ]
          : const <QgBatchOutcome>[],
      requested: (summary['requested'] as num?)?.toInt() ?? 0,
      completed: (summary['completed'] as num?)?.toInt() ?? 0,
      refused: (summary['refused'] as num?)?.toInt() ?? 0,
      persisted: (summary['persisted'] as num?)?.toInt() ?? 0,
      combinedPrompt: json['combined_prompt'] == true,
    );
  }
}

/// Transport port so the Stage 4 panel can be rendered against a recorded
/// response in a component test without reaching the network.
abstract interface class QgGenerationPort {
  Future<ApiResult<QgGenerationResult>> generateForObjective({
    required String assessmentId,
    required String confirmationId,
    required String contextId,
    required String proposalId,
    String responseFormat,
    String? recoveryOf,
  });

  /// One action, one governed attempt per selected objective.
  ///
  /// The list is the owner's selection. The server walks it in order and
  /// reports each objective separately, so a refusal on one does not remove
  /// another's result.
  Future<ApiResult<QgBatchResult>> generateForObjectives({
    required String assessmentId,
    required String confirmationId,
    required String contextId,
    required List<String> proposalIds,
    String responseFormat,
  });

  Future<ApiResult<QgRecoveryState>> readRecovery({
    required String assessmentId,
    required String contextId,
    required String proposalId,
  });
}

final class QgGenerationApi implements QgGenerationPort {
  const QgGenerationApi();

  @override
  Future<ApiResult<QgBatchResult>> generateForObjectives({
    required String assessmentId,
    required String confirmationId,
    required String contextId,
    required List<String> proposalIds,
    String responseFormat = 'MULTIPLE_CHOICE',
  }) async {
    final response = await WebAuth.requestDetailed(
      '$_base/${Uri.encodeComponent(assessmentId)}/qg-candidates/generate-batch',
      method: 'POST',
      body: {
        'confirmation_id': confirmationId,
        'context_id': contextId,
        'proposal_ids': proposalIds,
        'response_format': responseFormat,
      },
    );
    if (response['ok'] != true) {
      return ApiResult<QgBatchResult>.error(
        AssessmentFailure(
          status: response['status'] as int?,
          code: response['code'] as String?,
          message:
              response['message'] as String? ??
              'The generation request could not be completed.',
        ),
      );
    }
    final payload = response['body'];
    if (payload is! Map<String, dynamic>) {
      return ApiResult<QgBatchResult>.error(
        const AssessmentFailure(
          code: 'unexpected_response',
          message: 'The server returned a response this page cannot read.',
        ),
      );
    }
    return ApiResult<QgBatchResult>.success(QgBatchResult.fromJson(payload));
  }

  @override
  Future<ApiResult<QgRecoveryState>> readRecovery({
    required String assessmentId,
    required String contextId,
    required String proposalId,
  }) async {
    final query = Uri(
      queryParameters: {'proposal_id': proposalId, 'context_id': contextId},
    ).query;
    final response = await WebAuth.requestDetailed(
      '$_base/${Uri.encodeComponent(assessmentId)}/qg-candidates/recovery?$query',
    );
    if (response['ok'] != true) {
      return ApiResult<QgRecoveryState>.error(
        AssessmentFailure(
          status: response['status'] as int?,
          code: response['code'] as String?,
          message:
              response['message'] as String? ??
              'The recovery state could not be read.',
        ),
      );
    }
    final payload = response['body'];
    if (payload is! Map<String, dynamic>) {
      return ApiResult<QgRecoveryState>.error(
        const AssessmentFailure(
          code: 'unexpected_response',
          message: 'The server returned a response this page cannot read.',
        ),
      );
    }
    return ApiResult<QgRecoveryState>.success(
      QgRecoveryState.fromJson(payload),
    );
  }

  @override
  Future<ApiResult<QgGenerationResult>> generateForObjective({
    required String assessmentId,
    required String confirmationId,
    required String contextId,
    required String proposalId,
    String responseFormat = 'MULTIPLE_CHOICE',
    String? recoveryOf,
  }) async {
    final response = await WebAuth.requestDetailed(
      '$_base/${Uri.encodeComponent(assessmentId)}/qg-candidates/generate',
      method: 'POST',
      body: {
        'confirmation_id': confirmationId,
        'context_id': contextId,
        'proposal_id': proposalId,
        'response_format': responseFormat,
        // Present only for a recovery the owner has just authorised. The server
        // validates it against the spent row and refuses anything that does not
        // describe the same act, so this is a request to recover a named
        // attempt, not a retry switch. Omitted entirely when null, so an ordinary
        // generation request carries no recovery field at all.
        'recovery_of': ?recoveryOf,
      },
    );
    if (response['ok'] != true) {
      return ApiResult<QgGenerationResult>.error(
        AssessmentFailure(
          status: response['status'] as int?,
          code: response['code'] as String?,
          message:
              response['message'] as String? ??
              'The question-generation request could not be completed.',
        ),
      );
    }
    final payload = response['body'];
    if (payload is! Map<String, dynamic>) {
      return ApiResult<QgGenerationResult>.error(
        const AssessmentFailure(
          code: 'unexpected_response',
          message: 'The server returned a response this page cannot read.',
        ),
      );
    }
    return ApiResult<QgGenerationResult>.success(
      QgGenerationResult.fromJson(payload),
    );
  }
}
