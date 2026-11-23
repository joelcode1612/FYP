/// Typed model of the governed BDJ research-objective proposal contract
/// (`bdj-objective-proposal/1`).
///
/// Everything here is decoded from a persisted server response. Nothing is
/// defaulted into existence: a proposal that the server did not return is not
/// rendered, and a field the server omitted stays `null` rather than being
/// filled with a plausible value.
///
/// Two vocabularies matter and must not be conflated:
///
/// * [BdjRecommendationStatus] — how strongly the *source* supports the
///   proposal (`MOST_SUGGESTED` needs a confirmed information gap,
///   `SUGGESTED` is exploratory).
/// * [BdjReviewState] / [BdjAdmission] — what the *entrepreneur* decided, and
///   separately whether the objective may proceed downstream. An `APPROVED`
///   decision is never an admission: admission is computed server-side and
///   currently reports `HELD` with `M2_UNCERTAINTY_LINK_REQUIRED`.
library;

/// `MOST_SUGGESTED` | `SUGGESTED`. The server also uses these as the two
/// allowed `recommendation_status` values; any other string is preserved
/// verbatim so an unexpected value is visible rather than silently coerced.
enum BdjRecommendationStatus {
  mostSuggested,
  suggested,
  unrecognised;

  static BdjRecommendationStatus parse(String? raw) => switch (raw) {
    'MOST_SUGGESTED' => BdjRecommendationStatus.mostSuggested,
    'SUGGESTED' => BdjRecommendationStatus.suggested,
    _ => BdjRecommendationStatus.unrecognised,
  };

  String get wire => switch (this) {
    BdjRecommendationStatus.mostSuggested => 'MOST_SUGGESTED',
    BdjRecommendationStatus.suggested => 'SUGGESTED',
    BdjRecommendationStatus.unrecognised => 'UNRECOGNISED',
  };

  /// Only a source-confirmed gap may be shown as the stronger category.
  bool get isSourceConfirmed =>
      this == BdjRecommendationStatus.mostSuggested;
}

/// `PENDING` | `APPROVED` | `REJECTED`, as the proposal row records it.
enum BdjReviewState {
  pending,
  approved,
  rejected,
  unrecognised;

  /// The persisted vocabulary is the database check constraint
  /// ``ck_proposal_review_state``: ``CANDIDATE | APPROVED | REJECTED |
  /// REVIEWED | WITHDRAWN``. ``CANDIDATE`` is the undecided state and is what an
  /// unreviewed proposal actually carries, so it maps to [pending].
  ///
  /// ``PENDING`` is kept as an accepted synonym for forward compatibility, but
  /// it is not what the database stores. Before this mapping every unreviewed
  /// proposal rendered as "Review state unreadable", because the parser only
  /// knew ``PENDING``.
  static BdjReviewState parse(String? raw) => switch (raw) {
    'CANDIDATE' || 'PENDING' => BdjReviewState.pending,
    'APPROVED' => BdjReviewState.approved,
    'REJECTED' => BdjReviewState.rejected,
    _ => BdjReviewState.unrecognised,
  };

  bool get hasDecision =>
      this == BdjReviewState.approved || this == BdjReviewState.rejected;
}

/// `HELD` | `NOT_ADMISSIBLE`. Deliberately not a boolean: "held" means the
/// approval is valid but a separate requirement is unmet, which is not the
/// same as "not admissible".
enum BdjAdmissionState {
  held,
  notAdmissible,
  unrecognised;

  static BdjAdmissionState parse(String? raw) => switch (raw) {
    'HELD' => BdjAdmissionState.held,
    'NOT_ADMISSIBLE' => BdjAdmissionState.notAdmissible,
    _ => BdjAdmissionState.unrecognised,
  };

  /// Admission was never granted, whatever the review state says.
  bool get grantsDownstreamAuthority => false;
}

