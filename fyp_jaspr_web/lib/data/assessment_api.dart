/// Typed client for the web Location Assessment Workspace.
///
/// Two backend surfaces feed it:
///
/// * `/api/v1/assessments` — the persisted web assessment record (stage
///   timestamps, saved business requirements, capability verdicts).
/// * `/api/v1/preferences/me` — the entrepreneur's stored recommendation
///   criteria, which use the same vocabulary as an assessment's requirements.
/// * `/api/v1/catalog/properties/{id}` and `.../evidence` — single-record
///   reads added for the workspace, so "this id does not exist" is a 404
///   rather than "the list happened to be paginated past it".
///
/// Every call goes through [WebAuth.requestDetailed] rather than
/// `WebAuth.request`. The workspace has to render four different failures —
/// invalid property id, unauthorized, refused stage transition and service
/// failure — and Dart cannot read `.status` off a thrown JS error, so the
/// bridge returns the outcome as data instead.
///
/// The Flutter mobile app does not use this file. Mobile assessment is a
/// data-collection workflow with its own session store; these routes are the
/// web decision-support workflow's persistence.
library;

import 'package:shared_logic/shared_logic.dart';

import 'api_property_repository.dart';
import 'auth_service.dart';

/// Why a call failed, reduced to the states the workspace must render.
enum AssessmentFailureKind {
  /// Not signed in, or signed in as a role the backend refuses. The route
  /// guard's answer is respected — no retry is offered.
  unauthorized,

  /// The id is well-formed but there is no such record.
  notFound,

  /// The record exists but the requested transition or payload is refused
  /// (409) or invalid (422). The message is the backend's own sentence.
  refused,

  /// The service did not answer. Retry is meaningful.
  serviceFailure,
}

/// A failure carried as a value, not thrown, so a caller can branch on the
/// HTTP status without parsing an error message.
final class AssessmentFailure {
  /// The real HTTP status, or null when the request never completed.
  final int? status;

  /// The backend's machine-readable `detail.code`, when it sent one.
  final String? code;

  /// Client-facing text. Always the backend's own message where one exists.
  final String message;

  const AssessmentFailure({this.status, this.code, required this.message});

  AssessmentFailureKind get kind => switch (status) {
    401 || 403 => AssessmentFailureKind.unauthorized,
    404 => AssessmentFailureKind.notFound,
    409 || 422 => AssessmentFailureKind.refused,
    // Null means the request never reached the server; a 5xx means it did and
    // the server could not answer. Both are retryable.
    _ => AssessmentFailureKind.serviceFailure,
  };

  bool get isRetryable => kind == AssessmentFailureKind.serviceFailure;
}

/// Either a parsed value or a failure. Never both, never neither.
final class ApiResult<T> {
  final T? value;
  final AssessmentFailure? failure;

  const ApiResult.success(this.value) : failure = null;
  const ApiResult.error(this.failure) : value = null;

  bool get ok => failure == null;
}

/// One workflow stage as the backend stores it.
///
/// Status is derived server-side from the persisted stage timestamp plus the
/// runtime capability probe — the client never computes it, so a stage cannot
/// be shown as complete unless a row confirms it.
final class AssessmentStage {
  /// `select_property` | `business_requirements` | `location_evidence` |
  /// `ai_explanation` | `assessment_report`.
  final String key;

  final int number;
  final String title;

  /// `complete` | `current` | `incomplete` | `unavailable`.
  final String status;

  /// ISO timestamp, null until the stage is complete.
  final String? completedAt;

  /// Why an `unavailable` stage cannot be completed — the model artifact,
  /// SHAP or the evidence row is missing.
  final String? unavailableReason;

  const AssessmentStage({
    required this.key,
    required this.number,
    required this.title,
    required this.status,
    this.completedAt,
    this.unavailableReason,
  });

  bool get isComplete => status == 'complete';
  bool get isCurrent => status == 'current';
  bool get isUnavailable => status == 'unavailable';

