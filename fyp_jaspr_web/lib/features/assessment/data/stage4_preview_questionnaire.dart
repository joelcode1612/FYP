/// Stage 4 Section A — the fixed governed core questionnaire, preview only.
///
/// The 13 questions come from the governed CQ contract, not from this client.
/// Nothing here decides wording: [PreviewQuestion.populatedStem] is the server's
/// substitution result and is rendered verbatim.
///
/// Authority is deliberately explicit and negative. Not one of Q01–Q13 carries a
/// scientific approval, so every row reports its own [measurementStatus] and
/// [approvalState], and [PreviewQuestionnaire.fieldingAuthorized] is false. A
/// reader must not treat a rendered question as a question any respondent will
/// be asked: template population and respondent routing are separate concerns.
library;

/// A placeholder the server could not fill from the owner's declarations.
///
/// A required unresolved slot is not an error and not a respondent-facing
/// absence — it means the owner has not declared the value the wording needs.
final class UnresolvedSlot {
  const UnresolvedSlot({
    required this.token,
    required this.slot,
    required this.source,
    required this.required,
    required this.reason,
  });

  /// The bracketed text still present in the stem, e.g. `[named area]`.
  final String token;

  /// Stable slot name, e.g. `named_area`.
  final String slot;

  /// The M2 declaration or BCB field that would fill it.
  final String source;

  final bool required;
  final String reason;

  factory UnresolvedSlot.fromJson(Map<String, dynamic> json) => UnresolvedSlot(
    token: json['token'] as String? ?? '',
    slot: json['slot'] as String? ?? '',
    source: json['source'] as String? ?? '',
    required: json['required'] == true,
    reason: json['reason'] as String? ?? '',
  );
}

/// One governed core question, with the server's population result.
final class PreviewQuestion {
  const PreviewQuestion({
    required this.questionId,
    required this.stemTemplate,
    required this.populatedStem,
    required this.responseType,
    required this.questionClass,
    required this.construct,
    required this.measurementStatus,
    required this.approvalState,
    required this.populationStatus,
    required this.codes,
    required this.displayOrder,
    required this.exclusiveCodes,
    required this.maxSelections,
    required this.unresolvedSlots,
  });

  final String questionId;

  /// The governed wording exactly as recovered, placeholders intact.
  final String stemTemplate;

  /// The wording after deterministic substitution. Rendered as-is.
  final String populatedStem;

  final String responseType;
  final String questionClass;
  final String construct;

  /// The measurement-approval state carried by the governed contract. Never
  /// `APPROVED` for Q01–Q13.
  final String measurementStatus;

  /// Always `NOT_APPROVED` for the fixed core.
  final String approvalState;

  /// `COMPLETE` | `PARTIAL_UNRESOLVED` | `NO_SUBSTITUTION_REQUIRED`.
  final String populationStatus;

  final List<String> codes;
  final List<String> displayOrder;
  final List<String> exclusiveCodes;
  final int? maxSelections;
  final List<UnresolvedSlot> unresolvedSlots;

  /// True when the wording still shows a placeholder the owner must resolve.
  bool get hasUnresolvedRequiredSlot =>
      unresolvedSlots.any((slot) => slot.required);

  factory PreviewQuestion.fromJson(Map<String, dynamic> json) {
    List<String> strings(Object? raw) => raw is List
        ? [for (final value in raw) value.toString()]
        : const <String>[];
    return PreviewQuestion(
      questionId: json['question_id'] as String? ?? '',
      stemTemplate: json['stem_template'] as String? ?? '',
      populatedStem: json['populated_stem'] as String? ?? '',
      responseType: json['response_type'] as String? ?? '',
      questionClass: json['question_class'] as String? ?? '',
      construct: json['construct'] as String? ?? '',
      measurementStatus: json['measurement_status'] as String? ?? '',
      approvalState: json['approval_state'] as String? ?? '',
      populationStatus: json['population_status'] as String? ?? '',
      codes: strings(json['codes']),
      displayOrder: strings(json['display_order']),
      exclusiveCodes: strings(json['exclusive_codes']),
      maxSelections: json['max_selections'] as int?,
      unresolvedSlots: json['unresolved_slots'] is List
          ? [
              for (final row in json['unresolved_slots'] as List)
                if (row is Map)
                  UnresolvedSlot.fromJson(Map<String, dynamic>.from(row)),
            ]
          : const <UnresolvedSlot>[],
    );
  }
}

/// The whole Section A payload.
final class PreviewQuestionnaire {
  const PreviewQuestionnaire({
    required this.catalogueVersion,
    required this.authority,
    required this.questionCount,
    required this.approvedQuestionCount,
    required this.unresolvedRequiredSlotCount,
    required this.populationStatus,
    required this.populatedDigest,
    required this.fieldingAuthorized,
    required this.questions,
  });

  final String catalogueVersion;
  final String authority;
  final int questionCount;

  /// Must be 0. Rendered so a future regression is visible rather than silent.
  final int approvedQuestionCount;

  final int unresolvedRequiredSlotCount;
  final String populationStatus;
  final String populatedDigest;

  /// Always false. Section A is a preview, never fielded from here.
  final bool fieldingAuthorized;

  final List<PreviewQuestion> questions;

  factory PreviewQuestionnaire.fromJson(Map<String, dynamic> json) =>
      PreviewQuestionnaire(
        catalogueVersion: json['catalogue_version'] as String? ?? '',
        authority: json['authority'] as String? ?? '',
        questionCount: json['question_count'] as int? ?? 0,
        approvedQuestionCount: json['approved_question_count'] as int? ?? -1,
        unresolvedRequiredSlotCount:
            json['unresolved_required_slot_count'] as int? ?? -1,
        populationStatus: json['population_status'] as String? ?? '',
        populatedDigest: json['populated_digest'] as String? ?? '',
        fieldingAuthorized: json['fielding_authorized'] == true,
        questions: json['questions'] is List
            ? [
                for (final row in json['questions'] as List)
                  if (row is Map)
                    PreviewQuestion.fromJson(Map<String, dynamic>.from(row)),
              ]
            : const <PreviewQuestion>[],
      );
}