/// One citation from a proposal back to a confirmed M2 declaration.
///
/// `quote` is optional: the objective contract cites by identifier, and only
/// the legacy findings contract carries a verbatim quote.
final class BdjSourceRef {
  final String itemKey;
  final String answerRevisionId;
  final String itemVersionId;
  final String? quote;

  const BdjSourceRef({
    required this.itemKey,
    required this.answerRevisionId,
    required this.itemVersionId,
    this.quote,
  });

  factory BdjSourceRef.fromJson(Map<String, dynamic> json) => BdjSourceRef(
    itemKey: (json['item_key'] ?? '') as String,
    answerRevisionId: (json['answer_revision_id'] ?? '') as String,
    itemVersionId: (json['item_version_id'] ?? '') as String,
    quote: json['quote'] as String?,
  );

  /// Short form for dense UI: the item key plus the first block of the id.
  String get shortLabel =>
      '$itemKey · ${answerRevisionId.length > 8 ? answerRevisionId.substring(0, 8) : answerRevisionId}';
}

/// The model-authored content of one proposal, before any review state.
final class BdjRecommendation {
  final BdjRecommendationStatus status;
  final String problemType;

  /// Null for `SUGGESTED`. A non-null value here is the gap the source proves.
  final String? problem;

  final String researchObjective;
  final String reason;
  final List<BdjSourceRef> sourceRefs;

  const BdjRecommendation({
    required this.status,
    required this.problemType,
    required this.researchObjective,
    required this.reason,
    required this.sourceRefs,
    this.problem,
  });

  factory BdjRecommendation.fromJson(Map<String, dynamic> json) {
    final raw = json['source_refs'];
    return BdjRecommendation(
      status: BdjRecommendationStatus.parse(
        json['recommendation_status'] as String?,
      ),
      problemType: (json['problem_type'] ?? '') as String,
      problem: json['problem'] as String?,
      researchObjective: (json['research_objective'] ?? '') as String,
      reason: (json['reason'] ?? '') as String,
      sourceRefs: raw is List
          ? raw
                .whereType<Map>()
                .map((row) => BdjSourceRef.fromJson(row.cast<String, dynamic>()))
                .toList(growable: false)
          : const [],
    );
  }

  /// A `MOST_SUGGESTED` proposal is only trustworthy when it names the answer
  /// that establishes the gap. The server enforces this; the UI re-checks so a
  /// malformed payload can never be presented as source-confirmed.
  bool get isProperlySourced =>
      !status.isSourceConfirmed || (problem != null && sourceRefs.isNotEmpty);
}

/// One persisted proposal plus the entrepreneur's review state for it.
final class BdjObjectiveProposal {
  final String proposalId;
  final BdjRecommendation recommendation;
  final BdjReviewState reviewState;

  /// True when this evaluate call inserted the row, false when it already
  /// existed. Null when the response came from a list/read rather than an
  /// evaluation.
  final bool? created;

  const BdjObjectiveProposal({
    required this.proposalId,
    required this.recommendation,
    required this.reviewState,
    this.created,
  });

  factory BdjObjectiveProposal.fromJson(Map<String, dynamic> json) =>
      BdjObjectiveProposal(
        proposalId: (json['proposal_id'] ?? '') as String,
        recommendation: BdjRecommendation.fromJson(json),
        reviewState: BdjReviewState.parse(json['review_state'] as String?),
        created: json['created'] as bool?,
      );

  /// Rebuilds the same proposal with a new review state, so a decision can be
  /// reflected without refetching and without inventing any other field.
  BdjObjectiveProposal withReviewState(BdjReviewState state) =>
      BdjObjectiveProposal(
        proposalId: proposalId,
        recommendation: recommendation,
        reviewState: state,
        created: created,
      );
}

/// How the governed attempt was produced. `dispatched` is false for every
/// simulated run, which is the only mode currently authorised.
final class BdjExecution {
  final String executionMode;
  final String modelProvider;
  final bool dispatched;
  final String runId;
  final int? attemptNo;
  final String promptVersion;
  final String? promptSha256;
  final String? requestSha256;
  final String? outputSha256;
  final String? receiptOutcome;
  final bool reused;
  final String? contextPacketHash;

