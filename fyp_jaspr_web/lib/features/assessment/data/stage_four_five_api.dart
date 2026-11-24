/// Authenticated reads for Stage 4 (question review) and Stage 5 (preview).
///
/// A separate port from `BdjObjectiveProposalPort` on purpose: adding methods to
/// that interface would break every existing implementer, including the recorded
/// fixtures the Stage 3 tests render. Nothing here writes, dispatches or
/// authorises: every method is a GET, and the server reports its own refusal
/// codes verbatim.
///
/// * `GET /project1-workflow/assessments/{id}/objective-proposals/{pid}/admission`
/// * `GET /m2/research-objectives/{objective_id}/research-questions`
/// * `GET /m2/assessments/{id}/questionnaire-preview`
library;

import 'package:sitewise_jaspr_web/features/assessment/data/assessment_api.dart';
import 'package:sitewise_jaspr_web/features/authentication/data/auth_service.dart';

const String _workflow = '/api/v1/project1-workflow/assessments';
const String _m2 = '/api/v1/m2';

/// One answer option. `code` is the server's code, never a position.
///
/// `eligible` is the server's own selection constraint. It stays nullable so
/// "the server did not say" is distinct from "the server said ineligible" — a
/// projection that omits the flag must not be rendered as a disabled option.
final class QuestionOption {
  const QuestionOption({required this.code, required this.label, this.eligible});
  final String code;
  final String label;
  final bool? eligible;
}

/// The owner-admission state for one proposal.
///
/// `state` is the server's own vocabulary (`HELD`, `ADMITTED`,
/// `NOT_ADMISSIBLE`). The panel never derives it.
final class ProposalAdmission {
  const ProposalAdmission({
    required this.state,
    required this.reason,
    this.objectiveId,
    this.qgEligible = false,
    this.qgBlocker,
    this.admissionId,
  });

  final String state;
  final String reason;
  final String? objectiveId;
  final bool qgEligible;
  final String? qgBlocker;
  final String? admissionId;

  bool get isAdmitted => state == 'ADMITTED';

  factory ProposalAdmission.fromJson(Map<String, dynamic> json) {
    final admission = json['admission'] is Map
        ? Map<String, dynamic>.from(json['admission'] as Map)
        : json;
    return ProposalAdmission(
      state: '${admission['state'] ?? 'UNKNOWN'}',
      reason: '${admission['reason'] ?? ''}',
      objectiveId: admission['objective_id'] as String?,
      qgEligible: admission['qg_eligible'] == true,
      qgBlocker: admission['qg_blocker'] as String?,
      admissionId: admission['admission_id'] as String?,
    );
  }
}

/// One persisted candidate version.
final class ResearchQuestionCandidate {
  const ResearchQuestionCandidate({
    required this.version,
    required this.question,
    required this.options,
    required this.status,
    this.decision,
    this.rationale,
    this.supersedes,
  });

  final String version;
  final String question;
  final List<QuestionOption> options;
  final String status;
  final String? decision;
  final String? rationale;
  final String? supersedes;

  bool get isPending => status == 'PENDING';
}

/// Every version for one objective, oldest first.
final class QuestionHistory {
  const QuestionHistory({
    required this.objectiveId,
    required this.objective,
    required this.versions,
  });

  final String objectiveId;
  final String objective;
  final List<ResearchQuestionCandidate> versions;

  factory QuestionHistory.fromJson(Map<String, dynamic> json) {
    final raw = json['versions'];
    return QuestionHistory(
      objectiveId: '${json['objective_id'] ?? ''}',
      objective: '${json['objective'] ?? ''}',
      versions: raw is List
          ? raw
                .whereType<Map>()
                .map(
                  (v) => ResearchQuestionCandidate(
                    version: '${v['version'] ?? ''}',
                    question: '${v['question'] ?? ''}',
                    options: parseOptions(v['options']),
                    status: '${v['status'] ?? 'PENDING'}',
                    decision: v['decision'] as String?,
                    rationale: v['rationale'] as String?,
                    supersedes: v['supersedes'] as String?,
                  ),
                )
                .toList(growable: false)
          : const [],
    );
  }
}

