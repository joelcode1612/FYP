/// The server-composed report: which sections exist and what state each is in.
///
/// Before this model existed the view decided section availability itself, from
/// three separate responses. That made the rendered page the only place the
/// composition existed, so an export or an audit read could not obtain the same
/// answer, and the A10 section contract was never consulted.
///
/// The payload is deliberately small: it carries states, reason codes and
/// source identities. It carries a count only when a slot's own admission
/// decision is `ADMITTED` — `countsDisclosed` is computed by the server, not
/// assumed here, and it is false for every response in this deployment.
library;

/// The availability vocabulary, mirrored from `services/report_composition.py`.
///
/// Kept as strings rather than an enum so an unknown state from a newer server
/// degrades to "unrecognised" instead of failing to parse the document.
class SectionAvailability {
  static const available = 'AVAILABLE';
  static const administrative = 'ADMINISTRATIVE';
  static const partial = 'PARTIAL';
  static const pending = 'PENDING_MEASUREMENT';
  static const unavailable = 'UNAVAILABLE';
  static const withheld = 'WITHHELD';
  static const notApplicable = 'NOT_APPLICABLE';
}

/// One traceable claim: what it rests on and whether it may be shown.
class ComposedEvidence {
  const ComposedEvidence({
    required this.claimId,
    required this.sourceType,
    required this.evidenceStatus,
    required this.admissionStatus,
    required this.sourceRef,
    required this.limitations,
    this.questionId,
    this.snapshotId,
  });

  final String claimId;
  final String sourceType;
  final String evidenceStatus;
  final String admissionStatus;
  final Map<String, dynamic> sourceRef;
  final List<String> limitations;
  final String? questionId;
  final String? snapshotId;

  static ComposedEvidence fromJson(Map<String, dynamic> json) => ComposedEvidence(
    claimId: '${json['claim_id'] ?? ''}',
    sourceType: '${json['source_type'] ?? ''}',
    evidenceStatus: '${json['evidence_status'] ?? ''}',
    admissionStatus: '${json['admission_status'] ?? ''}',
    sourceRef: Map<String, dynamic>.from(
      (json['source_ref'] as Map?) ?? const <String, dynamic>{},
    ),
    limitations: [
      for (final value in (json['limitations'] as List?) ?? const <dynamic>[])
        '$value',
    ],
    questionId: json['question_id'] as String?,
    snapshotId: json['measurement_snapshot_id'] as String?,
  );
}

/// One additional-research item (Section B). `admissionStage` is the stage the
/// item actually reached: a candidate *submitted for review* is not an admitted
/// research question, and an abstained candidate is not a question at all.
class AdditionalResearchItem {
  const AdditionalResearchItem({
    required this.candidateId,
    required this.stem,
    required this.measurementState,
    required this.reviewDecision,
    required this.options,
    required this.ownerIntendedOptions,
    required this.limitations,
    this.objectiveId,
    this.measurementLevel,
    this.denominator,
    this.admissionStage,
  });

  final String candidateId;
  final String stem;
  final String measurementState;
  final String? reviewDecision;
  final List<String> options;
  final List<String> ownerIntendedOptions;
  final List<String> limitations;
  final String? objectiveId;
  final String? measurementLevel;
  final String? denominator;
  final String? admissionStage;

  /// True only when a measurement for this item is admitted.
  bool get isMeasured => measurementState == 'MEASURED';

  static AdditionalResearchItem fromJson(Map<String, dynamic> json) {
    final options = <String>[];
    for (final option in (json['options'] as List?) ?? const <dynamic>[]) {
      if (option is Map) {
        options.add('${option['label'] ?? option['code'] ?? ''}');
      } else {
        options.add('$option');
      }
    }
    return AdditionalResearchItem(
      candidateId: '${json['candidate_id'] ?? ''}',
      stem: '${json['stem'] ?? ''}',
      measurementState: '${json['measurement_state'] ?? 'UNMEASURED'}',
      reviewDecision: json['review_decision'] as String?,
      options: options,
      ownerIntendedOptions: [
        for (final value
            in (json['owner_intended_options'] as List?) ?? const <dynamic>[])
          '$value',
      ],
      limitations: [
        for (final value in (json['limitations'] as List?) ?? const <dynamic>[])
          '$value',
      ],
      objectiveId: json['objective_id'] as String?,
      measurementLevel: json['measurement_level'] as String?,
      denominator: json['denominator'] as String?,
      admissionStage: json['admission_stage'] as String?,
    );
  }
}

/// One report section as the server composes it.
class ComposedSection {
  const ComposedSection({
    required this.index,
    required this.domId,
    required this.title,
    required this.purpose,
    required this.availability,
    required this.reasonCode,
    required this.detail,
    required this.evidence,
    required this.items,
    required this.a10States,
    this.measurementState,
    this.chartStatus,
    this.chartReason,
    this.findingState,
    this.coverage,
    this.additionalCounts,
    this.admittedSlots,
    this.withheldSlots,
  });

  final String index;
  final String domId;
  final String title;
  final String purpose;
  final String availability;
  final String reasonCode;
  final String detail;
  final List<ComposedEvidence> evidence;
  final List<AdditionalResearchItem> items;
  final List<Map<String, dynamic>> a10States;
  final String? measurementState;
  final String? chartStatus;
  final String? chartReason;