  factory AssessmentStage.fromJson(Map<String, dynamic> json) =>
      AssessmentStage(
        key: json['key'] as String,
        number: (json['number'] as num).toInt(),
        title: json['title'] as String,
        status: json['status'] as String,
        completedAt: json['completed_at'] as String?,
        unavailableReason: json['unavailable_reason'] as String?,
      );
}

/// Whether one decision-support capability can actually run right now.
final class AssessmentCapability {
  final bool available;
  final String? reason;
  final String? modelVersion;

  const AssessmentCapability({
    required this.available,
    this.reason,
    this.modelVersion,
  });

  factory AssessmentCapability.fromJson(Map<String, dynamic> json) =>
      AssessmentCapability(
        available: json['available'] == true,
        reason: json['reason'] as String?,
        modelVersion: json['model_version'] as String?,
      );
}

/// The three probes the backend runs per request: the trained artifact, the
/// explanation (artifact **and** SHAP) and the report generator.
final class AssessmentCapabilities {
  final AssessmentCapability model;
  final AssessmentCapability explanation;
  final AssessmentCapability report;

  const AssessmentCapabilities({
    required this.model,
    required this.explanation,
    required this.report,
  });

  factory AssessmentCapabilities.fromJson(Map<String, dynamic> json) =>
      AssessmentCapabilities(
        model: AssessmentCapability.fromJson(
          (json['model'] as Map?)?.cast<String, dynamic>() ?? const {},
        ),
        explanation: AssessmentCapability.fromJson(
          (json['explanation'] as Map?)?.cast<String, dynamic>() ?? const {},
        ),
        report: AssessmentCapability.fromJson(
          (json['report'] as Map?)?.cast<String, dynamic>() ?? const {},
        ),
      );
}

/// What the entrepreneur should do next, as the backend derived it.
final class AssessmentNextAction {
  /// `continue` | `blocked` | `view_report`.
  final String kind;

  final String stageKey;
  final String label;

  /// Set when [kind] is `blocked`: the capability or evidence that is missing.
  final String? reason;

  const AssessmentNextAction({
    required this.kind,
    required this.stageKey,
    required this.label,
    this.reason,
  });

  bool get isBlocked => kind == 'blocked';
  bool get isReport => kind == 'view_report';

  factory AssessmentNextAction.fromJson(Map<String, dynamic> json) =>
      AssessmentNextAction(
        kind: json['kind'] as String? ?? 'continue',
        stageKey: json['stage_key'] as String? ?? '',
        label: json['label'] as String? ?? '',
        reason: json['reason'] as String?,
      );
}

/// The persisted assessment record, decoded.
final class AssessmentRecord {
  final String assessmentId;
  final String propertyId;

  /// `in_progress` | `completed`.
  final String status;

  /// 1-based index of the stage the entrepreneur is on.
  final int currentStage;
  final String currentStageKey;
  final int completedStages;
  final int totalStages;

  /// Derived server-side from [completedStages] / [totalStages]; never a
  /// hardcoded constant in the UI.
  final int progressPercent;

  /// True only once `report_generated_at` is set.
  final bool reportAvailable;

  /// The saved business requirements, or null when stage 2 has not been saved.
  final Map<String, dynamic>? requirements;

  /// 0 = nothing saved, 1 = legacy criteria form, 2 = eight-question form.
  ///
  /// The workspace uses this to show a "saved before the questionnaire
  /// existed" notice instead of reinterpreting old answers.
  final int requirementsVersion;

  /// The two numbers a v1 record can honestly answer for the v2 questions.
  final Map<String, dynamic>? requirementsLegacyView;

  final List<AssessmentStage> stages;
  final AssessmentCapabilities capabilities;
  final AssessmentNextAction nextAction;

  /// The catalogue listing, decoded through the same mapper Explore uses.
  final CommercialProperty? property;

  final String? createdAt;
  final String? updatedAt;