/// One row of the Stage 5 preview.
///
/// `source` names the table the row came from. It is carried because the preview
/// reads `m2_review_question_versions`, not `m2_qg_candidates`, and a reader who
/// does not know that will look for a generated candidate in the wrong list.
final class PreviewItem {
  const PreviewItem({
    required this.objectiveId,
    required this.objectiveText,
    required this.question,
    required this.questionVersion,
    required this.options,
    required this.accepted,
    this.objectiveAuthority,
    this.source,
  });

  final String objectiveId;
  final String objectiveText;
  final String question;
  final String questionVersion;
  final List<QuestionOption> options;
  final bool accepted;
  final String? objectiveAuthority;
  final String? source;
}

/// The Stage 5 envelope. `status` is `UNAVAILABLE` or `DRAFT_AVAILABLE`.
final class QuestionnairePreview {
  const QuestionnairePreview({
    required this.status,
    required this.reason,
    required this.items,
    required this.draftOnly,
    required this.fieldingAuthorized,
    required this.publicationAuthorized,
    this.confirmationId,
    this.assessmentRevision,
  });

  final String status;
  final String reason;
  final List<PreviewItem> items;
  final bool draftOnly;
  final bool fieldingAuthorized;
  final bool publicationAuthorized;
  final String? confirmationId;
  final int? assessmentRevision;

  bool get isAvailable => status == 'DRAFT_AVAILABLE' && items.isNotEmpty;

  factory QuestionnairePreview.fromJson(Map<String, dynamic> json) {
    final raw = json['question_items'];
    return QuestionnairePreview(
      status: '${json['status'] ?? 'UNAVAILABLE'}',
      reason: '${json['reason'] ?? ''}',
      confirmationId: json['confirmation_id'] as String?,
      assessmentRevision: json['assessment_revision'] as int?,
      draftOnly: json['draft_only'] != false,
      fieldingAuthorized: json['fielding_authorized'] == true,
      publicationAuthorized: json['publication_authorized'] == true,
      items: raw is List
          ? raw
                .whereType<Map>()
                .map(
                  (i) => PreviewItem(
                    objectiveId: '${i['objective_id'] ?? ''}',
                    objectiveText: '${i['objective_text'] ?? ''}',
                    question: '${i['question'] ?? ''}',
                    questionVersion: '${i['question_version'] ?? ''}',
                    options: parseOptions(i['options']),
                    accepted: i['accepted'] == true,
                    objectiveAuthority: i['objective_authority'] as String?,
                    source: i['source'] as String?,
                  ),
                )
                .toList(growable: false)
          : const [],
    );
  }
}

/// Options arrive either as maps (`{code,label,eligible}`) or as bare strings.
List<QuestionOption> parseOptions(Object? raw) {
  if (raw is! List) return const [];
  final out = <QuestionOption>[];
  for (var index = 0; index < raw.length; index++) {
    final entry = raw[index];
    if (entry is Map) {
      final code = entry['code'] ?? entry['value'];
      final label = entry['label'] ?? entry['text'] ?? entry['code'] ?? entry['value'];
      final eligible = entry['eligible'];
      out.add(
        QuestionOption(
          code: '${code ?? index + 1}',
          label: '${label ?? ''}',
          eligible: eligible is bool ? eligible : null,
        ),
      );
    } else if (entry != null) {
      out.add(QuestionOption(code: '${index + 1}', label: '$entry'));
    }
  }
  return out;
}

/// The current question version as the review surface sees it.
///
/// Produced by `GET …/research-questions/{version}/entrepreneur-review`, which
/// returns only the version that no newer version supersedes. `desiredOption`
/// is the entrepreneur's *expected* answer — an expectation, never a respondent
/// answer, and never an input to a CQ or EE-01 calculation.
final class QuestionReviewDetail {
  const QuestionReviewDetail({
    required this.version,
    required this.objectiveId,
    required this.question,
    required this.options,
    this.desiredOption,
  });

  final String version;
  final String objectiveId;
  final String question;
  final List<QuestionOption> options;
  final String? desiredOption;

  factory QuestionReviewDetail.fromJson(Map<String, dynamic> json) =>
      QuestionReviewDetail(
        version: '${json['id'] ?? json['question_version'] ?? ''}',
        objectiveId: '${json['objective_id'] ?? ''}',
        question: '${json['question'] ?? ''}',
        options: parseOptions(json['options']),
        desiredOption: json['option_code'] as String?,
      );
}

