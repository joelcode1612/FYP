/// Stage 5 — the composed questionnaire, decoded from the governed document.
///
/// The contract is `sitewise-questionnaire-composition/1`, served by
/// `GET /assessments/{m2_id}/stage5/composed-questionnaire`. Nothing in this
/// file decides wording, eligibility or ordering: the server composes the
/// document from the governed core plus the candidates that already carry an
/// owner approval, and this model only makes that document readable.
///
/// Three separations the model deliberately preserves:
///
/// * **Composition ≠ authority.** [ComposedQuestionnaire.compositionStatus] may
///   be `VALID` while every authority flag is false. A valid document is a
///   well-formed document, not a published one.
/// * **Empty ≠ missing.** An empty Section B is explained by
///   [ComposedQuestionnaire.unresolvedRequirements] and
///   [ComposedQuestionnaire.excludedCandidates], never by a blank list. The
///   reason codes are kept verbatim so a reader can tell "no question was ever
///   generated" from "questions exist but none is approved".
/// * **Intended ≠ answered.** An additional item may carry
///   [ComposedItem.ownerIntendedOption]. That is the entrepreneur's own
///   expectation, scoped `ENTREPRENEUR_ONLY_METADATA`. It is not a respondent
///   answer and must never be preselected in a customer-facing view.
library;

import 'package:sitewise_jaspr_web/features/assessment/data/stage4_preview_questionnaire.dart'
    show UnresolvedSlot;

/// Section keys. Exactly two sections exist and no third is expected.
abstract final class ComposedSections {
  static const fixedCore = 'A_FIXED_CORE';
  static const additional = 'B_ADDITIONAL';
}

/// Composition verdicts. `INVALID` means the document contradicts itself; it
/// never means "not authorised", which is a separate axis.
abstract final class CompositionStatus {
  static const valid = 'VALID';
  static const invalid = 'INVALID';
}

/// Section B availability, so a reader can distinguish "nothing generated" from
/// "generated but nothing approved".
abstract final class AdditionalStatus {
  static const noneEligible = 'NONE_ELIGIBLE';
  static const available = 'AVAILABLE';
}

/// Requirement codes the server reports for an incomplete document.
abstract final class RequirementCodes {
  static const slotUnresolved = 'FIXED_CORE_SLOT_UNRESOLVED';
  static const noAdditional = 'NO_ELIGIBLE_ADDITIONAL_QUESTION';
  static const validationFailed = 'QUESTIONNAIRE_VALIDATION_FAILED';
  static const noAdmittedObjective = 'NO_ADMITTED_OBJECTIVE';
}

/// Exclusion codes: the first failing eligibility predicate for a candidate.
abstract final class ExclusionCodes {
  static const notApproved = 'CANDIDATE_NOT_APPROVED';
  static const notValidated = 'CANDIDATE_NOT_VALIDATED';
  static const validationNotPass = 'CANDIDATE_VALIDATION_NOT_PASS';
  static const staleRevision = 'CANDIDATE_STALE_REVISION';
  static const wordingMissing = 'CANDIDATE_WORDING_MISSING';
  static const optionsUnusable = 'CANDIDATE_OPTIONS_UNUSABLE';
}

/// A fixed label for a requirement code.
///
/// These are *labels*, not diagnoses: the server's own `detail` sentence is
/// rendered beside them and is always preferred. An unknown code is returned
/// verbatim so a new server code becomes visible instead of being swallowed.
String describeRequirementCode(String code) => switch (code) {
  RequirementCodes.slotUnresolved =>
    'A required word in a core question has no declared value.',
  RequirementCodes.noAdditional =>
    'No additional question is eligible, so Section B is empty.',
  RequirementCodes.validationFailed =>
    'The composed document failed its own consistency check.',
  RequirementCodes.noAdmittedObjective =>
    'No research objective has been admitted for this confirmation.',
  _ => code,
};

/// A fixed label for an exclusion code. See [describeRequirementCode].
String describeExclusionCode(String code) => switch (code) {
  ExclusionCodes.notApproved =>
    'You have not approved this question for review.',
  ExclusionCodes.notValidated => 'The question has not finished validation.',
  ExclusionCodes.validationNotPass =>
    'A structural, semantic or provenance check did not pass.',
  ExclusionCodes.staleRevision =>
    'The question was written for an earlier revision of your declaration.',
  ExclusionCodes.wordingMissing => 'The question carries no wording.',
  ExclusionCodes.optionsUnusable =>
    'The question has fewer than two usable answer options.',
  _ => code,
};