  const BdjExecution({
    required this.executionMode,
    required this.modelProvider,
    required this.dispatched,
    required this.runId,
    required this.promptVersion,
    required this.reused,
    this.attemptNo,
    this.promptSha256,
    this.requestSha256,
    this.outputSha256,
    this.receiptOutcome,
    this.contextPacketHash,
  });

  factory BdjExecution.fromJson(Map<String, dynamic> json) => BdjExecution(
    executionMode: (json['execution_mode'] ?? '') as String,
    modelProvider: (json['model_provider'] ?? '') as String,
    dispatched: json['dispatched'] == true,
    runId: (json['run_id'] ?? '') as String,
    attemptNo: (json['attempt_no'] as num?)?.toInt(),
    promptVersion: (json['prompt_version'] ?? '') as String,
    promptSha256: json['prompt_sha256'] as String?,
    requestSha256: json['request_sha256'] as String?,
    outputSha256: json['output_sha256'] as String?,
    receiptOutcome: json['receipt_outcome'] as String?,
    reused: json['reused'] == true,
    contextPacketHash: json['context_packet_hash'] as String?,
  );

  /// A simulated attempt never reaches a provider; the UI must say so rather
  /// than implying a live model produced the text.
  bool get isSimulated => executionMode.toUpperCase() == 'SIMULATED';
}

/// The envelope returned by `POST …/objective-proposals[/evaluate]`.
final class BdjObjectiveEvaluation {
  final String contractVersion;
  final String assessmentId;
  final String confirmationId;
  final int confirmationRevision;
  final String contextId;
  final String? contextPacketHash;
  final String sourceFingerprint;
  final String outcome;
  final int proposalCount;
  final List<BdjObjectiveProposal> proposals;
  final BdjExecution? execution;
  final String findingAuthority;
  final String statusContract;

  const BdjObjectiveEvaluation({
    required this.contractVersion,
    required this.assessmentId,
    required this.confirmationId,
    required this.confirmationRevision,
    required this.contextId,
    required this.sourceFingerprint,
    required this.outcome,
    required this.proposalCount,
    required this.proposals,
    required this.findingAuthority,
    required this.statusContract,
    this.contextPacketHash,
    this.execution,
  });

  factory BdjObjectiveEvaluation.fromJson(Map<String, dynamic> json) {
    final raw = json['proposals'];
    final execution = json['execution'];
    return BdjObjectiveEvaluation(
      contractVersion: (json['contract_version'] ?? '') as String,
      assessmentId: (json['assessment_id'] ?? '') as String,
      confirmationId: (json['confirmation_id'] ?? '') as String,
      confirmationRevision:
          (json['confirmation_revision'] as num?)?.toInt() ?? 0,
      contextId: (json['context_id'] ?? '') as String,
      contextPacketHash: json['context_packet_hash'] as String?,
      sourceFingerprint: (json['source_fingerprint'] ?? '') as String,
      outcome: (json['outcome'] ?? '') as String,
      proposalCount: (json['proposal_count'] as num?)?.toInt() ?? 0,
      proposals: raw is List
          ? raw
                .whereType<Map>()
                .map(
                  (row) => BdjObjectiveProposal.fromJson(
                    row.cast<String, dynamic>(),
                  ),
                )
                .toList(growable: false)
          : const [],
      execution: execution is Map
          ? BdjExecution.fromJson(execution.cast<String, dynamic>())
          : null,
      findingAuthority: (json['finding_authority'] ?? '') as String,
      statusContract: (json['status_contract'] ?? '') as String,
    );
  }

  /// Nothing was proposed. Distinct from a failure: the source may simply
  /// contain no information gap, which is a valid outcome.
  bool get isEmpty => proposals.isEmpty;
}