  const AssessmentRecord({
    required this.assessmentId,
    required this.propertyId,
    required this.status,
    required this.currentStage,
    required this.currentStageKey,
    required this.completedStages,
    required this.totalStages,
    required this.progressPercent,
    required this.reportAvailable,
    required this.requirements,
    required this.requirementsVersion,
    this.requirementsLegacyView,
    required this.stages,
    required this.capabilities,
    required this.nextAction,
    required this.property,
    this.createdAt,
    this.updatedAt,
  });

  bool get isCompleted => status == 'completed';

  AssessmentStage? stageByKey(String key) {
    for (final stage in stages) {
      if (stage.key == key) return stage;
    }
    return null;
  }

  factory AssessmentRecord.fromJson(Map<String, dynamic> json) {
    final property = (json['property'] as Map?)?.cast<String, dynamic>();
    return AssessmentRecord(
      assessmentId: json['assessment_id'] as String,
      propertyId: json['property_id'] as String,
      status: json['status'] as String,
      currentStage: (json['current_stage'] as num).toInt(),
      currentStageKey: json['current_stage_key'] as String,
      completedStages: (json['completed_stages'] as num).toInt(),
      totalStages: (json['total_stages'] as num).toInt(),
      progressPercent: (json['progress_percent'] as num).toInt(),
      reportAvailable: json['report_available'] == true,
      requirements: (json['requirements'] as Map?)?.cast<String, dynamic>(),
      requirementsVersion: (json['requirements_version'] as num?)?.toInt() ?? 0,
      requirementsLegacyView:
          (json['requirements_legacy_view'] as Map?)?.cast<String, dynamic>(),
      stages: [
        for (final stage in (json['stages'] as List? ?? const []))
          AssessmentStage.fromJson((stage as Map).cast<String, dynamic>()),
      ],
      capabilities: AssessmentCapabilities.fromJson(
        (json['capabilities'] as Map?)?.cast<String, dynamic>() ?? const {},
      ),
      nextAction: AssessmentNextAction.fromJson(
        (json['next_action'] as Map?)?.cast<String, dynamic>() ?? const {},
      ),
      // A null property means the listing left the catalogue after the
      // assessment was created; the page shows that rather than a blank panel.
      property: property == null
          ? null
          : ApiPropertyRepository.fromJson(property),
      createdAt: json['created_at'] as String?,
      updatedAt: json['updated_at'] as String?,
    );
  }
}

/// One measured location-evidence figure.
final class EvidenceMetric {
  final String key;
  final String label;
  final String unit;

  /// Null exactly when [status] is `unavailable`. A mapped zero is evidence;
  /// a NULL is missing evidence, and the two are never collapsed.
  final num? value;

  /// `available` | `unavailable`.
  final String status;

  /// Coverage or nearest-competitor context from the analysis row.
  final String? note;

  const EvidenceMetric({
    required this.key,
    required this.label,
    required this.unit,
    required this.value,
    required this.status,
    this.note,
  });

  bool get isAvailable => status == 'available';

  factory EvidenceMetric.fromJson(Map<String, dynamic> json) => EvidenceMetric(
    key: json['key'] as String,
    label: json['label'] as String,
    unit: json['unit'] as String? ?? '',
    value: json['value'] as num?,
    status: json['status'] as String? ?? 'unavailable',
    note: json['note'] as String?,
  );
}

/// A themed block of metrics — competitor pressure, accessibility, catchment
/// demand, built environment.
final class EvidenceGroup {
  final String key;
  final String label;
  final List<EvidenceMetric> metrics;

  const EvidenceGroup({
    required this.key,
    required this.label,
    required this.metrics,
  });

  /// Counted from the real metric list, so a section header can say
  /// "3 of 7 measured" without guessing.
  int get availableCount => metrics.where((m) => m.isAvailable).length;
  int get missingCount => metrics.length - availableCount;

  factory EvidenceGroup.fromJson(Map<String, dynamic> json) => EvidenceGroup(
    key: json['key'] as String,
    label: json['label'] as String,
    metrics: [
      for (final metric in (json['metrics'] as List? ?? const []))
        EvidenceMetric.fromJson((metric as Map).cast<String, dynamic>()),
    ],
  );
}

