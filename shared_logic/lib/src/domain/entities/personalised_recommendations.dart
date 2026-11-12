/// Entities for the Layer 2/3 personalised recommendation pipeline
/// (`POST /api/v1/recommendations/generate`, `GET .../me/generated`,
/// `GET .../{result_id}/explanation` and the Layer 1 SHAP endpoint).
///
/// These are the pipeline's OWN contracts, kept separate from the
/// requirement-fit search entities: the personalised batch is scored from
/// the entrepreneur's SAVED preferences with the versioned rule engine on
/// top of the stored PU research association score, while `/search` ranks
/// the approved+published listing feed.
///
/// Honesty rules mirrored from the API:
/// * `preferenceMatchScore` may be null (no scorable preference components);
///   unknown components are excluded by the server, never zero-filled.
/// * `puAssociationScore` is an uncalibrated research association index,
///   never a success probability.
/// * `shap` is present only when the verified 47-feature vector resolved;
///   `shapStatus.reason` explains every absence.
library;

/// One ranked result from a generated batch.
class GeneratedRecommendation {
  final String resultId;
  final String batchId;
  final String generatedAt;
  final String propertyId; // canonical text id (EP-/MD-)
  final GeneratedProperty property;
  final double puAssociationScore;
  final String? puScoreSource;
  final double? preferenceMatchScore;
  final double finalScore;
  final int? rank;
  final String? scoreBasis;
  final List<String> preferenceReasons;
  final List<String> cautions;
  final ListingRef? listingRef;

  const GeneratedRecommendation({
    required this.resultId,
    required this.batchId,
    required this.generatedAt,
    required this.propertyId,
    required this.property,
    required this.puAssociationScore,
    this.puScoreSource,
    this.preferenceMatchScore,
    required this.finalScore,
    this.rank,
    this.scoreBasis,
    this.preferenceReasons = const [],
    this.cautions = const [],
    this.listingRef,
  });

  factory GeneratedRecommendation.fromJson(Map<String, dynamic> json) {
    final propertyJson = (json['property'] as Map<String, dynamic>?) ?? const {};
    final modelJson = (json['model'] as Map<String, dynamic>?) ?? const {};
    final personalisation =
        (json['personalisation'] as Map<String, dynamic>?) ?? const {};
    final finalRec = (json['final_recommendation'] as Map<String, dynamic>?) ?? const {};
    final explanation = (json['explanation'] as Map<String, dynamic>?) ?? const {};
    final listingRefJson = propertyJson['listing_ref'];
    return GeneratedRecommendation(
      resultId: (json['result_id'] as String?) ?? '',
      batchId: (json['batch_id'] as String?) ?? '',
      generatedAt: (json['generated_at'] as String?) ?? '',
      propertyId: (json['property_id'] as String?) ?? '',
      property: GeneratedProperty.fromJson(propertyJson),
      puAssociationScore:
          _toDouble(modelJson['association_score']) ?? 0.0,
      puScoreSource: modelJson['score_source'] as String?,
      preferenceMatchScore:
          _toDouble(personalisation['preference_match_score']),
      finalScore: _toDouble(finalRec['score']) ?? 0.0,
      rank: (finalRec['rank'] as num?)?.toInt(),
      scoreBasis: finalRec['basis'] as String?,
      preferenceReasons: _toStringList(explanation['preference_reasons']),
      cautions: _toStringList(explanation['cautions']),
      listingRef: listingRefJson is Map<String, dynamic>
          ? ListingRef.fromJson(listingRefJson)
          : null,
    );
  }
}

/// The property block of one ranked result.
class GeneratedProperty {
  final String propertyId; // canonical text id
  final String title;
  final String address;
  final String city;
  final String state;
  final String propertyType;
  final double? monthlyRentalMyr;
  final double? builtUpSqft;
  final String? imageUrl;
  final Map<String, dynamic> verification;

  const GeneratedProperty({
    required this.propertyId,
    this.title = '',
    this.address = '',
    this.city = '',
    this.state = '',
    this.propertyType = '',
    this.monthlyRentalMyr,
    this.builtUpSqft,
    this.imageUrl,
    this.verification = const {},
  });