/// One answer option. Fixed-core options carry only a governed code; additional
/// options carry the generator's label and ordering too.
final class ComposedOption {
  const ComposedOption({
    required this.code,
    required this.label,
    this.order,
    this.orderSource,
  });

  final String code;

  /// Empty for fixed-core options: the governed contract stores codes only, so
  /// no label is invented here.
  final String label;

  final int? order;
  final String? orderSource;

  /// What to show. Falls back to the code rather than to invented wording.
  String get display => label.trim().isEmpty ? code : label.trim();

  factory ComposedOption.fromJson(Map<String, dynamic> json) => ComposedOption(
    code: json['code'] as String? ?? '',
    label: json['label'] as String? ?? '',
    order: json['order'] is int ? json['order'] as int : null,
    orderSource: json['order_source'] as String?,
  );
}

/// One item of the composed document. Section A and Section B share this type
/// because they are rendered by the same list; [isAdditional] is the only
/// branch that matters, and it is derived from [section] rather than guessed.
final class ComposedItem {
  const ComposedItem({
    required this.itemId,
    required this.section,
    required this.displayOrder,
    required this.source,
    required this.stem,
    required this.stemTemplate,
    required this.responseFormat,
    required this.options,
    required this.unresolvedSlots,
    required this.reviewControls,
    required this.approvalState,
    required this.fieldingAuthorized,
    required this.publicationAuthorized,
    required this.scientificallyAccepted,
    required this.construct,
    required this.questionClass,
    required this.measurementStatus,
    required this.authorityToActivate,
    required this.populationStatus,
    required this.objectiveId,
    required this.objectiveAdmissionId,
    required this.measurementId,
    required this.measurementVersion,
    required this.reviewDecision,
    required this.reviewRecordedAt,
    required this.ownerIntendedOption,
    required this.ownerIntendedOptionScope,
    required this.candidateState,
    required this.structuralStatus,
    required this.semanticStatus,
    required this.provenanceStatus,
    required this.semanticBasis,
    required this.executionMode,
  });

  final String itemId;
  final String section;
  final int displayOrder;

  /// `GOVERNED_CORE` or `QG_CANDIDATE`.
  final String source;

  /// The wording as it will be read, with the server's substitution applied.
  final String stem;

  /// The governed template, placeholders intact. Null for additional items,
  /// which have no template.
  final String? stemTemplate;

  final String responseFormat;
  final List<ComposedOption> options;
  final List<UnresolvedSlot> unresolvedSlots;

  /// `NONE` for the fixed core, `PER_ITEM` for additional questions. The fixed
  /// core is not individually reviewable anywhere in this app.
  final String reviewControls;

  final String approvalState;
  final bool fieldingAuthorized;
  final bool publicationAuthorized;
  final bool scientificallyAccepted;

  // -- fixed-core-only metadata -------------------------------------------
  final String? construct;
  final String? questionClass;
  final String? measurementStatus;
  final String? authorityToActivate;
  final String? populationStatus;

  // -- additional-only metadata -------------------------------------------
  final String? objectiveId;
  final String? objectiveAdmissionId;
  final String? measurementId;
  final String? measurementVersion;

  /// `APPROVE_FOR_REVIEW` for every item that reached this document.
  final String? reviewDecision;
  final String? reviewRecordedAt;

  /// The owner's intended answer. Entrepreneur-only metadata: never a
  /// respondent answer, never preselected for a customer.
  final String? ownerIntendedOption;

  /// Always `ENTREPRENEUR_ONLY_METADATA` when present. Kept so the UI can state
  /// the scope from the payload instead of asserting it in a comment.
  final String? ownerIntendedOptionScope;

  final String? candidateState;
  final String? structuralStatus;
  final String? semanticStatus;
  final String? provenanceStatus;

  /// `VALIDATOR_PASS` or `OWNER_REVIEW` — which basis satisfied the semantic
  /// disposition. Reported rather than flattened into "PASS".
  final String? semanticBasis;

  final String? executionMode;

  bool get isAdditional => section == ComposedSections.additional;

  /// True when the wording still shows a placeholder the owner must resolve.
  bool get hasUnresolvedRequiredSlot =>
      unresolvedSlots.any((slot) => slot.required);

  /// True when this item may be individually reviewed on this screen. The
  /// fixed core never is.
  bool get isReviewable => reviewControls == 'PER_ITEM';