/// The Stage 3 evidence payload.
final class EvidencePayload {
  final String propertyId;

  /// False when the analysis pipeline has no row for this listing at all.
  /// Distinct from a true payload whose metrics are individually unavailable.
  final bool available;

  /// The backend's own explanation when [available] is false.
  final String? reason;

  final String? analysisStatus;
  final String? referenceCoverage;
  final String? featureSnapshotAt;
  final String? inventorySnapshotAt;
  final num? dataCompletenessPct;
  final String? selfExclusionStatus;
  final String? district;
  final String? stateDosm;
  final String? coordinateQuality;

  /// `property` / `demand` / `accessibility` / `district_income` join verdicts.
  final Map<String, String?> joinStatus;

  final List<EvidenceGroup> groups;

  const EvidencePayload({
    required this.propertyId,
    required this.available,
    this.reason,
    this.analysisStatus,
    this.referenceCoverage,
    this.featureSnapshotAt,
    this.inventorySnapshotAt,
    this.dataCompletenessPct,
    this.selfExclusionStatus,
    this.district,
    this.stateDosm,
    this.coordinateQuality,
    this.joinStatus = const {},
    this.groups = const [],
  });

  /// True when the analysis row exists but every metric in it is NULL — the
  /// "zero matching records" case, as opposed to "evidence unavailable".
  bool get hasAnyMetric =>
      groups.any((group) => group.metrics.any((metric) => metric.isAvailable));

  factory EvidencePayload.fromJson(Map<String, dynamic> json) =>
      EvidencePayload(
        propertyId: json['property_id'] as String? ?? '',
        available: json['available'] == true,
        reason: json['reason'] as String?,
        analysisStatus: json['analysis_status'] as String?,
        referenceCoverage: json['reference_coverage'] as String?,
        featureSnapshotAt: json['feature_snapshot_at'] as String?,
        inventorySnapshotAt: json['inventory_snapshot_at'] as String?,
        dataCompletenessPct: json['data_completeness_pct'] as num?,
        selfExclusionStatus: json['self_exclusion_status'] as String?,
        district: json['district'] as String?,
        stateDosm: json['state_dosm'] as String?,
        coordinateQuality: json['coordinate_quality'] as String?,
        joinStatus: {
          for (final entry
              in ((json['join_status'] as Map?)?.cast<String, dynamic>() ??
                      const {})
                  .entries)
            entry.key: entry.value as String?,
        },
        groups: [
          for (final group in (json['groups'] as List? ?? const []))
            EvidenceGroup.fromJson((group as Map).cast<String, dynamic>()),
        ],
      );
}

/// History page: the rows plus the server's paging metadata.
///
/// The backend returns the full record per row, so the list reuses
/// [AssessmentRecord] rather than a second, drifting summary shape.
final class AssessmentHistory {
  final List<AssessmentRecord> items;
  final int total;

  const AssessmentHistory({required this.items, required this.total});

  factory AssessmentHistory.fromJson(Map<String, dynamic> json) =>
      AssessmentHistory(
        items: [
          for (final row in (json['data'] as List? ?? const []))
            AssessmentRecord.fromJson((row as Map).cast<String, dynamic>()),
        ],
        total: ((json['meta'] as Map?)?['total'] as num?)?.toInt() ?? 0,
      );
}

