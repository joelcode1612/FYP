/// Diagnostic for whether the property's stored data satisfy the saved PU model.
class PuFeatureCoverage {
  final String propertyId;
  final int featureCount;
  final int availableFeatures;
  final List<String> missingFeatures;
  final List<String> qualityFlags;
  final String? subjectId;

  /// `catalog` or `rental` — which id universe the backend resolved.
  final String? source;

  /// The exact resolved measurement per model feature. A null entry means
  /// "not recorded"; it is never collapsed to zero. Keys are the model's own
  /// feature names, so a consumer never pairs a value with the wrong feature.
  final Map<String, double?> values;

  /// Per-feature provenance (`schema.table.column`), as the backend resolved
  /// it. Absent for a feature that did not resolve.
  final Map<String, String> valueSources;

  /// The analysis row's own status (e.g. `COMPLETED`), null when unknown.
  final String? analysisStatus;

  const PuFeatureCoverage({
    required this.propertyId,
    required this.featureCount,
    required this.availableFeatures,
    required this.missingFeatures,
    required this.qualityFlags,
    this.subjectId,
    this.source,
    this.values = const {},
    this.valueSources = const {},
    this.analysisStatus,
  });

  bool get ready =>
      featureCount > 0 &&
      availableFeatures == featureCount &&
      missingFeatures.isEmpty;

  /// Decodes `GET /api/v1/ml/properties/{id}/coverage`.
  factory PuFeatureCoverage.fromJson(Map<String, dynamic> json) =>
      PuFeatureCoverage(
        propertyId: json['property_id'] as String? ?? '',
        featureCount: (json['feature_count'] as num?)?.toInt() ?? 0,
        availableFeatures: (json['available_features'] as num?)?.toInt() ?? 0,
        missingFeatures: [
          for (final name in (json['missing_features'] as List? ?? const []))
            '$name',
        ],
        qualityFlags: [
          for (final flag in (json['flags'] as List? ?? const [])) '$flag',
        ],
        subjectId: json['subject_id'] as String?,
        source: json['source'] as String?,
        values: {
          for (final entry
              in ((json['values'] as Map?)?.cast<String, dynamic>() ?? const {})
                  .entries)
            entry.key: (entry.value as num?)?.toDouble(),
        },
        valueSources: {
          for (final entry
              in ((json['value_sources'] as Map?)?.cast<String, dynamic>() ??
                      const {})
                  .entries)
            entry.key: '${entry.value}',
        },
        analysisStatus: json['analysis_status'] as String?,
      );
}
