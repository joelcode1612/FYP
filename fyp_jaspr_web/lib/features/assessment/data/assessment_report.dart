/// The typed read of `GET /api/v1/assessments/{id}/report`.
///
/// The endpoint assembles the five-stage report from what is actually stored:
/// the saved business preferences, the property listing, the analysed location
/// evidence, the persisted SHAP explanation and the deterministic requirement
/// checks. Every section is returned with an explicit availability flag and a
/// reason when it is empty — so this model keeps `available`/`reason` beside the
/// data instead of flattening them away. Nothing here invents a value: a
/// section the server marked unavailable stays unavailable in the UI.
///
/// The endpoint is read-only. It never advances a stage and never computes SHAP,
/// which is what makes it safe to call on page load.
library;

/// One `{available, data | reason}` block of the report.
final class ReportSection {
  final bool available;

  /// The block's payload: a map for object sections, a list for collections,
  /// null when the server had nothing to send.
  final Object? data;

  /// Why the block is empty. Only present when [available] is false.
  final String? reason;

  const ReportSection({
    required this.available,
    this.data,
    this.reason,
  });

  static const ReportSection empty = ReportSection(available: false);

  factory ReportSection.fromJson(Object? json) {
    if (json is! Map) return empty;
    final map = json.cast<String, dynamic>();
    return ReportSection(
      available: map['available'] == true,
      data: map['data'],
      reason: map['reason'] as String?,
    );
  }

  /// The block as an object, or null when it is not one.
  Map<String, dynamic>? get asMap => data is Map
      ? (data as Map).cast<String, dynamic>()
      : null;

  /// The block as a list of objects — the shape evidence groups arrive in.
  List<Map<String, dynamic>> get asList => data is List
      ? [
          for (final entry in data as List)
            if (entry is Map) entry.cast<String, dynamic>(),
        ]
      : const [];
}

/// One deterministic constraint check from `requirement_matching`.
final class ReportCheck {
  /// `affordability` | `floor_area` | `accessibility` | `competition_context` …
  final String key;
  final String label;

  /// `match` | `mismatch` | `unknown` | `informational`.
  final String verdict;

  /// The sentence the backend generated from the stored numbers.
  final String detail;

  const ReportCheck({
    required this.key,
    required this.label,
    required this.verdict,
    required this.detail,
  });

  factory ReportCheck.fromJson(Map<String, dynamic> json) => ReportCheck(
    key: json['key'] as String? ?? '',
    label: json['label'] as String? ?? 'Requirement check',
    verdict: json['verdict'] as String? ?? 'unknown',
    detail: json['detail'] as String? ?? '',
  );

  /// The badge wording. `unknown` is deliberately "Not verified" rather than
  /// "Failed": the backend could not evaluate it, which is not a mismatch.
  String get verdictLabel => switch (verdict) {
    'match' => 'Supported',
    'mismatch' => 'Not met',
    'informational' => 'Context only',
    _ => 'Not verified',
  };

  String get verdictTone => switch (verdict) {
    'match' => 'success',
    'mismatch' => 'danger',
    'informational' => 'neutral',
    _ => 'warning',
  };
}

/// `requirement_matching`: the supported constraint checks plus their counts.
final class RequirementMatching {
  final List<ReportCheck> checks;
  final int matched;
  final int mismatched;
  final int unknown;

  /// The backend's own note about what this section is not.
  final String note;

  const RequirementMatching({
    this.checks = const [],
    this.matched = 0,
    this.mismatched = 0,
    this.unknown = 0,
    this.note = '',
  });

  factory RequirementMatching.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const RequirementMatching();
    return RequirementMatching(
      checks: [
        for (final entry in (json['checks'] as List? ?? const []))
          if (entry is Map) ReportCheck.fromJson(entry.cast<String, dynamic>()),
      ],
      matched: (json['matched'] as num?)?.toInt() ?? 0,
      mismatched: (json['mismatched'] as num?)?.toInt() ?? 0,
      unknown: (json['unknown'] as num?)?.toInt() ?? 0,
      note: json['note'] as String? ?? '',
    );
  }

  int get total => checks.length;
}

/// The whole report document.
final class AssessmentReportPayload {
  final String assessmentId;
  final String propertyId;
  final String status;

  /// Server timestamp of this assembly — not of a frozen snapshot. The report
  /// is rebuilt on every read, so the UI must not call it a stored version.
  final String? generatedAt;
  final int requirementsVersion;

  final ReportSection questionnaire;
  final ReportSection property;
  final ReportSection listingMedia;
  final ReportSection geospatialFeatures;
  final ReportSection evidenceCategories;
  final ReportSection researchAssociation;
  final ReportSection explanation;

  final RequirementMatching requirementMatching;
  final List<String> missingInformation;

  /// `model`, `feature_set`, `explainer`, `research_only`, `score_meaning`.
  final Map<String, dynamic> modelInformation;

  /// Always false today: no server-side PDF generator is configured.
  final bool exportPdf;
  final String? exportReason;

  const AssessmentReportPayload({
    required this.assessmentId,
    required this.propertyId,
    required this.status,
    required this.generatedAt,
    required this.requirementsVersion,
    required this.questionnaire,
    required this.property,
    required this.listingMedia,
    required this.geospatialFeatures,
    required this.evidenceCategories,
    required this.researchAssociation,
    required this.explanation,
    required this.requirementMatching,
    required this.missingInformation,
    required this.modelInformation,
    required this.exportPdf,
    required this.exportReason,
  });

  factory AssessmentReportPayload.fromJson(Map<String, dynamic> json) {
    final export = (json['export'] as Map?)?.cast<String, dynamic>();
    return AssessmentReportPayload(
      assessmentId: json['assessment_id'] as String? ?? '',
      propertyId: json['property_id'] as String? ?? '',
      status: json['status'] as String? ?? 'unknown',
      generatedAt: json['generated_at'] as String?,
      requirementsVersion: (json['requirements_version'] as num?)?.toInt() ?? 0,
      questionnaire: ReportSection.fromJson(json['questionnaire']),
      property: ReportSection.fromJson(json['property']),
      listingMedia: ReportSection.fromJson(json['listing_media']),
      geospatialFeatures: ReportSection.fromJson(json['geospatial_features']),
      evidenceCategories: ReportSection.fromJson(json['evidence_categories']),
      researchAssociation: ReportSection.fromJson(json['research_association']),
      explanation: ReportSection.fromJson(json['explanation']),
      requirementMatching: RequirementMatching.fromJson(
        (json['requirement_matching'] as Map?)?.cast<String, dynamic>(),
      ),
      missingInformation: [
        for (final entry in (json['missing_information'] as List? ?? const []))
          '$entry',
      ],
      modelInformation:
          (json['model_information'] as Map?)?.cast<String, dynamic>() ??
          const {},
      exportPdf: export?['pdf'] == true,
      exportReason: export?['reason'] as String?,
    );
  }

  /// Measured evidence groups, as the report's evidence section reads them.
  List<Map<String, dynamic>> get evidenceGroups => evidenceCategories.asList;

  /// Metrics inside one evidence group that carry a real measured value.
  static int measuredMetrics(Map<String, dynamic> group) => [
    for (final metric in (group['metrics'] as List? ?? const []))
      if (metric is Map && metric['status'] == 'available' && metric['value'] != null)
        metric,
  ].length;

  static int totalMetrics(Map<String, dynamic> group) =>
      (group['metrics'] as List? ?? const []).length;
}