/// Maps a stored criteria payload onto the [BusinessPreferences] the ranking
/// engine reads.
///
/// One function for both surfaces on purpose: an assessment's `requirements`
/// column and `entrepreneur_preferences.preferences` hold the same vocabulary,
/// so a second copy of this mapping would be a second preference system in all
/// but name. Returns null when nothing is stored, so the caller keeps its own
/// defaults instead of being handed criteria the server never held.
BusinessPreferences? businessPreferencesFrom(Map<String, dynamic>? stored) {
  if (stored == null) return null;
  final propertyType = stored['property_type'] as String? ?? '';
  List<String> textList(String key) => [
    for (final item in (stored[key] as List? ?? const [])) '$item',
  ];
  return BusinessPreferences(
    businessType: stored['business_type'] as String? ?? '',
    // The ranking treats an empty property type as "no constraint", but 'Any'
    // is the value the form's radio group can actually show as selected.
    propertyType: propertyType.isEmpty ? 'Any' : propertyType,
    minBudgetRm: (stored['min_budget_rm'] as num?)?.toDouble() ?? 0,
    maxBudgetRm: (stored['max_budget_rm'] as num?)?.toDouble() ?? 0,
    minSizeSqft: (stored['min_size_sqft'] as num?)?.toDouble() ?? 0,
    maxSizeSqft: (stored['max_size_sqft'] as num?)?.toDouble() ?? 0,
    requirements: textList('requirements'),
    preferredAreas: textList('preferred_areas'),
    seatingModel: stored['seating_model'] as String? ?? '',
  );
}

/// The server's answer to "what criteria does this account hold".
final class StoredPreferences {
  /// The normalised payload, or null when nothing has ever been saved.
  final Map<String, dynamic>? preferences;

  /// False only when the account has no stored record at all.
  final bool saved;

  /// ISO timestamp of the last successful save, null when never saved.
  final String? updatedAt;

  const StoredPreferences({
    this.preferences,
    required this.saved,
    this.updatedAt,
  });

  factory StoredPreferences.fromJson(Map<String, dynamic> json) =>
      StoredPreferences(
        preferences: (json['preferences'] as Map?)?.cast<String, dynamic>(),
        saved: json['saved'] == true,
        updatedAt: json['updated_at'] as String?,
      );

  /// The stored criteria as the shared object the ranking reads, or null when
  /// the account has none.
  BusinessPreferences? asBusinessPreferences() =>
      businessPreferencesFrom(preferences);
}

/// One saved catalogue property as the server stores it.
final class SavedPropertyRow {
  /// The stored row's id — not used by the UI, which removes by property ref.
  final String favoriteId;

  /// The catalogue id (`EP-01051`), the same string the catalogue serves.
  final String propertyRef;

  /// ISO timestamp of when the property was saved, null if the server sent none.
  final String? createdAt;

  const SavedPropertyRow({
    required this.favoriteId,
    required this.propertyRef,
    this.createdAt,
  });

  factory SavedPropertyRow.fromJson(Map<String, dynamic> json) =>
      SavedPropertyRow(
        favoriteId: '${json['favorite_id']}',
        propertyRef: '${json['property_ref']}',
        createdAt: json['created_at'] as String?,
      );
}

/// The account's saved list, split by what still exists in the catalogue.
final class SavedProperties {
  /// Saved rows whose property ref is still in the catalogue — and, while the
  /// caller has not filtered, also the ones that are not. Check [unresolved].
  final List<SavedPropertyRow> saved;

  /// Saved ids that no longer match any catalogue row: properties delisted by
  /// a later import. Reported, never silently dropped.
  final List<String> unresolved;

  const SavedProperties({required this.saved, required this.unresolved});

  factory SavedProperties.fromJson(Map<String, dynamic> json) =>
      SavedProperties(
        saved: [
          for (final row in (json['saved'] as List? ?? const []))
            SavedPropertyRow.fromJson((row as Map).cast<String, dynamic>()),
        ],
        unresolved: [
          for (final ref in (json['unresolved'] as List? ?? const [])) '$ref',
        ],
      );

  /// The refs the UI can safely show and persist in state.
  Set<String> resolvedRefs() => {
    for (final row in saved)
      if (!unresolved.contains(row.propertyRef)) row.propertyRef,
  };
}

/// The entrepreneur's decision-support backend surface: the assessment
/// record, the stored recommendation criteria, the account's saved shortlist
/// and the catalogue reads all of them need.
///
/// Const and stateless: nothing is cached here, so a refresh always re-reads
/// the persisted record rather than a stale in-memory copy.
final class AssessmentApi {
  const AssessmentApi();

