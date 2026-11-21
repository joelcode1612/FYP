/// Research-only P/U classifier output. NOT a probability of business success.
/// Keep this separate from LocationAnalysis.suitabilityScore (a 0–100
/// decision-support score in the current UI) and from personalized rankings.
class PuPrediction {
  final String propertyId;
  final bool available;
  final double? positiveLabelAssociation;
  final String? modelVersion;
  final String? reason;
  final String scoreMeaning;
  final int? featureCount;
  final int? availableFeatures;
  final List<String> missingFeatures;
  final List<String> qualityFlags;

  const PuPrediction({
    required this.propertyId,
    required this.available,
    required this.positiveLabelAssociation,
    required this.scoreMeaning,
    this.modelVersion,
    this.reason,
    this.featureCount,
    this.availableFeatures,
    this.missingFeatures = const [],
    this.qualityFlags = const [],
  });

  /// Display as a *research association* percentage only (not success odds).
  double? get associationPercent =>
      positiveLabelAssociation == null ? null : positiveLabelAssociation! * 100;

  /// Decodes `GET /api/v1/ml/properties/{id}/prediction`. The endpoint merges
  /// the coverage envelope with the prediction, so feature counts and flags
  /// ride along. A null score is preserved exactly — never coerced to zero.
  factory PuPrediction.fromJson(Map<String, dynamic> json) => PuPrediction(
    propertyId: json['property_id'] as String? ?? '',
    available: json['available'] == true,
    positiveLabelAssociation: (json['score'] as num?)?.toDouble(),
    modelVersion: json['model_version'] as String?,
    reason: json['reason'] as String?,
    scoreMeaning:
        json['score_meaning'] as String? ??
        'research_positive_label_association_NOT_business_success_probability',
    featureCount: (json['feature_count'] as num?)?.toInt(),
    availableFeatures: (json['available_features'] as num?)?.toInt(),
    missingFeatures: [
      for (final name in (json['missing_features'] as List? ?? const []))
        '$name',
    ],
    qualityFlags: [
      for (final flag in (json['flags'] as List? ?? const [])) '$flag',
    ],
  );
}
