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

import 'dart:math';

import 'package:sitewise_jaspr_web/features/assessment/data/assessment_api.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/bdj_objective_proposal.dart';
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

/// Reported when the server returned no admission state at all.
///
/// Deliberately not `UNKNOWN`: the previous code defaulted to that word, which
/// reads like a state the server chose and rendered as `Admission UNKNOWN ()`.
const String unreadableState = 'UNREADABLE';

/// The owner-admission state for one proposal.
///
/// `state` is the server's own vocabulary (`HELD`, `ADMITTED`,
/// `NOT_ADMISSIBLE`). The panel never derives it.
///
/// [pendingRequirement] is the server's own sentence describing what is
/// outstanding — or, when the refusal is a policy result, that it is *not* a
/// missing owner action. Stage 4 used to have no field for it and therefore
/// rewrote every non-admitted state as "the owner has not recorded that this
/// gap is worth researching", which misattributed
/// `ADMISSION_NOT_RESEARCH_SUITABLE_*` to the owner. The server's sentence is
/// now preferred verbatim, and the local fallback is used only when the server
/// sent none.
final class ProposalAdmission {
  const ProposalAdmission({
    required this.state,
    required this.reason,
    this.objectiveId,
    this.qgEligible = false,
    this.qgBlocker,
    this.admissionId,
    this.pendingRequirement,
    this.policyDisposition,
  });

  final String state;
  final String reason;
  final String? objectiveId;
  final bool qgEligible;
  final String? qgBlocker;
  final String? admissionId;
  final String? pendingRequirement;
  final String? policyDisposition;

  bool get isAdmitted => state == 'ADMITTED';

  /// The same state, in the vocabulary Stage 3 already renders.
  ///
  /// Both surfaces describe one server value, so both must read it through one
  /// parser. `unrecognised` means the wire value was absent or unknown — it is
  /// never used for a state the server actually sent.
  BdjAdmissionState get parsedState => BdjAdmissionState.parse(
    state == unreadableState ? null : state,
  );

  factory ProposalAdmission.fromJson(Map<String, dynamic> json) {
    final admission = json['admission'] is Map
        ? Map<String, dynamic>.from(json['admission'] as Map)
        : json;
    // The server's authority block is emitted by
    // `objective_admission._state` as `admission_state` / `admission_reason`.
    // This projection used to read `state` / `reason`, which match nothing, so
    // every Stage 4 card fell back to `UNKNOWN` with an empty reason and
    // contradicted Stage 3 about the same proposal. The legacy names are still
    // accepted second, so an older payload cannot silently regress.
    final rawState = admission['admission_state'] ?? admission['state'];
    final rawReason = admission['admission_reason'] ?? admission['reason'];
    // A genuinely absent state is reported as unreadable, never as a state the
    // server might have meant.
    final state = rawState is String && rawState.trim().isNotEmpty
        ? rawState.trim()
        : unreadableState;
    final rawPending = admission['pending_requirement'];
    final rawDisposition = admission['policy_disposition'];
    return ProposalAdmission(
      state: state,
      reason: rawReason is String ? rawReason : '',
      objectiveId: admission['objective_id'] as String?,
      qgEligible: admission['qg_eligible'] == true,
      qgBlocker: admission['qg_blocker'] as String?,
      admissionId: admission['admission_id'] as String?,
      pendingRequirement: rawPending is String && rawPending.trim().isNotEmpty
          ? rawPending.trim()
          : null,
      policyDisposition: rawDisposition is String && rawDisposition.isNotEmpty
          ? rawDisposition
          : null,
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
    this.expectedOptionCodes = const [],
    this.reviewed = false,
  });

  final String? decision;
  final String? rationale;
  final String? recordedAt;

  /// The compatibility projection of [expectedOptionCodes]. NULL for a
  /// multi-select intention, so it must never be read as "no intention".
  final String? expectedOptionCode;

  /// The owner's intended response, as the set the server stores.
  final List<String> expectedOptionCodes;

  final bool reviewed;

  factory CandidateReview.fromJson(Map<String, dynamic> json) {
    final raw = json['expected_option_codes'];
    final codes = <String>[];
    if (raw is List) {
      for (final entry in raw) {
        if (entry == null) continue;
        codes.add('$entry');
      }
    }
    final singular = json['expected_option_code'] as String?;
    return CandidateReview(
      decision: json['decision'] as String?,
      rationale: json['rationale'] as String?,
      recordedAt: json['recorded_at'] as String?,
      expectedOptionCode: singular,
      // A projection that omits the set but carries the singular is one
      // selection, not an absent one.
      expectedOptionCodes: codes.isEmpty && singular != null
          ? [singular]
          : List<String>.unmodifiable(codes),
      reviewed: json['reviewed'] == true,
    );
  }