/// The list envelope from `GET …/objective-proposals`. It carries no execution
/// block because it reads persisted rows rather than performing a run.
final class BdjObjectiveProposalList {
  final String assessmentId;
  final String contextId;
  final int proposalCount;
  final List<BdjObjectiveProposal> proposals;

  const BdjObjectiveProposalList({
    required this.assessmentId,
    required this.contextId,
    required this.proposalCount,
    required this.proposals,
  });

  factory BdjObjectiveProposalList.fromJson(Map<String, dynamic> json) {
    final raw = json['proposals'];
    return BdjObjectiveProposalList(
      assessmentId: (json['assessment_id'] ?? '') as String,
      contextId: (json['context_id'] ?? '') as String,
      proposalCount: (json['proposal_count'] as num?)?.toInt() ?? 0,
      proposals: raw is List
          ? raw
                .whereType<Map>()
                .map(
                  (row) => BdjObjectiveProposal.fromJson(
                    row.cast<String, dynamic>(),
                  ),
                )
                .toList(growable: false)
          : const [],
    );
  }
}

/// Single-proposal readback. Adds the stored validation status and the
/// execution mode that produced the row.
final class BdjProposalReadback {
  final String contractVersion;
  final String proposalId;
  final String assessmentId;
  final int confirmationRevision;
  final String contextId;
  final String? contextPacketHash;
  final String sourceFingerprint;
  final BdjRecommendation recommendation;
  final String executionMode;
  final String validationStatus;
  final BdjReviewState reviewState;

  /// Persisted provenance of the row being displayed. `null` when the server
  /// did not report it (an older payload), never guessed from the page context.
  final String? modelProvider;
  final String? modelRequested;
  final String? modelReturned;
  final String? promptVersion;

  const BdjProposalReadback({
    required this.contractVersion,
    required this.proposalId,
    required this.assessmentId,
    required this.confirmationRevision,
    required this.contextId,
    required this.sourceFingerprint,
    required this.recommendation,
    required this.executionMode,
    required this.validationStatus,
    required this.reviewState,
    this.contextPacketHash,
    this.modelProvider,
    this.modelRequested,
    this.modelReturned,
    this.promptVersion,
  });

  factory BdjProposalReadback.fromJson(Map<String, dynamic> json) {
    final recommendation = json['recommendation'];
    return BdjProposalReadback(
      contractVersion: (json['contract_version'] ?? '') as String,
      proposalId: (json['proposal_id'] ?? '') as String,
      assessmentId: (json['assessment_id'] ?? '') as String,
      confirmationRevision:
          (json['confirmation_revision'] as num?)?.toInt() ?? 0,
      contextId: (json['context_id'] ?? '') as String,
      contextPacketHash: json['context_packet_hash'] as String?,
      sourceFingerprint: (json['source_fingerprint'] ?? '') as String,
      recommendation: recommendation is Map
          ? BdjRecommendation.fromJson(
              recommendation.cast<String, dynamic>(),
            )
          : BdjRecommendation.fromJson(const {}),
      executionMode: (json['execution_mode'] ?? '') as String,
      validationStatus: (json['validation_status'] ?? '') as String,
      reviewState: BdjReviewState.parse(json['review_state'] as String?),
      modelProvider: _executionText(json, 'model_provider'),
      modelRequested: _executionText(json, 'model_requested'),
      modelReturned: _executionText(json, 'model_returned'),
      promptVersion: _executionText(json, 'prompt_version'),
    );
  }

  /// Reads one provenance field from the additive `execution` block, falling
  /// back to the top level so a payload without the block still parses.
  static String? _executionText(Map<String, dynamic> json, String key) {
    final block = json['execution'];
    if (block is Map) {
      final value = block[key];
      if (value is String && value.isNotEmpty) return value;
    }
    final top = json[key];
    return top is String && top.isNotEmpty ? top : null;
  }
}