  /// Section 03's finding state. `null` outside section 03.
  final String? findingState;

  /// Section 08's own tally of the nine sections.
  final Map<String, dynamic>? coverage;

  /// Section 06's per-stage counts.
  final Map<String, dynamic>? additionalCounts;

  final int? admittedSlots;
  final int? withheldSlots;

  /// True when the section carries evidence the reader may see.
  bool get hasEvidence =>
      availability == SectionAvailability.available ||
      availability == SectionAvailability.partial;

  /// True when evidence exists and the report is not authorized to show it.
  bool get isWithheld => availability == SectionAvailability.withheld;

  static ComposedSection fromJson(Map<String, dynamic> json) {
    final chart = json['chart'] as Map?;
    return ComposedSection(
      index: '${json['index'] ?? ''}',
      domId: '${json['dom_id'] ?? ''}',
      title: '${json['title'] ?? ''}',
      purpose: '${json['purpose'] ?? ''}',
      availability: '${json['availability'] ?? SectionAvailability.unavailable}',
      reasonCode: '${json['reason_code'] ?? ''}',
      detail: '${json['detail'] ?? ''}',
      evidence: [
        for (final entry in (json['evidence'] as List?) ?? const <dynamic>[])
          if (entry is Map)
            ComposedEvidence.fromJson(Map<String, dynamic>.from(entry)),
      ],
      items: [
        for (final entry in (json['items'] as List?) ?? const <dynamic>[])
          if (entry is Map)
            AdditionalResearchItem.fromJson(Map<String, dynamic>.from(entry)),
      ],
      a10States: [
        for (final entry in (json['a10'] as List?) ?? const <dynamic>[])
          if (entry is Map) Map<String, dynamic>.from(entry),
      ],
      measurementState: json['measurement_state'] as String?,
      chartStatus: chart == null ? null : '${chart['status'] ?? ''}',
      chartReason: chart == null ? null : chart['reason'] as String?,
      findingState: json['finding_state'] as String?,
      coverage: json['coverage'] is Map
          ? Map<String, dynamic>.from(json['coverage'] as Map)
          : null,
      additionalCounts: json['additional_counts'] is Map
          ? Map<String, dynamic>.from(json['additional_counts'] as Map)
          : null,
      admittedSlots: (json['admitted_slots'] as num?)?.toInt(),
      withheldSlots: (json['withheld_slots'] as num?)?.toInt(),
    );
  }
}

/// The whole composed document.
class ReportComposition {
  const ReportComposition({
    required this.contractVersion,
    required this.sections,
    required this.instrument,
    required this.admission,
    required this.countsDisclosed,
    required this.counts,
    required this.revisions,
    this.assessmentRevision,
    this.reportPayload,
  });

  final String contractVersion;
  final List<ComposedSection> sections;
  final Map<String, dynamic> instrument;
  final Map<String, dynamic> admission;
  final bool countsDisclosed;

  /// How many of the nine sections are in each state. The server counts all
  /// nine, including the coverage section itself.
  final Map<String, dynamic> counts;

  /// Every revision-like number in the document, named for what it is. In
  /// particular `marketplace_requirements_form_version` is a form-schema
  /// generation marker, not a revision counter.
  final Map<String, dynamic> revisions;

  final int? assessmentRevision;

  /// The report body the composition describes, when the server embedded it.
  /// Present so one request answers both questions; `null` when it was not
  /// embedded, in which case the caller falls back to `/report`.
  final Map<String, dynamic>? reportPayload;

  ComposedSection? byIndex(String index) {
    for (final section in sections) {
      if (section.index == index) return section;
    }
    return null;
  }

  /// Never true while no admission adapter is adopted. Exposed so a renderer
  /// asks rather than assumes.
  bool get releaseAuthorized => admission['report_release_authorized'] == true;

  static ReportComposition? tryParse(dynamic json) {
    if (json is! Map) return null;
    final rawSections = json['sections'];
    if (rawSections is! List) return null;
    final sections = <ComposedSection>[];
    for (final entry in rawSections) {
      if (entry is! Map) return null;
      sections.add(ComposedSection.fromJson(Map<String, dynamic>.from(entry)));
    }
    if (sections.isEmpty) return null;
    return ReportComposition(
      contractVersion: '${json['contract_version'] ?? ''}',
      sections: sections,
      instrument: Map<String, dynamic>.from(
        (json['instrument'] as Map?) ?? const <String, dynamic>{},
      ),
      admission: Map<String, dynamic>.from(
        (json['admission'] as Map?) ?? const <String, dynamic>{},
      ),
      countsDisclosed: json['counts_disclosed'] == true,
      counts: Map<String, dynamic>.from(
        (json['counts'] as Map?) ?? const <String, dynamic>{},
      ),
      revisions: Map<String, dynamic>.from(
        (json['revisions'] as Map?) ?? const <String, dynamic>{},
      ),
      assessmentRevision: (json['assessment_revision'] as num?)?.toInt(),
      reportPayload: json['report'] is Map
          ? Map<String, dynamic>.from(json['report'] as Map)
          : null,
    );
  }
}