/// The receipt a review decision returns.
///
/// The server pins `fielding_authorized` and `scientific_acceptance` to false on
/// every decision. They are carried here so the page can assert that rather
/// than assume it.
final class QuestionReviewReceipt {
  const QuestionReviewReceipt({
    required this.decision,
    required this.rationale,
    required this.fieldingAuthorized,
    required this.scientificAcceptance,
  });

  final String decision;
  final String rationale;
  final bool fieldingAuthorized;
  final bool scientificAcceptance;

  factory QuestionReviewReceipt.fromJson(Map<String, dynamic> json) =>
      QuestionReviewReceipt(
        decision: '${json['decision'] ?? ''}',
        rationale: '${json['rationale'] ?? ''}',
        fieldingAuthorized: json['fielding_authorized'] == true,
        scientificAcceptance: json['scientific_acceptance'] == true,
      );
}

/// The three decisions the database accepts
/// (`m2_candidate_owner_reviews_decision_check`).
const List<String> kQuestionReviewDecisions = [
  'APPROVE_FOR_REVIEW',
  'REJECT',
  'REQUEST_REVISION',
];

/// One answer option of a persisted Direct-QG candidate.
///
/// `orderSource` says where the ordering came from: `MEASUREMENT` when the
/// measurement supplied an explicit `order`, `ARRAY_POSITION` when only the
/// parallel response arrays existed. The distinction matters because the second
/// is a weaker claim about the intended sequence.
final class CandidateOption {
  const CandidateOption({
    required this.code,
    required this.label,
    required this.order,
    required this.orderSource,
  });

  final String code;
  final String label;
  final int order;
  final String orderSource;
}

/// The owner's review of one candidate. All fields null until reviewed.
final class CandidateReview {
  const CandidateReview({
    this.decision,
    this.rationale,
    this.recordedAt,
    this.expectedOptionCode,
    this.reviewed = false,
  });

  final String? decision;
  final String? rationale;
  final String? recordedAt;
  final String? expectedOptionCode;
  final bool reviewed;

  factory CandidateReview.fromJson(Map<String, dynamic> json) => CandidateReview(
    decision: json['decision'] as String?,
    rationale: json['rationale'] as String?,
    recordedAt: json['recorded_at'] as String?,
    expectedOptionCode: json['expected_option_code'] as String?,
    reviewed: json['reviewed'] == true,
  );
}

/// The receipt a candidate review returns.
///
/// Deliberately not the persisted review: the server echoes only the decision
/// plus the two authority flags, which it pins to false. Reusing
/// [CandidateReview] here would let a caller mistake a receipt for the stored
/// record and skip the read-back.
final class CandidateReviewReceipt {
  const CandidateReviewReceipt({
    required this.candidateId,
    required this.decision,
    required this.rationale,
    required this.fieldingAuthorized,
    required this.scientificallyAccepted,
  });

  final String candidateId;
  final String decision;
  final String rationale;
  final bool fieldingAuthorized;
  final bool scientificallyAccepted;

  factory CandidateReviewReceipt.fromJson(Map<String, dynamic> json) =>
      CandidateReviewReceipt(
        candidateId: '${json['candidate_id'] ?? ''}',
        decision: '${json['decision'] ?? ''}',
        rationale: '${json['rationale'] ?? ''}',
        fieldingAuthorized: json['fielding_authorized'] == true,
        scientificallyAccepted: json['scientifically_accepted'] == true,
      );
}

/// A persisted Direct-QG question candidate, as Stage 4 reads it.
///
/// Everything is decoded from the server envelope (`sitewise-qg-candidate/1`).
/// `dispatched` is the server's own statement that a ledger run exists; it is
/// never inferred from the provider name, because a simulated run has a provider
/// label but no run row.
final class QgCandidate {
  const QgCandidate({
    required this.candidateId,
    required this.assessmentId,
    required this.objectiveId,
    required this.objectiveClassification,
    required this.question,
    required this.responseFormat,
    required this.options,
    required this.routing,
    required this.review,
    required this.candidateState,
    required this.executionMode,
    required this.modelProvider,
    required this.dispatched,
    required this.fieldingAuthorized,
    required this.scientificallyAccepted,
    this.objectiveAdmissionId,
    this.proposalId,
    this.policyDisposition,
    this.policyVersion,
    this.confirmationId,
    this.assessmentRevision,
    this.measurementId,
    this.measurementVersion,
    this.runId,
    this.attemptNo,
    this.promptVersion,
    this.promptSha256,
    this.qgAuthorizationId,
    this.contractVersion,
    this.adapterVersion,
    this.modelRequested,
    this.modelReturned,
    this.referencePeriod,
    this.limitations,
    this.justification,
    this.structuralStatus,
    this.semanticStatus,
    this.provenanceStatus,
    this.createdAt,
  });