  /// True when the owner recorded an intention, by either spelling.
  bool get hasIntention =>
      expectedOptionCodes.isNotEmpty || expectedOptionCode != null;

  /// The selection, whichever spelling the payload carried.
  ///
  /// A record built with only the compatibility field still has an intention,
  /// so every reader goes through this getter rather than the set directly.
  List<String> get selection {
    if (expectedOptionCodes.isNotEmpty) return expectedOptionCodes;
    final singular = expectedOptionCode;
    return singular == null ? const <String>[] : <String>[singular];
  }
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
///
/// The field names are the v1 ones; the contract the server actually serves is
/// `sitewise-qg-generation-eligibility/2`, which calls the same two axes
/// `generation` and `scientific`. The parser below reads the v2 keys first and
/// keeps the v1 names only as a fallback, because reading only v1 made every
/// real report render as `prepare UNVERIFIED` / `dispatch UNVERIFIED` with an
/// empty requirement list — the server's refusal was in the payload and never
/// reached the page.
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
    this.scientificChecks = const [],
    this.objectiveKind,
    this.contractVersion,
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

  /// The scientific axis, check by check. Kept separate from [checks] because
  /// the two lists answer different questions and a refusal on one is not a
  /// refusal on the other.
  final List<EligibilityCheck> scientificChecks;

  /// `ADDITIONAL_ASSESSMENT_OBJECTIVE` or `MANDATORY_REGISTRY_OBJECTIVE`.
  final String? objectiveKind;
  final String? contractVersion;

