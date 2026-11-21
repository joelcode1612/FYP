/// PROJECT1 research-question candidate.
///
/// This file is the ONE place the Jaspr web app and the Flutter app agree on:
///
/// * what a candidate payload means (parsing, incl. the `candidate` vs `qg`
///   key and the `options` vs `response_codes`/`response_options` shapes),
/// * which review decisions a version's status allows,
/// * how a prepare/revise response is classified (validated answer,
///   abstention, conflict, budget exhausted, unavailable), and
/// * the entrepreneur-facing wording for a missing business fact.
///
/// Framework-free and transport-free: `ApiM2Repository` owns HTTP. Neither app
/// may re-implement these rules, because the two must never disagree about
/// whether a candidate is still reviewable.
///
/// AUTHORITY: a candidate is a PROPOSAL. `FieldAuthority` is read from the
/// server and defaults to "no authority" when absent, so a missing flag can
/// never be rendered as approval. Nothing here grants scientific acceptance,
/// fielding, publication or report release.
library;

import '../../core/errors/app_failure.dart';

final _uuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
);

/// True for a canonical lowercase UUID.
bool isCandidateVersionId(Object? value) =>
    value is String && _uuid.hasMatch(value);

Map<String, dynamic> _asMap(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : const <String, dynamic>{};

List<String> _asStringList(Object? value) => value is List
    ? [
        for (final item in value)
          if (item is String && item.isNotEmpty) item,
      ]
    : const [];

/// One answer option of a candidate question.
final class ResearchAnswerOption {
  final String code;
  final String label;
  const ResearchAnswerOption(this.code, this.label);

  @override
  bool operator ==(Object other) =>
      other is ResearchAnswerOption && other.code == code && other.label == label;

  @override
  int get hashCode => Object.hash(code, label);

  /// Reads either shape the backend emits:
  ///
  /// * read/history: `[{"code": "A", "label": "...", "eligible": true}, ...]`
  /// * prepare: `response_codes` + `response_options` (two parallel lists)
  ///
  /// An option without a code or a label is dropped rather than rendered as a
  /// blank row: the reviewer must never see an option they cannot identify.
  static List<ResearchAnswerOption> parse(
    Object? options, {
    Object? codes,
    Object? labels,
  }) {
    final parsed = <ResearchAnswerOption>[];
    if (options is List) {
      for (final raw in options) {
        final map = _asMap(raw);
        final code = map['code'];
        final label = map['label'];
        if (code is String && code.isNotEmpty && label is String) {
          parsed.add(ResearchAnswerOption(code, label));
        }
      }
      if (parsed.isNotEmpty) return parsed;
    }
    if (codes is List && labels is List) {
      final count = codes.length < labels.length ? codes.length : labels.length;
      for (var i = 0; i < count; i++) {
        final code = codes[i];
        final label = labels[i];
        if (code is String && code.isNotEmpty && label is String) {
          parsed.add(ResearchAnswerOption(code, label));
        }
      }
    }
    return parsed;
  }
}

/// The server's authority flags for a candidate, as received.
///
/// Every getter defaults to `false`. `scientifically_adopted` and
/// `fielding_authorized` come from the engine's `field_authority` block; the
/// rest come from the contract-wide `no_authority()` block. A payload that
/// omits them is treated as "no authority", never as approval.
final class FieldAuthority {
  final bool scientificallyAdopted;
  final bool fieldingAuthorized;
  final bool scientificAcceptance;
  final bool ownerAuthorization;
  final bool publicationAuthorized;
  final bool reportReleaseAuthorized;

  const FieldAuthority({
    this.scientificallyAdopted = false,
    this.fieldingAuthorized = false,
    this.scientificAcceptance = false,
    this.ownerAuthorization = false,
    this.publicationAuthorized = false,
    this.reportReleaseAuthorized = false,
  });

  const FieldAuthority.none() : this();

  factory FieldAuthority.fromJson(Object? json) {
    final map = _asMap(json);
    bool flag(String key) => map[key] == true;
    return FieldAuthority(
      scientificallyAdopted: flag('scientifically_adopted'),
      fieldingAuthorized: flag('fielding_authorized'),
      scientificAcceptance: flag('scientific_acceptance'),
      ownerAuthorization: flag('owner_authorization'),
      publicationAuthorized: flag('publication_authorized'),
      reportReleaseAuthorized: flag('report_release_authorized'),
    );
  }

  /// True when the generated fields are still only a proposal. This is what
  /// drives the visible "proposal — not confirmed" marker.
  bool get isProposal => !scientificallyAdopted && !fieldingAuthorized;

  /// Any authority at all, used to render a warning instead of silently
  /// claiming the fields are proposals when the server says otherwise.
  bool get grantsAnyAuthority =>
      scientificallyAdopted ||
      fieldingAuthorized ||
      scientificAcceptance ||
      ownerAuthorization ||
      publicationAuthorized ||
      reportReleaseAuthorized;

  /// The exact flags, for display next to the proposal marker. Never phrased
  /// as an approval.
  String get flagSummary => [
    'scientifically_adopted: $scientificallyAdopted',
    'fielding_authorized: $fieldingAuthorized',
  ].join(' · ');
}

/// A candidate version's review state.
///
/// [unknown] is deliberately distinct from [pending]: an unrecognised code
/// must NOT re-open review actions on a version the server has already
/// decided.
enum ResearchDecision {
  pending,
  approveForReview,
  reject,
  requestRevision,
  unknown;

  static ResearchDecision fromCode(Object? code) => switch (code) {
    'PENDING' => ResearchDecision.pending,
    'APPROVE_FOR_REVIEW' => ResearchDecision.approveForReview,
    'REJECT' => ResearchDecision.reject,
    'REQUEST_REVISION' => ResearchDecision.requestRevision,
    null => ResearchDecision.pending,
    _ => ResearchDecision.unknown,
  };

  /// What the server stores. [pending] and [unknown] are not writable.
  String get wireCode => switch (this) {
    pending => 'PENDING',
    approveForReview => 'APPROVE_FOR_REVIEW',
    reject => 'REJECT',
    requestRevision => 'REQUEST_REVISION',
    unknown => 'UNKNOWN',
  };

  String get label => switch (this) {
    pending => 'Awaiting your decision',
    approveForReview => 'Approved for further review',
    reject => 'Rejected',
    requestRevision => 'Revision requested',
    unknown => 'Unrecognised status',
  };
}

/// The three decisions the owner-review route accepts.
enum ResearchReviewAction { approveForReview, reject, requestRevision }

extension ResearchReviewActionWire on ResearchReviewAction {
  String get wireCode => switch (this) {
    ResearchReviewAction.approveForReview => 'APPROVE_FOR_REVIEW',
    ResearchReviewAction.reject => 'REJECT',
    ResearchReviewAction.requestRevision => 'REQUEST_REVISION',
  };

  String get label => switch (this) {
    ResearchReviewAction.approveForReview => 'Approve for further review',
    ResearchReviewAction.reject => 'Reject',
    ResearchReviewAction.requestRevision => 'Request revision',
  };

  /// Every decision needs a rationale: the route declares
  /// `rationale: Field(min_length=1)`. For a revision it is the reason the
  /// child question must address.
  bool get requiresRationale => true;
}

/// Which decisions the UI may offer for a version.
///
/// A decided version is terminal. Asking for a revision does not reopen the
/// parent: it produces a CHILD version (see [canGenerateRevision]).
List<ResearchReviewAction> reviewActionsFor(ResearchDecision decision) =>
    decision == ResearchDecision.pending
    ? const [
        ResearchReviewAction.approveForReview,
        ResearchReviewAction.reject,
        ResearchReviewAction.requestRevision,
      ]
    : const [];

/// A child version may only be generated from a version whose terminal
/// decision was REQUEST_REVISION. The server enforces this too; the UI uses it
/// to decide whether to show the action, not to grant it.
bool canGenerateRevision(ResearchDecision decision) =>
    decision == ResearchDecision.requestRevision;

/// One persisted candidate version.
final class ResearchCandidate {
  final String version;
  final String? objectiveId;
  final String? objective;
  final String question;
  final List<ResearchAnswerOption> options;
  final String? supersedes;
  final ResearchDecision decision;
  final String? rationale;
  final String? reviewerId;
  final String? recordedAt;
  final FieldAuthority fieldAuthority;
  final Map<String, dynamic>? admission;

  /// The engine's generated fields, exactly as received (read-only).
  ///
  /// Kept raw because the payload grows with the engine contract; the typed
  /// getters below name only the keys this UI renders. A key that is absent
  /// yields null/empty, never a placeholder sentence.
  final Map<String, dynamic> fields;

  const ResearchCandidate({
    required this.version,
    required this.question,
    this.objectiveId,
    this.objective,
    this.options = const [],
    this.supersedes,
    this.decision = ResearchDecision.pending,
    this.rationale,
    this.reviewerId,
    this.recordedAt,
    this.fieldAuthority = const FieldAuthority.none(),
    this.admission,
    this.fields = const {},
  });

  String? _string(String key) {
    final value = fields[key];
    return value is String && value.trim().isNotEmpty ? value : null;
  }

  List<String> _strings(String key) => _asStringList(fields[key]);

  /// How the engine read the objective. A proposal, not a finding.
  String? get constructInterpretation => _string('construct_interpretation');

  String? get referencePeriod => _string('reference_period');

  String? get measurementDescription => _string('measurement_description');

  String? get denominatorSpecification => _string('denominator_specification');

  List<String> get limitations => _strings('limitations');

  List<String> get unresolvedAssumptions => _strings('unresolved_assumptions');

  List<String> get declaredMissingFacts => _strings('missing_business_facts');

  String? get justification => _string('justification');

  /// `POST .../qg-candidate` and `POST .../revision` answer.
  ///
  /// The payload nests the engine output. The documented key is `candidate`;
  /// `qg` is accepted as a fallback so a contract rename cannot blank the
  /// screen, but neither is guessed: a body with no question fails parsing.
  factory ResearchCandidate.fromPrepare(Map<String, dynamic> body) {
    final version = body['version'];
    if (!isCandidateVersionId(version)) {
      throw const FormatException(
        'The prepared candidate has no verifiable version.',
      );
    }
    final qg = _asMap(body['candidate'] ?? body['qg']);
    final question = qg['question'];
    return ResearchCandidate(
      version: version as String,
      objectiveId: qg['objective_id'] is String
          ? qg['objective_id'] as String
          : null,
      question: question is String ? question : '',
      options: ResearchAnswerOption.parse(
        qg['options'],
        codes: qg['response_codes'],
        labels: qg['response_options'],
      ),
      decision: ResearchDecision.pending,
      fieldAuthority: FieldAuthority.fromJson(body['field_authority']),
      admission: body['admission'] is Map
          ? _asMap(body['admission'])
          : null,
      fields: Map<String, dynamic>.unmodifiable(qg),
    );
  }

  /// `GET /research-questions/{version}` answer.
  factory ResearchCandidate.fromRead(Map<String, dynamic> body) {
    final version = body['version'];
    if (!isCandidateVersionId(version)) {
      throw const FormatException(
        'The stored candidate has no verifiable version.',
      );
    }
    final question = body['question'];
    return ResearchCandidate(
      version: version as String,
      objectiveId: body['objective_id'] is String
          ? body['objective_id'] as String
          : null,
      objective: body['objective'] is String ? body['objective'] as String : null,
      question: question is String ? question : '',
      options: ResearchAnswerOption.parse(body['options']),
      supersedes: body['supersedes'] is String
          ? body['supersedes'] as String
          : null,
      decision: ResearchDecision.fromCode(body['status'] ?? body['decision']),
      rationale: body['rationale'] is String
          ? body['rationale'] as String
          : null,
      reviewerId: body['reviewer_id'] is String
          ? body['reviewer_id'] as String
          : null,
      recordedAt: body['recorded_at'] is String
          ? body['recorded_at'] as String
          : null,
      fieldAuthority: FieldAuthority.fromJson(body['field_authority']),
      admission: body['admission'] is Map ? _asMap(body['admission']) : null,
      // The read projection carries the persisted row, not the full engine
      // draft; the typed getters simply return null for keys it omits.
      fields: Map<String, dynamic>.unmodifiable(body),
    );
  }

  /// One entry of `GET /research-objectives/{id}/research-questions`.
  factory ResearchCandidate.fromHistory(Map<String, dynamic> entry) {
    final version = entry['version'];
    if (!isCandidateVersionId(version)) {
      throw const FormatException(
        'A stored candidate version could not be verified.',
      );
    }
    final question = entry['question'];
    return ResearchCandidate(
      version: version as String,
      question: question is String ? question : '',
      options: ResearchAnswerOption.parse(entry['options']),
      supersedes: entry['supersedes'] is String
          ? entry['supersedes'] as String
          : null,
      decision: ResearchDecision.fromCode(entry['status'] ?? entry['decision']),
      rationale: entry['rationale'] is String
          ? entry['rationale'] as String
          : null,
      reviewerId: entry['reviewer_id'] is String
          ? entry['reviewer_id'] as String
          : null,
      recordedAt: entry['recorded_at'] is String
          ? entry['recorded_at'] as String
          : null,
    );
  }
}

/// Every version of one objective, oldest generation first.
final class ResearchCandidateHistory {
  final String objectiveId;
  final String objective;
  final List<ResearchCandidate> versions;

  const ResearchCandidateHistory({
    required this.objectiveId,
    required this.objective,
    required this.versions,
  });

  factory ResearchCandidateHistory.fromJson(Map<String, dynamic> body) {
    final objectiveId = body['objective_id'];
    if (!isCandidateVersionId(objectiveId)) {
      throw const FormatException(
        'The candidate history is not bound to a research objective.',
      );
    }
    final raw = body['versions'];
    if (raw is! List) {
      throw const FormatException('The candidate history has no version list.');
    }
    return ResearchCandidateHistory(
      objectiveId: objectiveId as String,
      objective: body['objective'] is String
          ? body['objective'] as String
          : '',
      versions: [
        for (final entry in raw)
          ResearchCandidate.fromHistory(_asMap(entry)),
      ],
    );
  }
}

/// What one prepare/revise call produced.
///
/// An abstention is a VALID answer (it names the confirmed facts that are
/// missing), not a failure — it gets its own kind so the UI can say "what we
/// still need to know" instead of showing an error.
enum CandidateOutcomeKind {
  validated,
  abstention,
  conflict,
  budgetExhausted,
  unavailable,
}

final class CandidatePrepareOutcome {
  final CandidateOutcomeKind kind;
  final String? code;
  final ResearchCandidate? candidate;
  final List<String> missingBusinessFacts;
  final String? abstentionDecision;
  final List<Map<String, dynamic>> attempts;
  final Map<String, dynamic>? admission;

  const CandidatePrepareOutcome._({
    required this.kind,
    this.code,
    this.candidate,
    this.missingBusinessFacts = const [],
    this.abstentionDecision,
    this.attempts = const [],
    this.admission,
  });

  /// A 200 body: `VALIDATED_OUTPUT` or `VALID_ABSTENTION`.
  factory CandidatePrepareOutcome.fromAnswer(Map<String, dynamic> body) {
    final status = body['status'];
    if (status == 'VALIDATED_OUTPUT') {
      return CandidatePrepareOutcome._(
        kind: CandidateOutcomeKind.validated,
        candidate: ResearchCandidate.fromPrepare(body),
        attempts: _attempts(body['attempts']),
        admission: body['admission'] is Map ? _asMap(body['admission']) : null,
      );
    }
    if (status == 'VALID_ABSTENTION') {
      final qg = _asMap(body['candidate'] ?? body['qg']);
      final facts = _asStringList(
        body['missing_business_facts'] ?? qg['missing_business_facts'],
      );
      return CandidatePrepareOutcome._(
        kind: CandidateOutcomeKind.abstention,
        code: 'VALID_ABSTENTION',
        missingBusinessFacts: facts,
        abstentionDecision: qg['decision'] is String
            ? qg['decision'] as String
            : 'ABSTAIN_NEEDS_REVIEW',
        attempts: _attempts(body['attempts']),
        admission: body['admission'] is Map ? _asMap(body['admission']) : null,
      );
    }
    // A 200 the route did not document. Never render it as a candidate.
    return CandidatePrepareOutcome._(
      kind: CandidateOutcomeKind.unavailable,
      code: body['code'] is String ? body['code'] as String : 'UNEXPECTED_STATUS',
    );
  }

  /// A transport refusal, mapped from the documented statuses.
  ///
  /// 409 -> conflict, 429 -> budget exhausted, anything else (503, 404, a
  /// transport failure with no status) -> unavailable. 401/403 must be
  /// rethrown by the repository so the app's normal sign-in handling runs.
  factory CandidatePrepareOutcome.fromFailure(AppFailure failure) =>
      CandidatePrepareOutcome._(
        kind: switch (failure.statusCode) {
          409 => CandidateOutcomeKind.conflict,
          429 => CandidateOutcomeKind.budgetExhausted,
          _ => CandidateOutcomeKind.unavailable,
        },
        code: failure.backendCode,
      );

  bool get hasCandidate =>
      kind == CandidateOutcomeKind.validated && candidate != null;

  bool get isAbstention => kind == CandidateOutcomeKind.abstention;

  static List<Map<String, dynamic>> _attempts(Object? raw) => raw is List
      ? [
          for (final item in raw)
            if (item is Map) Map<String, dynamic>.from(item),
        ]
      : const [];
}

/// Entrepreneur-facing wording for a prepare/revise conflict.
///
/// The codes come from `qg_candidate.py` (`CONFLICT_CODES`) and
/// `qg_candidate_service.py`; an unknown code keeps the generic sentence so no
/// client invents a cause.
String candidateConflictExplanation(String? code) => switch (code) {
  'QG_CONTEXT_REVISION_STALE' ||
  'QG_CONTEXT_CONFIRMATION_MISMATCH' ||
  'QG_CONTEXT_OBJECTIVE_MISMATCH' ||
  'F01_CONTEXT_CHANGED_SINCE_ADMISSION' =>
    'Your research state changed since this screen loaded. Reload the '
        'objective and prepare again. Nothing was stored.',
  'QG_CANDIDATE_REVISION_NOT_REQUESTED' =>
    'A new version can only be generated after you request a revision on this '
        'candidate.',
  'QG_CANDIDATE_REVISION_UNCHANGED' =>
    'The revision reproduced the previous question exactly, so no new version '
        'was created. Nothing was stored.',
  'BCB_CONFIRMATION_REQUIRED' || 'UNCERTAINTY_NOT_CONFIRMED' =>
    'The confirmed business understanding for this revision is not available. '
        'Confirm the objective again before preparing a question.',
  'MODEL_STAGE_ALREADY_RESERVED' =>
    'Another question is already being prepared for this objective. Wait for '
        'it to finish, then reload.',
  _ =>
    'The request conflicts with the current research state. Reload before '
        'continuing. Nothing was stored.',
};

/// Heading and body for a refused prepare/revise, shared by both apps so the
/// two screens cannot describe the same 409/429/503 differently.
({String title, String body}) candidateRefusalCopy(
  CandidatePrepareOutcome outcome,
) => switch (outcome.kind) {
  CandidateOutcomeKind.conflict => (
    title: 'Your research state changed',
    body: candidateConflictExplanation(outcome.code),
  ),
  CandidateOutcomeKind.budgetExhausted => (
    title: 'Model attempt budget exhausted',
    body:
        'The authorized attempt budget for this objective is used up, so no '
        'further question was generated. Nothing was stored.',
  ),
  _ => (
    title: 'No question was produced',
    body:
        'The question engine is not available right now, so nothing was '
        'generated or stored. This is a service condition, not a verdict on '
        'your objective.',
  ),
};

/// Plain-language "what we still need to know" text for a missing fact.
///
/// Codes are the engine's declared `MISSING_FACT_CODES`. An unrecognised code
/// is shown verbatim rather than guessed at.
String missingBusinessFactLabel(String code) => switch (code) {
  'PRICE' => 'The price you will actually pay (rent, deposit and lease terms)',
  'PRODUCT' => 'Exactly what you will sell',
  'PACKAGE_SIZE' => 'The package or portion size you will offer',
  'SERVICE_FORMAT' => 'How the product is served (dine-in, takeaway, delivery)',
  'POPULATION' => 'The customer population you are asking about',
  'REFERENCE_PERIOD' => 'The time period the question should refer to',
  'LOCATION' => 'The exact location the question should refer to',
  'OBJECTIVE' => 'The decision this question is meant to inform',
  'OTHER' => 'A business fact the question still needs',
  _ => code,
};

/// The sentence both apps show above a generated candidate. It is deliberately
/// not "approved", "validated scientifically" or "ready to field".
const String candidateProposalNotice =
    'This is a proposal generated from your confirmed business facts. It is '
    'not a confirmed fact, not a scientifically adopted question and not '
    'authorized for customer fielding.';

/// Shown when the server refuses an owner decision because no pending review
/// assignment exists. The UI never decides this itself.
const String candidateReviewAssignmentNotice =
    'A decision is recorded only when the server has a current pending review '
    'assignment for you on this version. If it refuses, nothing was changed.';