  final String candidateId;
  final String assessmentId;
  final String objectiveId;
  final String objectiveClassification;
  final String question;
  final String responseFormat;
  final List<CandidateOption> options;
  final Map<String, dynamic> routing;
  final CandidateReview review;
  final String candidateState;
  final String executionMode;
  final String modelProvider;
  final bool dispatched;
  final bool fieldingAuthorized;
  final bool scientificallyAccepted;
  final String? objectiveAdmissionId;
  final String? proposalId;
  final String? policyDisposition;
  final String? policyVersion;
  final String? confirmationId;
  final int? assessmentRevision;
  final String? measurementId;
  final String? measurementVersion;
  final String? runId;
  final int? attemptNo;
  final String? promptVersion;
  final String? promptSha256;
  final String? qgAuthorizationId;
  final String? contractVersion;
  final String? adapterVersion;
  final String? modelRequested;
  final String? modelReturned;
  final String? referencePeriod;
  final String? limitations;
  final String? justification;
  final String? structuralStatus;
  final String? semanticStatus;
  final String? provenanceStatus;
  final String? createdAt;

  factory QgCandidate.fromJson(Map<String, dynamic> json) {
    final rawOptions = json['options'];
    final options = <CandidateOption>[];
    if (rawOptions is List) {
      for (final entry in rawOptions) {
        if (entry is! Map) continue;
        options.add(
          CandidateOption(
            code: '${entry['code'] ?? ''}',
            label: '${entry['label'] ?? ''}',
            order: entry['order'] is num ? (entry['order'] as num).toInt() : 0,
            orderSource: '${entry['order_source'] ?? 'UNKNOWN'}',
          ),
        );
      }
    }
    options.sort((a, b) => a.order.compareTo(b.order));
    final routing = json['routing'];
    final review = json['review'];
    return QgCandidate(
      candidateId: '${json['candidate_id'] ?? ''}',
      assessmentId: '${json['assessment_id'] ?? ''}',
      objectiveId: '${json['objective_id'] ?? ''}',
      objectiveClassification: '${json['objective_classification'] ?? 'UNCLASSIFIED'}',
      question: '${json['question'] ?? ''}',
      responseFormat: '${json['response_format'] ?? ''}',
      options: options,
      routing: routing is Map ? Map<String, dynamic>.from(routing) : const {},
      review: review is Map
          ? CandidateReview.fromJson(Map<String, dynamic>.from(review))
          : const CandidateReview(),
      candidateState: '${json['candidate_state'] ?? ''}',
      executionMode: '${json['execution_mode'] ?? ''}',
      modelProvider: '${json['model_provider'] ?? ''}',
      dispatched: json['dispatched'] == true,
      fieldingAuthorized: json['fielding_authorized'] == true,
      scientificallyAccepted: json['scientifically_accepted'] == true,
      objectiveAdmissionId: json['objective_admission_id'] as String?,
      proposalId: json['proposal_id'] as String?,
      policyDisposition: json['policy_disposition'] as String?,
      policyVersion: json['policy_version'] as String?,
      confirmationId: json['confirmation_id'] as String?,
      assessmentRevision: json['assessment_revision'] is num
          ? (json['assessment_revision'] as num).toInt()
          : null,
      measurementId: json['measurement_id'] as String?,
      measurementVersion: json['measurement_version'] as String?,
      runId: json['run_id'] as String?,
      attemptNo: json['attempt_no'] is num
          ? (json['attempt_no'] as num).toInt()
          : null,
      promptVersion: json['prompt_version'] as String?,
      promptSha256: json['prompt_sha256'] as String?,
      qgAuthorizationId: json['qg_authorization_id'] as String?,
      contractVersion: json['contract_version'] as String?,
      adapterVersion: json['adapter_version'] as String?,
      modelRequested: json['model_requested'] as String?,
      modelReturned: json['model_returned'] as String?,
      referencePeriod: json['reference_period'] as String?,
      limitations: json['limitations'] as String?,
      justification: json['justification'] as String?,
      structuralStatus: json['structural_status'] as String?,
      semanticStatus: json['semantic_status'] as String?,
      provenanceStatus: json['provenance_status'] as String?,
      createdAt: json['created_at'] as String?,
    );
  }