  factory GeneratedProperty.fromJson(Map<String, dynamic> json) =>
      GeneratedProperty(
        propertyId: (json['property_id'] as String?) ?? '',
        title: (json['title'] as String?) ?? '',
        address: (json['address'] as String?) ?? '',
        city: (json['city'] as String?) ?? '',
        state: (json['state'] as String?) ?? '',
        propertyType: (json['property_type'] as String?) ?? '',
        monthlyRentalMyr: _toDouble(json['monthly_rental_myr']),
        builtUpSqft: _toDouble(json['built_up_sqft']),
        imageUrl: json['image_url'] as String?,
        verification:
            (json['verification'] as Map<String, dynamic>?) ?? const {},
      );
}

/// Verified mapping to the commercial listing the detail routes navigate
/// with. `detailAvailable` mirrors the explore policy (approved + published
/// only); when it is false the canonical id stays the navigation key for
/// assessments and research evidence.
class ListingRef {
  final int listingId;
  final bool matchVerified;
  final bool detailAvailable;
  final String? detailNote;

  const ListingRef({
    required this.listingId,
    required this.matchVerified,
    required this.detailAvailable,
    this.detailNote,
  });

  factory ListingRef.fromJson(Map<String, dynamic> json) => ListingRef(
        listingId: (json['listing_id'] as num?)?.toInt() ?? 0,
        matchVerified: json['match_verified'] == true,
        detailAvailable: json['detail_available'] == true,
        detailNote: json['detail_note'] as String?,
      );
}

/// A generated batch as returned by `GET /recommendations/me/generated`.
class GeneratedBatch {
  final String batchId;
  final String? generatedAt;
  final int resultCount;
  final List<GeneratedRecommendation> results;

  const GeneratedBatch({
    required this.batchId,
    this.generatedAt,
    required this.resultCount,
    required this.results,
  });