  /// True when the owner's intended option is present *and* correctly scoped as
  /// entrepreneur-only. If the scope is missing the value is not shown at all,
  /// because an unscoped value could be mistaken for a respondent answer.
  bool get hasScopedIntendedOption =>
      (ownerIntendedOption ?? '').trim().isNotEmpty &&
      ownerIntendedOptionScope == 'ENTREPRENEUR_ONLY_METADATA';

  factory ComposedItem.fromJson(Map<String, dynamic> json) {
    String? text(Object? raw) =>
        raw is String && raw.trim().isNotEmpty ? raw : null;
    return ComposedItem(
      itemId: json['item_id'] as String? ?? '',
      section: json['section'] as String? ?? '',
      displayOrder: json['display_order'] is int
          ? json['display_order'] as int
          : 0,
      source: json['source'] as String? ?? '',
      stem: json['stem'] as String? ?? '',
      stemTemplate: text(json['stem_template']),
      responseFormat: json['response_format'] as String? ?? '',
      options: json['options'] is List
          ? [
              for (final row in json['options'] as List)
                if (row is Map)
                  ComposedOption.fromJson(Map<String, dynamic>.from(row)),
            ]
          : const <ComposedOption>[],
      unresolvedSlots: json['unresolved_slots'] is List
          ? [
              for (final row in json['unresolved_slots'] as List)
                if (row is Map)
                  UnresolvedSlot.fromJson(Map<String, dynamic>.from(row)),
            ]
          : const <UnresolvedSlot>[],
      reviewControls: json['review_controls'] as String? ?? '',
      approvalState: json['approval_state'] as String? ?? '',
      fieldingAuthorized: json['fielding_authorized'] == true,
      publicationAuthorized: json['publication_authorized'] == true,
      scientificallyAccepted: json['scientifically_accepted'] == true,
      construct: text(json['construct']),
      questionClass: text(json['question_class']),
      measurementStatus: text(json['measurement_status']),
      authorityToActivate: text(json['authority_to_activate']),
      populationStatus: text(json['population_status']),
      objectiveId: text(json['objective_id']),
      objectiveAdmissionId: text(json['objective_admission_id']),
      measurementId: text(json['measurement_id']),
      measurementVersion: text(json['measurement_version']),
      reviewDecision: text(json['review_decision']),
      reviewRecordedAt: text(json['review_recorded_at']),
      ownerIntendedOption: text(json['owner_intended_option']),
      ownerIntendedOptionScope: text(json['owner_intended_option_scope']),
      candidateState: text(json['candidate_state']),
      structuralStatus: text(json['structural_status']),
      semanticStatus: text(json['semantic_status']),
      provenanceStatus: text(json['provenance_status']),
      semanticBasis: text(json['semantic_basis']),
      executionMode: text(json['execution_mode']),
    );
  }
}

/// One section of the document, as the server grouped it.
final class ComposedSection {
  const ComposedSection({
    required this.key,
    required this.title,
    required this.reviewControls,
    required this.itemCount,
    required this.items,
  });

  final String key;
  final String title;
  final String reviewControls;
  final int itemCount;
  final List<ComposedItem> items;

  factory ComposedSection.fromJson(Map<String, dynamic> json) =>
      ComposedSection(
        key: json['key'] as String? ?? '',
        title: json['title'] as String? ?? '',
        reviewControls: json['review_controls'] as String? ?? '',
        itemCount: json['item_count'] is int ? json['item_count'] as int : 0,
        items: json['items'] is List
            ? [
                for (final row in json['items'] as List)
                  if (row is Map)
                    ComposedItem.fromJson(Map<String, dynamic>.from(row)),
              ]
            : const <ComposedItem>[],
      );
}

/// Something the document needs before it could be published.
final class ComposedRequirement {
  const ComposedRequirement({
    required this.code,
    required this.scope,
    required this.itemId,
    required this.slot,
    required this.source,
    required this.required,
    required this.blocking,
    required this.detail,
  });

  final String code;
  final String scope;
  final String? itemId;
  final String? slot;
  final String? source;
  final bool required;

  /// True when this requirement alone prevents publication.
  final bool blocking;

  /// The server's own sentence. Always rendered in preference to the label.
  final String detail;

  String get label => describeRequirementCode(code);