  bool get isSimulated => executionMode.toUpperCase() == 'SIMULATED';

  /// `true` only when the server states a ledger run exists **and** the provider
  /// is not the simulator. The two conditions are separate on purpose: a
  /// simulated candidate has a provider label but no run row, and a run row with
  /// a simulator label would still not be a live call.
  bool get isLiveProviderRun => dispatched && !isSimulated;
}

/// One eligibility check, as the server reported it.
///
/// `evidence` is the server's own supporting detail — for a
/// `QG_LIVE_AUTHORIZATION_NOT_BOUND_TO_ASSESSMENT` refusal it names both the
/// authorized and the requested assessment, which is what makes the refusal
/// actionable instead of merely negative.
final class EligibilityCheck {
  const EligibilityCheck({
    required this.checkId,
    required this.title,
    required this.status,
    required this.reasonCode,
    this.sources = const [],
    this.evidence = const {},
  });

  final String checkId;
  final String title;
  final String status;
  final String reasonCode;
  final List<String> sources;
  final Map<String, dynamic> evidence;

  bool get isBlocking => status != 'PASS';
  bool get isUnverified => status == 'UNVERIFIED';
  bool get isFailed => status == 'FAIL';
}

/// Why Direct-QG can or cannot run, requirement by requirement.
///
/// Two statuses are kept apart because they fail for different reasons:
/// `prepareStatus` asks whether a candidate can exist at all, `dispatchStatus`
/// whether that candidate may reach a real provider. A `PASS` here is
/// diagnostic only — the live runner re-verifies every condition itself.
final class QgEligibility {
  const QgEligibility({
    required this.prepareStatus,
    required this.prepareRefusal,
    required this.dispatchStatus,
    required this.dispatchRefusal,
    required this.checks,
    required this.fieldingAuthorized,
    required this.scientificallyAccepted,
    required this.dispatchesModel,
    this.objectiveId,
    this.admissionId,
    this.proposalId,
    this.measurementId,
    this.measurementVersion,
  });

  final String prepareStatus;
  final String prepareRefusal;
  final String dispatchStatus;
  final String dispatchRefusal;
  final List<EligibilityCheck> checks;
  final bool fieldingAuthorized;
  final bool scientificallyAccepted;

  /// The server's own statement that this report caused no provider call.
  final bool dispatchesModel;

  final String? objectiveId;
  final String? admissionId;
  final String? proposalId;
  final String? measurementId;
  final String? measurementVersion;

  factory QgEligibility.fromJson(Map<String, dynamic> json) {
    final raw = json['checks'];
    return QgEligibility(
      prepareStatus: '${json['prepare_status'] ?? 'UNVERIFIED'}',
      prepareRefusal: '${json['prepare_refusal'] ?? ''}',
      dispatchStatus: '${json['dispatch_status'] ?? 'UNVERIFIED'}',
      dispatchRefusal: '${json['dispatch_refusal'] ?? ''}',
      objectiveId: json['objective_id'] as String?,
      admissionId: json['admission_id'] as String?,
      proposalId: json['proposal_id'] as String?,
      measurementId: json['measurement_id'] as String?,
      measurementVersion: json['measurement_version'] as String?,
      fieldingAuthorized: json['fielding_authorized'] == true,
      scientificallyAccepted: json['scientifically_accepted'] == true,
      dispatchesModel: json['dispatches_model'] == true,
      checks: raw is List
          ? raw
                .whereType<Map>()
                .map(
                  (row) => EligibilityCheck(
                    checkId: '${row['check_id'] ?? ''}',
                    title: '${row['title'] ?? ''}',
                    status: '${row['status'] ?? 'UNVERIFIED'}',
                    reasonCode: '${row['reason_code'] ?? ''}',
                    sources: row['sources'] is List
                        ? (row['sources'] as List)
                              .map((s) => '$s')
                              .toList(growable: false)
                        : const [],
                    evidence: row['evidence'] is Map
                        ? Map<String, dynamic>.from(row['evidence'] as Map)
                        : const {},
                  ),
                )
                .toList(growable: false)
          : const [],
    );
  }