/// Approval and admission, kept as two separate facts.
///
/// `admissionState` is `HELD` while the approved objective has no confirmed
/// uncertainty link, and `NOT_ADMISSIBLE` when the proposal was not approved.
/// In both cases every downstream authority flag is false.
final class BdjAdmission {
  final BdjAdmissionState state;
  final String? reason;
  final String? pendingRequirement;
  final String? uncertaintyLink;
  final bool qjExecution;
  final bool qgExecution;
  final bool fieldingAuthorized;

  const BdjAdmission({
    required this.state,
    required this.qjExecution,
    required this.qgExecution,
    required this.fieldingAuthorized,
    this.reason,
    this.pendingRequirement,
    this.uncertaintyLink,
  });

  factory BdjAdmission.fromJson(Map<String, dynamic> json) => BdjAdmission(
    state: BdjAdmissionState.parse(json['admission_state'] as String?),
    reason: json['admission_reason'] as String?,
    pendingRequirement: json['pending_requirement'] as String?,
    uncertaintyLink: json['uncertainty_link'] as String?,
    qjExecution: json['qj_execution'] == true,
    qgExecution: json['qg_execution'] == true,
    fieldingAuthorized: json['fielding_authorized'] == true,
  );

  /// The one sentence a reviewer must see next to any APPROVED badge.
  String get summary => switch (state) {
    BdjAdmissionState.held =>
      'Approved by you, but not admitted for question generation yet'
          '${reason == null ? '' : ' ($reason)'}.',
    BdjAdmissionState.notAdmissible =>
      'Not admissible${reason == null ? '' : ' ($reason)'}.',
    BdjAdmissionState.unrecognised =>
      'Admission state could not be read from the server.',
  };
}

/// The envelope returned by `POST …/{proposal_id}/decision` and by its GET.
final class BdjObjectiveDecision {
  final String contractVersion;
  final String proposalId;
  final String assessmentId;
  final int confirmationRevision;
  final String contextId;
  final String sourceFingerprint;

  /// `APPROVED` | `REJECTED` exactly as stored.
  final String decision;

  final String decisionId;
  final String? decidedAt;
  final String? note;

  /// True when this call inserted the decision, false when the same decision
  /// already existed. Null for a read.
  final bool? decisionCreated;

  final BdjReviewState reviewState;
  final BdjAdmission admission;

  const BdjObjectiveDecision({
    required this.contractVersion,
    required this.proposalId,
    required this.assessmentId,
    required this.confirmationRevision,
    required this.contextId,
    required this.sourceFingerprint,
    required this.decision,
    required this.decisionId,
    required this.reviewState,
    required this.admission,
    this.decidedAt,
    this.note,
    this.decisionCreated,
  });

  factory BdjObjectiveDecision.fromJson(Map<String, dynamic> json) {
    final admission = json['admission'];
    return BdjObjectiveDecision(
      contractVersion: (json['contract_version'] ?? '') as String,
      proposalId: (json['proposal_id'] ?? '') as String,
      assessmentId: (json['assessment_id'] ?? '') as String,
      confirmationRevision:
          (json['confirmation_revision'] as num?)?.toInt() ?? 0,
      contextId: (json['context_id'] ?? '') as String,
      sourceFingerprint: (json['source_fingerprint'] ?? '') as String,
      decision: (json['decision'] ?? '') as String,
      decisionId: (json['decision_id'] ?? '') as String,
      decidedAt: json['decided_at'] as String?,
      note: json['note'] as String?,
      decisionCreated: json['decision_created'] as bool?,
      reviewState: BdjReviewState.parse(json['review_state'] as String?),
      admission: admission is Map
          ? BdjAdmission.fromJson(admission.cast<String, dynamic>())
          : const BdjAdmission(
              state: BdjAdmissionState.unrecognised,
              qjExecution: false,
              qgExecution: false,
              fieldingAuthorized: false,
            ),
    );
  }

  bool get isApproved => decision == 'APPROVED';
  bool get isRejected => decision == 'REJECTED';
}