  factory GeneratedBatch.fromJson(Map<String, dynamic> json) =>
      GeneratedBatch(
        batchId: (json['batch_id'] as String?) ?? '',
        generatedAt: json['generated_at'] as String?,
        resultCount: (json['result_count'] as num?)?.toInt() ?? 0,
        results: ((json['results'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(GeneratedRecommendation.fromJson)
            .toList(growable: false),
      );
}

/// Two separated explanations for one owned result:
/// * `preferenceReasons`/`cautions`/`components` come from the Layer 2 rule
///   engine's own calculations (SHAP is NEVER used to explain a rule);
/// * `shap` explains ONLY the research PU model's association score, when
///   the exact 47-feature vector resolved; otherwise `shapStatus` says why.
class PersonalisedExplanation {
  final String resultId;
  final String propertyId;
  final double? preferenceMatchScore;
  final double? finalScore;
  final int? rank;
  final List<String> preferenceReasons;
  final List<String> cautions;
  final Map<String, ComponentDetail> components;
  final Map<String, dynamic> coverage;
  final ShapExplanation? shap;
  final ShapStatus shapStatus;

  /// Plain-English names for the SHAP features, keyed by the exact technical
  /// feature name. Supplied by the backend so no client keeps its own copy of
  /// the 47-feature label map (and none can drift from the deployed model).
  /// Empty when SHAP is unavailable.
  final Map<String, String> featureLabels;

  const PersonalisedExplanation({
    required this.resultId,
    required this.propertyId,
    this.preferenceMatchScore,
    this.finalScore,
    this.rank,
    this.preferenceReasons = const [],
    this.cautions = const [],
    this.components = const {},
    this.coverage = const {},
    this.shap,
    required this.shapStatus,
    this.featureLabels = const {},
  });

  /// The friendly label for [feature], falling back to a de-underscored form
  /// rather than ever showing a raw column name.
  String labelFor(String feature) =>
      featureLabels[feature] ?? feature.replaceAll('_', ' ');

  factory PersonalisedExplanation.fromJson(Map<String, dynamic> json) {
    final explanation = (json['explanation'] as Map<String, dynamic>?) ?? const {};
    final personalisation =
        (json['personalisation'] as Map<String, dynamic>?) ?? const {};
    final finalRec = (json['final_recommendation'] as Map<String, dynamic>?) ?? const {};
    final componentsJson =
        (personalisation['component_details'] as Map<String, dynamic>?);
    final shapJson = explanation['shap'];
    final statusJson =
        (explanation['shap_status'] as Map<String, dynamic>?) ?? const {};
    return PersonalisedExplanation(
      resultId: (json['result_id'] as String?) ?? '',
      propertyId: (json['property_id'] as String?) ?? '',
      preferenceMatchScore:
          _toDouble(personalisation['preference_match_score']),
      finalScore: _toDouble(finalRec['score']),
      rank: (finalRec['rank'] as num?)?.toInt(),
      preferenceReasons: _toStringList(explanation['preference_reasons']),
      cautions: _toStringList(explanation['cautions']),
      components: (componentsJson ?? const {}).map(
        (name, detail) => MapEntry(
          name,
          ComponentDetail.fromJson(
            detail is Map<String, dynamic> ? detail : const {},
          ),
        ),
      ),
      coverage: (personalisation['coverage'] as Map<String, dynamic>?) ?? const {},
      shap: shapJson is Map<String, dynamic>
          ? ShapExplanation.fromJson(shapJson)
          : null,
      shapStatus: ShapStatus.fromJson(statusJson),
      featureLabels: (explanation['feature_labels'] as Map?)?.map(
            (key, value) => MapEntry('$key', '$value'),
          ) ??
          const {},
    );
  }
}

/// One rule-engine component: value (null = unknown, never zero), a plain
/// reason, an optional caution and the evidence values behind the score.
class ComponentDetail {
  final String name;
  final double? value;
  final String status; // "scored" | "unknown"
  final String reason;
  final String? caution;
  final Map<String, dynamic> evidence;

  const ComponentDetail({
    required this.name,
    this.value,
    required this.status,
    required this.reason,
    this.caution,
    this.evidence = const {},
  });

  factory ComponentDetail.fromJson(Map<String, dynamic> json) =>
      ComponentDetail(
        name: json['name'] ?? '',
        value: _toDouble(json['value']),
        status: (json['status'] as String?) ?? 'unknown',
        reason: (json['reason'] as String?) ?? '',
        caution: json['caution'] as String?,
        evidence: (json['evidence'] as Map<String, dynamic>?) ?? const {},
      );
}

/// Permutation SHAP over the research PU model. `reconstructionVerified`
/// means baseline + sum(contributions) == score was checked server-side
/// (|error| < 1e-6) before this payload was returned.
class ShapExplanation {
  final double score;
  final double baseline;
  final Map<String, double> contributions;
  final List<ShapFeatureContribution> topPositive;
  final List<ShapFeatureContribution> topNegative;
  final bool reconstructionVerified;
  final String? scoreMeaning;

  const ShapExplanation({
    required this.score,
    required this.baseline,
    required this.contributions,
    required this.topPositive,
    required this.topNegative,
    required this.reconstructionVerified,
    this.scoreMeaning,
  });

  factory ShapExplanation.fromJson(Map<String, dynamic> json) =>
      ShapExplanation(
        score: _toDouble(json['score']) ?? 0.0,
        baseline: _toDouble(json['baseline']) ?? 0.0,
        contributions: ((json['contributions'] as Map<String, dynamic>?) ?? const {})
            .map((k, v) => MapEntry(k, _toDouble(v) ?? 0.0)),
        topPositive: _contributions(json['top_positive_features']),
        topNegative: _contributions(json['top_negative_features']),
        reconstructionVerified: json['reconstruction_verified'] == true,
        scoreMeaning: json['score_meaning'] as String?,
      );
}

class ShapFeatureContribution {
  final String feature;
  final double contribution;

  const ShapFeatureContribution({
    required this.feature,
    required this.contribution,
  });

  factory ShapFeatureContribution.fromJson(Map<String, dynamic> json) =>
      ShapFeatureContribution(
        feature: (json['feature'] as String?) ?? '',
        contribution: _toDouble(json['contribution']) ?? 0.0,
      );
}

/// Why SHAP is present or absent. Absence is a normal, first-class state.
class ShapStatus {
  final bool available;
  final String? reason;
  final String? source;

  const ShapStatus({
    required this.available,
    this.reason,
    this.source,
  });

  factory ShapStatus.fromJson(Map<String, dynamic> json) => ShapStatus(
        available: json['available'] == true,
        reason: json['reason'] as String?,
        source: json['source'] as String?,
      );
}

double? _toDouble(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value);
  return null;
}

List<String> _toStringList(Object? value) => (value as List?)
        ?.whereType<Object>()
        .map((e) => e.toString())
        .toList(growable: false) ??
    const [];

List<ShapFeatureContribution> _contributions(Object? value) => (value as List?)
        ?.whereType<Map<String, dynamic>>()
        .map(ShapFeatureContribution.fromJson)
        .toList(growable: false) ??
    const [];