  /// The first blocking check, in the server's declaration order.
  ///
  /// Order matters and is preserved: the server declares admission first, then
  /// measurement, then authorization, so the first blocker is the earliest
  /// unmet prerequisite rather than an arbitrary one.
  EligibilityCheck? get firstBlocker {
    for (final check in checks) {
      if (check.isBlocking) return check;
    }
    return null;
  }

  /// The refusal code a reader should act on, with the status it came with.
  String get blockingReason {
    final blocker = firstBlocker;
    if (blocker == null) return '';
    return blocker.reasonCode.isEmpty
        ? '${blocker.checkId}_${blocker.status}'
        : blocker.reasonCode;
  }
}

/// Transport port for the Stage 4/5 reads and the Stage 4 review decisions.
abstract interface class StageFourFivePort {
  Future<ApiResult<ProposalAdmission>> admission({
    required String assessmentId,
    required String proposalId,
    required int expectedRevision,
    required String contextId,
  });

  Future<ApiResult<QuestionHistory>> history({
    required String objectiveId,
    required int expectedRevision,
  });

  Future<ApiResult<QuestionReviewDetail>> reviewQuestion({
    required String version,
    required int expectedRevision,
  });

  Future<ApiResult<QuestionReviewReceipt>> recordReview({
    required String version,
    required String decision,
    required String rationale,
  });

  Future<ApiResult<String?>> selectDesiredOption({
    required String version,
    required int expectedRevision,
    String? optionCode,
  });

  /// Persisted Direct-QG candidates for one assessment, newest first.
  Future<ApiResult<List<QgCandidate>>> candidates({required String assessmentId});

  /// Why Direct-QG can or cannot run for one objective.
  Future<ApiResult<QgEligibility>> eligibility({
    required String assessmentId,
    required String objectiveId,
  });

  /// Records the owner's judgement about a persisted candidate.
  ///
  /// `expectedRevision` is the assessment revision the reviewer believes they are
  /// looking at. The server refuses a mismatch with 409 rather than applying the
  /// judgement to a question the reviewer never saw.
  Future<ApiResult<CandidateReviewReceipt>> reviewCandidate({
    required String assessmentId,
    required String candidateId,
    required String decision,
    required String rationale,
    int? expectedRevision,
  });

  /// Records the entrepreneur's expected answer. Never a respondent answer.
  Future<ApiResult<String?>> setExpectedAnswer({
    required String assessmentId,
    required String candidateId,
    String? optionCode,
    int? expectedRevision,
  });

  Future<ApiResult<QuestionnairePreview>> preview({required String assessmentId});
}

final class StageFourFiveApi implements StageFourFivePort {
  const StageFourFiveApi();

  @override
  Future<ApiResult<ProposalAdmission>> admission({
    required String assessmentId,
    required String proposalId,
    required int expectedRevision,
    required String contextId,
  }) => _call(
    '$_workflow/${Uri.encodeComponent(assessmentId)}/objective-proposals/'
    '${Uri.encodeComponent(proposalId)}/admission'
    '?expected_revision=$expectedRevision'
    '&context_id=${Uri.encodeQueryComponent(contextId)}',
    ProposalAdmission.fromJson,
  );

  @override
  Future<ApiResult<QuestionHistory>> history({
    required String objectiveId,
    required int expectedRevision,
  }) => _call(
    '$_m2/research-objectives/${Uri.encodeComponent(objectiveId)}/'
    'research-questions?expected_revision=$expectedRevision',
    QuestionHistory.fromJson,
  );

  @override
  Future<ApiResult<QuestionReviewDetail>> reviewQuestion({
    required String version,
    required int expectedRevision,
  }) => _call(
    '$_m2/research-questions/${Uri.encodeComponent(version)}/'
    'entrepreneur-review?expected_revision=$expectedRevision',
    QuestionReviewDetail.fromJson,
  );