  factory ComposedRequirement.fromJson(Map<String, dynamic> json) =>
      ComposedRequirement(
        code: json['code'] as String? ?? '',
        scope: json['scope'] as String? ?? '',
        itemId: json['item_id'] as String?,
        slot: json['slot'] as String?,
        source: json['source'] as String?,
        required: json['required'] == true,
        blocking: json['blocking'] == true,
        detail: json['detail'] as String? ?? '',
      );
}

/// A candidate the server refused to place in Section B, with its reason.
final class ComposedExclusion {
  const ComposedExclusion({
    required this.candidateId,
    required this.objectiveId,
    required this.reason,
    required this.assessmentRevision,
  });

  final String candidateId;
  final String? objectiveId;
  final String reason;
  final int? assessmentRevision;

  String get label => describeExclusionCode(reason);

  factory ComposedExclusion.fromJson(Map<String, dynamic> json) =>
      ComposedExclusion(
        candidateId: json['candidate_id'] as String? ?? '',
        objectiveId: json['objective_id'] as String?,
        reason: json['reason'] as String? ?? '',
        assessmentRevision: json['assessment_revision'] is int
            ? json['assessment_revision'] as int
            : null,
      );
}

/// The document's own consistency check (`QV-01..QV-10`).
final class ComposedValidation {
  const ComposedValidation({
    required this.status,
    required this.checkCount,
    required this.failureCount,
    required this.failedChecks,
  });

  final String status;
  final int checkCount;
  final int failureCount;
  final List<String> failedChecks;

  bool get passed => status == 'PASS';

  factory ComposedValidation.fromJson(Map<String, dynamic> json) =>
      ComposedValidation(
        status: json['status'] as String? ?? '',
        checkCount: json['check_count'] is int ? json['check_count'] as int : 0,
        failureCount: json['failure_count'] is int
            ? json['failure_count'] as int
            : 0,
        failedChecks: json['failed_checks'] is List
            ? [for (final row in json['failed_checks'] as List) row.toString()]
            : const <String>[],
      );
}

/// Publication readiness, stated as blockers rather than as permission.
final class ComposedPublicationReadiness {
  const ComposedPublicationReadiness({
    required this.ready,
    required this.blockers,
    required this.detail,
  });

  /// Always false today. Read from the payload so a change becomes visible.
  final bool ready;
  final List<String> blockers;
  final String detail;

  factory ComposedPublicationReadiness.fromJson(Map<String, dynamic> json) =>
      ComposedPublicationReadiness(
        ready: json['ready'] == true,
        blockers: json['blockers'] is List
            ? [for (final row in json['blockers'] as List) row.toString()]
            : const <String>[],
        detail: json['detail'] as String? ?? '',
      );
}

/// The whole composed document for one assessment at one revision.
final class ComposedQuestionnaire {
  const ComposedQuestionnaire({
    required this.contractVersion,
    required this.assessmentId,
    required this.confirmationId,
    required this.assessmentRevision,
    required this.sections,
    required this.items,
    required this.fixedCoreCount,
    required this.additionalCount,
    required this.totalCount,
    required this.approvedFixedCoreCount,
    required this.approvedAdditionalCount,
    required this.excludedCount,
    required this.compositionStatus,
    required this.populationStatus,
    required this.additionalStatus,
    required this.admittedObjectiveCount,
    required this.unresolvedRequirements,
    required this.excludedCandidates,
    required this.validation,
    required this.publicationReadiness,
    required this.fieldingAuthorized,
    required this.publicationAuthorized,
    required this.scientificallyAccepted,
    required this.customerFieldingEnabled,
    required this.reportReleaseAuthorized,
  });

  final String contractVersion;

  /// The **M2** assessment id. The document is composed against M2, and the
  /// marketplace id is not accepted by the route.
  final String assessmentId;

  final String? confirmationId;
  final int assessmentRevision;

  final List<ComposedSection> sections;
  final List<ComposedItem> items;

  final int fixedCoreCount;
  final int additionalCount;
  final int totalCount;
  final int approvedFixedCoreCount;
  final int approvedAdditionalCount;
  final int excludedCount;

  final String compositionStatus;
  final String populationStatus;
  final String additionalStatus;
  final int admittedObjectiveCount;

  final List<ComposedRequirement> unresolvedRequirements;
  final List<ComposedExclusion> excludedCandidates;
  final ComposedValidation validation;
  final ComposedPublicationReadiness publicationReadiness;

  final bool fieldingAuthorized;
  final bool publicationAuthorized;
  final bool scientificallyAccepted;
  final bool customerFieldingEnabled;
  final bool reportReleaseAuthorized;