  /// Opens the workspace for [propertyId]. The backend resumes the existing
  /// record when one is present (`created: false`), which is what makes the
  /// four entry points resume instead of duplicate.
  Future<ApiResult<({AssessmentRecord assessment, bool created})>> start(
    String propertyId,
  ) => _call(
    '/api/v1/assessments/',
    method: 'POST',
    body: {'property_id': propertyId},
    parse: (json) {
      final assessment = (json['assessment'] as Map).cast<String, dynamic>();
      return (
        assessment: AssessmentRecord.fromJson(assessment),
        created: json['created'] == true,
      );
    },
  );

  /// Re-reads the persisted record without creating one. Returns a null value
  /// (not a failure) when the entrepreneur has no assessment for the property.
  Future<ApiResult<AssessmentRecord?>> byProperty(String propertyId) => _call(
    '/api/v1/assessments/by-property/$propertyId',
    parse: (json) {
      final assessment = (json['assessment'] as Map?)?.cast<String, dynamic>();
      return assessment == null ? null : AssessmentRecord.fromJson(assessment);
    },
  );

  /// The most recently updated assessment, for the dashboard's compact
  /// "Current Assessment" section. Null is the honest empty state.
  Future<ApiResult<AssessmentRecord?>> current() => _call(
    '/api/v1/assessments/me/current',
    parse: (json) {
      final assessment = (json['assessment'] as Map?)?.cast<String, dynamic>();
      return assessment == null ? null : AssessmentRecord.fromJson(assessment);
    },
  );

  Future<ApiResult<AssessmentHistory>> history({
    int limit = 50,
    int offset = 0,
  }) => _call(
    '/api/v1/assessments/me?limit=$limit&offset=$offset',
    parse: AssessmentHistory.fromJson,
  );

  /// Saves the business requirements. The server validates and normalises
  /// them; a 422 carries every problem in one message.
  Future<ApiResult<AssessmentRecord>> saveRequirements(
    String assessmentId,
    Map<String, dynamic> requirements,
  ) => _call(
    '/api/v1/assessments/$assessmentId',
    method: 'PATCH',
    body: {'requirements': requirements},
    parse: AssessmentRecord.fromJson,
  );

  /// Saves the requirements and records the stage complete in one request.
  /// The server applies them in that order, so the stage is only completed
  /// against values it has just validated.
  Future<ApiResult<AssessmentRecord>> saveRequirementsAndComplete(
    String assessmentId,
    Map<String, dynamic> requirements,
    String stageKey,
  ) => _call(
    '/api/v1/assessments/$assessmentId',
    method: 'PATCH',
    body: {'requirements': requirements, 'complete_stage': stageKey},
    parse: AssessmentRecord.fromJson,
  );

  /// Marks a stage complete. The server refuses with 409 when the stage's own
  /// precondition is not met (evidence missing, model artifact absent, a prior
  /// stage incomplete), so the client cannot fake progress.
  Future<ApiResult<AssessmentRecord>> completeStage(
    String assessmentId,
    String stageKey,
  ) => _call(
    '/api/v1/assessments/$assessmentId',
    method: 'PATCH',
    body: {'complete_stage': stageKey},
    parse: AssessmentRecord.fromJson,
  );

  /// Stage 3's evidence read. `available: false` is a successful call — it
  /// means the analysis pipeline has no row, not that the request failed.
  Future<ApiResult<EvidencePayload>> evidence(String propertyId) => _call(
    '/api/v1/catalog/properties/$propertyId/evidence',
    parse: EvidencePayload.fromJson,
  );

  Future<ApiResult<CommercialProperty>> property(String propertyId) => _call(
    '/api/v1/catalog/properties/$propertyId',
    parse: ApiPropertyRepository.fromJson,
  );

  /// Reads the persisted validated SHAP explanation for an assessment. A null
  /// value (not a failure) means Stage 4 has not produced one yet. This never
  /// calls the POST, so loading the Full Analysis page neither computes SHAP
  /// nor confirms a stage.
  Future<ApiResult<ResearchExplanation?>> explanation(String assessmentId) =>
      _call(
        '/api/v1/assessments/$assessmentId/explanation',
        parse: (json) {
          final payload = (json['explanation'] as Map?)?.cast<String, dynamic>();
          return payload == null ? null : ResearchExplanation.fromJson(payload);
        },
      );