  @override
  Future<ApiResult<QuestionReviewReceipt>> recordReview({
    required String version,
    required String decision,
    required String rationale,
  }) => _call(
    '$_m2/research-questions/${Uri.encodeComponent(version)}/owner-review',
    QuestionReviewReceipt.fromJson,
    method: 'POST',
    body: {'decision': decision, 'rationale': rationale},
  );

  /// Records the entrepreneur's *expected* answer.
  ///
  /// A null `optionCode` clears it. This is an expectation about the answer, not
  /// an answer: it is never counted as a respondent response.
  @override
  Future<ApiResult<String?>> selectDesiredOption({
    required String version,
    required int expectedRevision,
    String? optionCode,
  }) => _call(
    '$_m2/research-questions/${Uri.encodeComponent(version)}/desired-option',
    (json) => json['desired_option'] as String?,
    method: 'PUT',
    body: {'expected_revision': expectedRevision, 'option_code': optionCode},
  );

  @override
  Future<ApiResult<List<QgCandidate>>> candidates({
    required String assessmentId,
  }) => _call(
    '$_m2/assessments/${Uri.encodeComponent(assessmentId)}/qg-candidates',
    (json) {
      final raw = json['candidates'];
      if (raw is! List) return const <QgCandidate>[];
      return raw
          .whereType<Map>()
          .map((row) => QgCandidate.fromJson(Map<String, dynamic>.from(row)))
          .toList(growable: false);
    },
  );

  /// The eligibility report for one objective.
  ///
  /// An empty `objectiveId` is not sent as an empty query value: the server would
  /// then select the most recent admission of any objective, which is a different
  /// question from the one being asked.
  @override
  Future<ApiResult<QgEligibility>> eligibility({
    required String assessmentId,
    required String objectiveId,
  }) => _call(
    '$_m2/assessments/${Uri.encodeComponent(assessmentId)}/qg-eligibility'
    '${objectiveId.isEmpty ? '' : '?objective_id=${Uri.encodeQueryComponent(objectiveId)}'}',
    QgEligibility.fromJson,
  );

  /// Records the owner's judgement about a persisted candidate.
  ///
  /// The receipt is not a new candidate: it carries only the decision plus the
  /// two authority flags, which the server pins to false. The caller must re-read
  /// the candidate to see the persisted review, because the receipt deliberately
  /// does not echo the whole record.
  @override
  Future<ApiResult<CandidateReviewReceipt>> reviewCandidate({
    required String assessmentId,
    required String candidateId,
    required String decision,
    required String rationale,
    int? expectedRevision,
  }) => _call(
    '$_m2/assessments/${Uri.encodeComponent(assessmentId)}/qg-candidates/'
    '${Uri.encodeComponent(candidateId)}/review',
    CandidateReviewReceipt.fromJson,
    method: 'POST',
    body: {
      'decision': decision,
      'rationale': rationale,
      'expected_revision': ?expectedRevision,
    },
  );

  /// Records the entrepreneur's expectation. A null `optionCode` clears it.
  @override
  Future<ApiResult<String?>> setExpectedAnswer({
    required String assessmentId,
    required String candidateId,
    String? optionCode,
    int? expectedRevision,
  }) => _call(
    '$_m2/assessments/${Uri.encodeComponent(assessmentId)}/qg-candidates/'
    '${Uri.encodeComponent(candidateId)}/expected-answer',
    (json) => json['expected_option_code'] as String?,
    method: 'PUT',
    body: {
      'option_code': optionCode,
      'expected_revision': ?expectedRevision,
    },
  );

  @override
  Future<ApiResult<QuestionnairePreview>> preview({
    required String assessmentId,
  }) => _call(
    '$_m2/assessments/${Uri.encodeComponent(assessmentId)}/questionnaire-preview',
    QuestionnairePreview.fromJson,
  );

  static Future<ApiResult<T>> _call<T>(
    String path,
    T Function(Map<String, dynamic>) parse, {
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
              'The research service could not complete this request.',
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
      return ApiResult<T>.error(
        AssessmentFailure(
          code: 'unexpected_response',
          message: 'The research response could not be read: $error',
        ),
      );
    }
  }
}