  factory QgEligibility.fromJson(Map<String, dynamic> json) {
    List<EligibilityCheck> parseChecks(Object? raw) => raw is List
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
        : const [];

    return QgEligibility(
      // v2 first, v1 second. `generation` is what v1 called `prepare`.
      prepareStatus:
          '${json['generation_status'] ?? json['prepare_status'] ?? 'UNVERIFIED'}',
      prepareRefusal:
          '${json['generation_refusal'] ?? json['prepare_refusal'] ?? ''}',
      // `scientific` is what v1 called `dispatch`.
      dispatchStatus:
          '${json['scientific_status'] ?? json['dispatch_status'] ?? 'UNVERIFIED'}',
      dispatchRefusal:
          '${json['scientific_refusal'] ?? json['dispatch_refusal'] ?? ''}',
      objectiveId: json['objective_id'] as String?,
      objectiveKind: json['objective_kind'] as String?,
      contractVersion: json['contract_version'] as String?,
      admissionId: json['admission_id'] as String?,
      proposalId: json['proposal_id'] as String?,
      measurementId: json['measurement_id'] as String?,
      measurementVersion: json['measurement_version'] as String?,
      fieldingAuthorized: json['fielding_authorized'] == true,
      scientificallyAccepted:
          json['scientifically_approved'] == true ||
          json['scientifically_accepted'] == true,
      dispatchesModel: json['dispatches_model'] == true,
      checks: parseChecks(json['generation_checks'] ?? json['checks']),
      scientificChecks: parseChecks(json['scientific_checks']),
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


/// The authority the owner's approval already establishes (contract 2.1).
///
/// The objective identity is derived by the server from the proposal
/// (`proposal:<uuid>`), not from a registry id, because an additional objective
/// has no registry entry. The client asks for it rather than composing the
/// string itself, so the contract has one definition.
final class ObjectiveAuthority {
  const ObjectiveAuthority({
    required this.objectiveId,
    required this.objectiveKind,
    required this.objectiveText,
    required this.decisionId,
    required this.decision,
    required this.confirmationRevision,
  });

  final String objectiveId;
  final String objectiveKind;
  final String objectiveText;
  final String decisionId;
  final String decision;
  final int confirmationRevision;

  bool get isApproved => decision == 'APPROVED';

  factory ObjectiveAuthority.fromJson(Map<String, dynamic> json) {
    final decision = json['decision'];
    return ObjectiveAuthority(
      objectiveId: json['objective_id'] as String? ?? '',
      objectiveKind: json['objective_kind'] as String? ?? '',
      objectiveText: json['objective_text'] as String? ?? '',
      decisionId: decision is Map
          ? decision['decision_id'] as String? ?? ''
          : '',
      decision: decision is Map ? decision['decision'] as String? ?? '' : '',
      confirmationRevision:
          (json['confirmation_revision'] as num?)?.toInt() ?? 0,
    );
  }
}

/// One purpose's execution state, read from the AI ledger.
///
/// The ledger records discrete states, so this carries a state and the facts
/// behind it — never a percentage. [progressPercent] is deliberately absent from
/// this type: the server reports it as `null` and the interface must not invent
/// one.
final class AiExecutionPurpose {
  const AiExecutionPurpose({
    required this.purpose,
    required this.state,
    required this.reason,
    this.attemptNo,
    this.attemptsReserved = 0,
    this.reservedAt,
    this.receiptOutcome,
    this.receiptAt,
    this.persisted = 0,
    this.pendingValidation = 0,
    this.milestones = const <AiMilestone>[],
    this.stale = false,
    this.assessmentRevision,
    this.attributable = true,
    this.domainStore = '',
    this.assessmentWidePersisted = 0,
  });

  /// `BDJ` or `QG`.
  final String purpose;

  /// One of BLOCKED, PROCESSING, RETURNED, VALIDATING, PERSISTED, FAILED,
  /// UNKNOWN_OUTCOME.
  final String state;
  final String reason;
  final int? attemptNo;
  final int attemptsReserved;
  final String? reservedAt;
  final String? receiptOutcome;
  final String? receiptAt;
  final int persisted;
  final int pendingValidation;

  /// Per-milestone status, as the server derived it from [state]. Empty when an
  /// older server answered, in which case the panel falls back to deriving the
  /// rail from [state] alone rather than inventing one.
  final List<AiMilestone> milestones;

  /// True when the attempt was recorded at a different assessment revision than
  /// the one now on screen. The state is preserved — a superseded execution
  /// really happened — but it is not presented as the current one.
  final bool stale;

  /// The revision the attempt was recorded at, if the server reported one.
  final int? assessmentRevision;

  /// False when the persisted count cannot be joined to *this* attempt. BDJ
  /// objective proposals carry no run/attempt identity, so their count is a
  /// true fact about the assessment that cannot complete the Persisted
  /// milestone for a new attempt (CP-PROG-01).
  final bool attributable;

  final String domainStore;

  /// The assessment-wide figure, reported beside [persisted] so history is not
  /// silently dropped when it cannot be attributed.
  final int assessmentWidePersisted;

  bool get isTerminal =>
      state == 'PERSISTED' || state == 'FAILED' || state == 'UNKNOWN_OUTCOME';

  factory AiExecutionPurpose.fromJson(Map<String, dynamic> json) {
    final domain = json['domain'];
    final wide = json['domain_assessment_wide'];
    final rawMilestones = json['milestones'];
    return AiExecutionPurpose(
      purpose: json['purpose'] as String? ?? '',
      state: json['state'] as String? ?? 'UNKNOWN_OUTCOME',
      reason: json['reason'] as String? ?? '',
      attemptNo: (json['attempt_no'] as num?)?.toInt(),
      attemptsReserved: (json['attempts_reserved'] as num?)?.toInt() ?? 0,
      reservedAt: json['reserved_at'] as String?,
      receiptOutcome: json['receipt_outcome'] as String?,
      receiptAt: json['receipt_at'] as String?,
      persisted: domain is Map
          ? (domain['persisted'] as num?)?.toInt() ?? 0
          : 0,
      pendingValidation: domain is Map
          ? (domain['pending_validation'] as num?)?.toInt() ?? 0
          : 0,
      milestones: rawMilestones is List
          ? rawMilestones
                .whereType<Map<String, dynamic>>()
                .map(AiMilestone.fromJson)
                .toList(growable: false)
          : const <AiMilestone>[],
      stale: json['stale'] as bool? ?? false,
      assessmentRevision: (json['assessment_revision'] as num?)?.toInt(),
      attributable: domain is Map
          ? (domain['attributable'] as bool? ?? true)
          : true,
      domainStore: json['domain_store'] as String? ?? '',
      assessmentWidePersisted: wide is Map
          ? (wide['persisted'] as num?)?.toInt() ?? 0
          : 0,
    );
  }
}

/// One milestone of the execution rail, as the server derived it.
///
/// The server sends four, never five: `DISPATCHED` is absent because nothing
/// durable records it. A client must not add it back.
final class AiMilestone {
  const AiMilestone({required this.name, required this.status});

  /// `RESERVED` | `RETURNED` | `VALIDATED` | `PERSISTED`.
  final String name;

  /// `COMPLETED` | `ACTIVE` | `PENDING` | `FAILED` | `UNKNOWN`.
  final String status;

  factory AiMilestone.fromJson(Map<String, dynamic> json) => AiMilestone(
    name: json['milestone'] as String? ?? '',
    status: json['status'] as String? ?? 'PENDING',
  );
}

final class AiExecutionReading {
  const AiExecutionReading({
    required this.purposes,
    required this.domainReadable,
    this.progressPercent,
    this.bdjObjectives,
    this.contract = '',
    this.currentRevision,
    this.milestones = const <String>[],
    this.unprovableMilestones = const <String>[],
    this.providerTimeoutSeconds,
    this.graceSeconds,
    this.objectiveId,
    this.objectiveScoped = false,
  });

  final List<AiExecutionPurpose> purposes;

  /// False when the domain counts could not be read. A count that could not be
  /// read is not a count of zero, and the interface says so.
  final bool domainReadable;

  /// Always null today, and kept as a field so the interface can show that the
  /// absence is deliberate rather than an omission.
  final int? progressPercent;

  /// BDJ objective proposals: how many exist, how many the owner approved, and
  /// how many were scientifically admitted. The last two are separate facts —
  /// an approved objective can still be refused as research-unsuitable — and
  /// null means the read failed, never zero.
  final BdjObjectiveCounts? bdjObjectives;

  /// The contract this reading was produced under, e.g.
  /// `sitewise-ai-execution-status/2`. Empty when an older server answered.
  final String contract;

  /// The M2 revision the staleness qualifier was evaluated against.
  final int? currentRevision;

  /// The milestones the server supports, in order. Authoritative: the client
  /// renders these rather than a list of its own, so the two cannot drift.
  final List<String> milestones;

  /// Milestones the server explicitly cannot prove (today: `DISPATCHED`).
  final List<String> unprovableMilestones;

  /// The provider budget the server actually enforces, and the derived grace
  /// period. Reported so the client stops hardcoding its own copy.
  final int? providerTimeoutSeconds;
  final int? graceSeconds;

  /// The objective this reading was scoped to, echoed by the server.
  ///
  /// Direct-QG can be generating for two approved objectives at once, and the
  /// route answers one objective at a time. Without this echo a client polling
  /// two objectives cannot tell which response it is holding, and the slower
  /// answer overwrites the other objective's rail (CP-FINAL-04).
  final String? objectiveId;

  /// Whether the server scoped this reading to one objective. False means the
  /// figures are stage-wide.
  final bool objectiveScoped;

  /// Whether this reading answers a request for [objective].
  ///
  /// A stage-wide reading (`objectiveScoped == false`) is *not* an answer to an
  /// objective-scoped question: it reports the newest attempt whichever objective
  /// produced it, which is exactly the confusion the scoping exists to remove.
  bool answersObjective(String objective) =>
      objectiveScoped && objectiveId == objective;

  AiExecutionPurpose? forPurpose(String purpose) {
    for (final p in purposes) {
      if (p.purpose == purpose) return p;
    }
    return null;
  }

  factory AiExecutionReading.fromJson(Map<String, dynamic> json) {
    final raw = json['purposes'];
    final timing = json['timing'];
    final rawMilestones = json['milestones'];
    final rawUnprovable = json['unprovable_milestones'];
    return AiExecutionReading(
      purposes: raw is List
          ? raw
                .whereType<Map<String, dynamic>>()
                .map(AiExecutionPurpose.fromJson)
                .toList(growable: false)
          : const <AiExecutionPurpose>[],
      domainReadable: json['domain_readable'] as bool? ?? false,
      progressPercent: (json['progress_percent'] as num?)?.toInt(),
      bdjObjectives: json['bdj_objectives'] is Map
          ? BdjObjectiveCounts.fromJson(
              (json['bdj_objectives'] as Map).cast<String, dynamic>(),
            )
          : null,
      contract: json['contract'] as String? ?? '',
      currentRevision: (json['current_revision'] as num?)?.toInt(),
      milestones: rawMilestones is List
          ? rawMilestones.whereType<String>().toList(growable: false)
          : const <String>[],
      unprovableMilestones: rawUnprovable is List
          ? rawUnprovable.whereType<String>().toList(growable: false)
          : const <String>[],
      providerTimeoutSeconds: timing is Map
          ? (timing['provider_timeout_seconds'] as num?)?.toInt()
          : null,
      graceSeconds: timing is Map
          ? (timing['grace_seconds'] as num?)?.toInt()
          : null,
      objectiveId: json['objective_id'] as String?,
      objectiveScoped: json['objective_scoped'] as bool? ?? false,
    );
  }
}

/// Proposal counts for Stage 3's summary.
final class BdjObjectiveCounts {
  const BdjObjectiveCounts({
    required this.proposed,
    required this.approved,
    required this.admitted,
    required this.readable,
  });

  final int proposed;
  final int approved;
  final int admitted;

  /// False when the server could not read the counts. The summary then says
  /// "unavailable" rather than printing a zero it cannot stand behind.
  final bool readable;

  factory BdjObjectiveCounts.fromJson(Map<String, dynamic> json) =>
      BdjObjectiveCounts(
        proposed: (json['proposed'] as num?)?.toInt() ?? 0,
        approved: (json['approved'] as num?)?.toInt() ?? 0,
        admitted: (json['admitted'] as num?)?.toInt() ?? 0,
        readable: json['readable'] as bool? ?? false,
      );
}

/// The owner's QG processing permission for one objective.
///
/// [state] distinguishes five situations the interface must word differently:
/// `ABSENT` (never asked), `GRANTED`, `EXPIRED`, `REVOKED` and `CONSUMED` (the
/// single authorised attempt is spent).
final class QgConsent {
  const QgConsent({
    required this.state,
    required this.disclosure,
    this.consentId,
    this.maxAttempts = 0,
    this.expiresAt,
    this.grantedAt,
    this.revokedReason,
  });

  final String state;
  final Map<String, dynamic> disclosure;
  final String? consentId;
  final int maxAttempts;
  final String? expiresAt;
  final String? grantedAt;
  final String? revokedReason;

  bool get isGranted => state == 'GRANTED';

  factory QgConsent.fromJson(Map<String, dynamic> json) {
    final grant = json['grant'];
    final disclosure = json['disclosure'];
    return QgConsent(
      state: json['state'] as String? ?? 'ABSENT',
      disclosure: disclosure is Map<String, dynamic>
          ? disclosure
          : const <String, dynamic>{},
      consentId: grant is Map ? grant['consent_id'] as String? : null,
      maxAttempts: grant is Map
          ? (grant['max_attempts'] as num?)?.toInt() ?? 0
          : 0,
      expiresAt: grant is Map ? grant['expires_at'] as String? : null,
      grantedAt: grant is Map ? grant['granted_at'] as String? : null,
      revokedReason: grant is Map ? grant['revoked_reason'] as String? : null,
    );
  }
}

/// Transport port for the Stage 4/5 reads and the Stage 4 review decisions.
abstract interface class StageFourFivePort {
  /// The authority the owner's approval establishes for one proposal.
  ///
  /// This is the contract 2.1 replacement for the admission read: the approval
  /// is the authority, and the server names the objective it authorises.
  Future<ApiResult<ObjectiveAuthority>> objectiveAuthority({
    required String assessmentId,
    required String proposalId,
    required String contextId,
  });

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
  ///
  /// [optionCodes] is the selection. The server stores it as a set and already
  /// accepts `option_codes` on the route; the singular [optionCode] is kept for
  /// the one-option formats, where the two spellings mean the same thing. A
  /// multiple-choice intention sent through [optionCode] would lose every option
  /// but the first, so a multi-select caller must use the set.
  Future<ApiResult<String?>> setExpectedAnswer({
    required String assessmentId,
    required String candidateId,
    String? optionCode,
    List<String>? optionCodes,
    int? expectedRevision,
  });

  Future<ApiResult<QuestionnairePreview>> preview({required String assessmentId});

  /// What the AI ledger recorded for BDJ and Direct-QG on this assessment.
  ///
  /// Reading this never invokes a model, so the card may poll it.
  Future<ApiResult<AiExecutionReading>> executionStatus({
    required String assessmentId,
  });

  /// Whether the owner has granted QG processing for one approved objective.
  Future<ApiResult<QgConsent>> qgConsent({
    required String assessmentId,
    required String proposalId,
  });

  /// Records the owner's QG processing permission.
  ///
  /// [echo] is what the interface showed them, sent back unchanged. The server
  /// re-derives every term and refuses any disagreement, so this cannot widen
  /// the disclosure.
  Future<ApiResult<QgConsent>> grantQgConsent({
    required String assessmentId,
    required String proposalId,
    required Map<String, dynamic> echo,
    String? contextId,
  });
}

final class StageFourFiveApi implements StageFourFivePort {
  const StageFourFiveApi();

  @override
  Future<ApiResult<ObjectiveAuthority>> objectiveAuthority({
    required String assessmentId,
    required String proposalId,
    required String contextId,
  }) => _call(
    '$_m2/assessments/${Uri.encodeComponent(assessmentId)}/objective-authority'
    '?proposal_id=${Uri.encodeQueryComponent(proposalId)}'
    '&context_id=${Uri.encodeQueryComponent(contextId)}',
    ObjectiveAuthority.fromJson,
  );

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

  /// Records the entrepreneur's expectation. A null selection clears it.
  ///
  /// The set is what is sent when the caller has one. The server normalises the
  /// two spellings itself, so sending only `option_codes` cannot disagree with
  /// sending only `option_code`.
  @override
  Future<ApiResult<String?>> setExpectedAnswer({
    required String assessmentId,
    required String candidateId,
    String? optionCode,
    List<String>? optionCodes,
    int? expectedRevision,
  }) => _call(
    '$_m2/assessments/${Uri.encodeComponent(assessmentId)}/qg-candidates/'
    '${Uri.encodeComponent(candidateId)}/expected-answer',
    // The receipt echoes the selection, but the set is authoritative and the
    // singular column is NULL for a multi-select intention. The set is read
    // from the candidate envelope (`review.expected_option_codes`), which is
    // what the list renders from; this return value is only the single code the
    // one-option formats carry.
    (json) => json['expected_option_code'] as String?,
    method: 'PUT',
    body: {
      // One spelling or the other, never both: the server normalises whichever
      // arrives, and sending both would make the request ambiguous about which
      // of the two it means.
      if (optionCodes == null)
        'option_code': optionCode
      else
        'option_codes': optionCodes,
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

  @override
  Future<ApiResult<AiExecutionReading>> executionStatus({
    required String assessmentId,
  }) => _call(
    '$_m2/assessments/${Uri.encodeComponent(assessmentId)}/ai-execution-status',
    AiExecutionReading.fromJson,
  );

  @override
  Future<ApiResult<QgConsent>> qgConsent({
    required String assessmentId,
    required String proposalId,
  }) => _call(
    '$_m2/assessments/${Uri.encodeComponent(assessmentId)}/qg-consents/current'
    '?proposal_id=${Uri.encodeQueryComponent(proposalId)}',
    QgConsent.fromJson,
  );

  @override
  Future<ApiResult<QgConsent>> grantQgConsent({
    required String assessmentId,
    required String proposalId,
    required Map<String, dynamic> echo,
    String? contextId,
  }) => _call(
    '$_m2/assessments/${Uri.encodeComponent(assessmentId)}/qg-consents',
    (json) {
      // A declined request answers 200 with granted:false and no grant, which is
      // a decision rather than a failure. It is reported as ABSENT so the
      // interface says "you did not grant this" instead of "it did not work".
      if (json['granted'] == false) {
        return QgConsent.fromJson({
          'state': 'ABSENT',
          'disclosure': json['disclosure'],
        });
      }
      final consent = json['consent'];
      return QgConsent.fromJson({
        'state': consent is Map ? consent['state'] : 'GRANTED',
        'grant': consent,
        'disclosure': json['disclosure'],
      });
    },
    method: 'POST',
    body: {
      'proposal_id': proposalId,
      'context_id': ?contextId,
      'request_id': _requestId(),
      ...echo,
    },
  );

  /// A per-attempt idempotency key, so a double-click cannot record two
  /// permissions and a retry is recognised as the same request.
  ///
  /// The server types this as a UUID, so it is generated in that shape rather
  /// than as an opaque string: a malformed id would be rejected as a validation
  /// error before it ever reached the idempotency check.
  static String _requestId() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant 10
    String hex(int start, int end) => bytes
        .sublist(start, end)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${hex(0, 4)}-${hex(4, 6)}-${hex(6, 8)}-${hex(8, 10)}-${hex(10, 16)}';
  }

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