  /// The read-only business-target evaluation for an assessment, taken from the
  /// report's deterministic `requirement_matching` section. The report endpoint
  /// assembles without advancing any stage, so this is safe on page load.
  Future<ApiResult<BusinessTargetEvaluation>> targetMatching(
    String assessmentId,
  ) => _call(
    '/api/v1/assessments/$assessmentId/report',
    parse: (json) => BusinessTargetEvaluation.fromJson(
      (json['requirement_matching'] as Map?)?.cast<String, dynamic>() ??
          const {},
    ),
  );

  /// The catalogue's real `property_type` vocabulary.
  ///
  /// Stage 2 offers only these values, so the eligibility filter can never be
  /// set to a type that matches no listing. Read from the data rather than
  /// hardcoded in the UI.
  Future<ApiResult<List<String>>> propertyTypes() => _call(
    '/api/v1/catalog/property-types',
    parse: (json) => [
      for (final row in (json['data'] as List? ?? const []))
        (row as Map)['value'] as String,
    ],
  );

  /// The entrepreneur's stored recommendation criteria.
  ///
  /// `saved: false` with a null payload is a successful read, not a failure: it
  /// means nothing has been stored yet, so the form shows its own defaults
  /// rather than criteria the server invented.
  Future<ApiResult<StoredPreferences>> preferences() =>
      _call('/api/v1/preferences/me', parse: StoredPreferences.fromJson);

  /// Merges [changes] over the stored criteria and persists the result.
  ///
  /// The response is the normalised payload the server actually wrote, so a
  /// success notice is only ever shown against persisted values. A 422 carries
  /// every validation problem in one message and writes nothing.
  Future<ApiResult<StoredPreferences>> savePreferences(
    Map<String, dynamic> changes,
  ) => _call(
    '/api/v1/preferences/me',
    method: 'PATCH',
    body: {'preferences': changes},
    parse: StoredPreferences.fromJson,
  );

  /// The signed-in account's saved catalogue properties.
  ///
  /// `unresolved` reports saved ids the catalogue no longer contains
  /// (delisted by a later import) so the caller can exclude them from the
  /// shortlist rather than render dead entries.
  Future<ApiResult<SavedProperties>> savedProperties() =>
      _call('/api/v1/saved-properties/me', parse: SavedProperties.fromJson);

  /// Saves one catalogue property to the account. Idempotent server-side:
  /// saving an already-saved id returns the existing row instead of a
  /// duplicate.
  Future<ApiResult<SavedPropertyRow>> saveProperty(String propertyRef) => _call(
    '/api/v1/saved-properties/',
    method: 'POST',
    body: {'property_ref': propertyRef},
    parse: SavedPropertyRow.fromJson,
  );

  /// Removes one catalogue property from the account's saved list.
  Future<ApiResult<void>> unsaveProperty(String propertyRef) => _callVoid(
    '/api/v1/saved-properties/me/${Uri.encodeComponent(propertyRef)}',
  );

  /// Like [_call] for endpoints that answer 204 with no body (DELETE).
  static Future<ApiResult<void>> _callVoid(
    String path, {
    String method = 'DELETE',
  }) async {
    final response = await WebAuth.requestDetailed(path, method: method);
    if (response['ok'] != true) {
      return ApiResult<void>.error(
        AssessmentFailure(
          status: response['status'] as int?,
          code: response['code'] as String?,
          message:
              response['message'] as String? ??
              'The data service could not complete this request.',
        ),
      );
    }
    return const ApiResult<void>.success(null);
  }

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
              'The data service could not complete this request.',
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
      // A malformed payload is reported, not papered over: showing zeros here
      // would be exactly the fabrication the workspace must avoid.
      return ApiResult<T>.error(
        AssessmentFailure(
          code: 'unexpected_response',
          message: 'The server response could not be read: $error',
        ),
      );
    }
  }
}