  /// The 13 governed core questions, in server order.
  List<ComposedItem> get fixedCore => [
    for (final item in items)
      if (!item.isAdditional) item,
  ];

  /// The approved additional questions, in server order.
  List<ComposedItem> get additional => [
    for (final item in items)
      if (item.isAdditional) item,
  ];

  bool get compositionValid => compositionStatus == CompositionStatus.valid;

  /// True when every blocking requirement is absent — i.e. the document needs
  /// nothing further from the owner before it could be considered for
  /// publication. This is *not* authorisation: authority is separate and always
  /// false, so [isPublishable] stays false regardless.
  bool get hasNoBlockingRequirement =>
      !unresolvedRequirements.any((requirement) => requirement.blocking);

  /// Never true while any authority flag is false. Publication is a separate
  /// decision that this document cannot make, so this is false in every
  /// configuration this build can reach; it exists so a future change to the
  /// server's flags becomes visible rather than silently enabling a control.
  bool get isPublishable =>
      publicationReadiness.ready &&
      publicationAuthorized &&
      scientificallyAccepted &&
      fieldingAuthorized;

  /// Blocking requirements only, in server order.
  List<ComposedRequirement> get blockingRequirements => [
    for (final requirement in unresolvedRequirements)
      if (requirement.blocking) requirement,
  ];

  factory ComposedQuestionnaire.fromJson(Map<String, dynamic> json) {
    final counts = json['counts'] is Map
        ? Map<String, dynamic>.from(json['counts'] as Map)
        : const <String, dynamic>{};
    int count(String key) => counts[key] is int ? counts[key] as int : 0;
    List<Map<String, dynamic>> maps(Object? raw) => raw is List
        ? [
            for (final row in raw)
              if (row is Map) Map<String, dynamic>.from(row),
          ]
        : const <Map<String, dynamic>>[];

    final sections = [
      for (final row in maps(json['sections'])) ComposedSection.fromJson(row),
    ];
    final items = [
      for (final row in maps(json['items'])) ComposedItem.fromJson(row),
    ];

    // The section item counts are authoritative for display, but a payload that
    // disagrees with itself must not produce a silently wrong total, so the
    // flat item list wins and the discrepancy is left visible in the sections.
    final fixed = items.where((item) => !item.isAdditional).length;
    final extra = items.where((item) => item.isAdditional).length;

    return ComposedQuestionnaire(
      contractVersion: json['contract_version'] as String? ?? '',
      assessmentId: json['assessment_id'] as String? ?? '',
      confirmationId: json['confirmation_id'] as String?,
      assessmentRevision: json['assessment_revision'] is int
          ? json['assessment_revision'] as int
          : 0,
      sections: sections,
      items: items,
      fixedCoreCount: fixed,
      additionalCount: extra,
      totalCount: items.length,
      approvedFixedCoreCount: count('approved_fixed_core'),
      approvedAdditionalCount: count('approved_additional'),
      excludedCount: json['excluded_candidates'] is List
          ? (json['excluded_candidates'] as List).length
          : count('excluded_candidates'),
      compositionStatus: json['composition_status'] as String? ?? '',
      populationStatus: json['population_status'] as String? ?? '',
      additionalStatus: json['additional_status'] as String? ?? '',
      admittedObjectiveCount: json['admitted_objective_count'] is int
          ? json['admitted_objective_count'] as int
          : 0,
      unresolvedRequirements: [
        for (final row in maps(json['unresolved_requirements']))
          ComposedRequirement.fromJson(row),
      ],
      excludedCandidates: [
        for (final row in maps(json['excluded_candidates']))
          ComposedExclusion.fromJson(row),
      ],
      validation: ComposedValidation.fromJson(
        json['validation'] is Map
            ? Map<String, dynamic>.from(json['validation'] as Map)
            : const <String, dynamic>{},
      ),
      publicationReadiness: ComposedPublicationReadiness.fromJson(
        json['publication_readiness'] is Map
            ? Map<String, dynamic>.from(json['publication_readiness'] as Map)
            : const <String, dynamic>{},
      ),
      fieldingAuthorized: json['fielding_authorized'] == true,
      publicationAuthorized: json['publication_authorized'] == true,
      scientificallyAccepted: json['scientifically_accepted'] == true,
      customerFieldingEnabled: json['customer_fielding_enabled'] == true,
      reportReleaseAuthorized: json['report_release_authorized'] == true,
    );
  }
}
