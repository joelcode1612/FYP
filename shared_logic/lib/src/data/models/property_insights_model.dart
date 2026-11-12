/// Location insights for one catalogue property: the deployed model's score,
/// its genuine permutation-SHAP factors, the five entrepreneur-facing
/// categories, and the map layers recorded for the property.
///
/// Source: `GET /api/v1/catalog/properties/{id}/insights`.
///
/// Honesty contract, mirrored from the backend:
/// * [PropertyInsightsModel.score] is `null` when the backend could not produce
///   one, so the UI shows "Score not available" instead of a placeholder;
/// * [InsightFactorModel.label] is always prose; [InsightFactorModel.technical]
///   keeps the raw column for audit and must never be the primary text;
/// * [MapLayerModel.mapped] is `false` for layers recorded only as counts, so
///   the map never invents a position for them;
/// * [PanoramaModel.readyUrl] is non-null only for a genuinely completed
///   stitching job.
library;

/// One feature's signed contribution to the model output.
class InsightFactorModel {
  final String technical;
  final String label;
  final double contribution;
  final String direction;
  final String valueDisplay;
  final String category;
  final String categoryLabel;

  const InsightFactorModel({
    required this.technical,
    required this.label,
    required this.contribution,
    required this.direction,
    required this.valueDisplay,
    required this.category,
    required this.categoryLabel,
  });

  factory InsightFactorModel.fromJson(Map<String, dynamic> json) => InsightFactorModel(
    technical: '${json['technical'] ?? ''}',
    label: '${json['label'] ?? json['technical'] ?? 'Unnamed factor'}',
    contribution: (json['contribution'] as num?)?.toDouble() ?? 0,
    direction: '${json['direction'] ?? 'neutral'}',
    valueDisplay: '${json['value_display'] ?? 'not measured'}',
    category: '${json['category'] ?? 'other'}',
    categoryLabel: '${json['category_label'] ?? 'Other'}',
  );

  bool get increases => contribution > 0;
}

/// One of the five analysis categories, with its own factors.
class InsightCategoryModel {
  final String key;
  final String label;
  final String question;
  final String why;
  final bool available;
  final double contribution;
  final int featureCount;
  final List<InsightFactorModel> factors;
  final String? note;

  const InsightCategoryModel({
    required this.key,
    required this.label,
    required this.question,
    required this.why,
    required this.available,
    required this.contribution,
    required this.featureCount,
    required this.factors,
    this.note,
  });

  factory InsightCategoryModel.fromJson(Map<String, dynamic> json) => InsightCategoryModel(
    key: '${json['key'] ?? ''}',
    label: '${json['label'] ?? 'Category'}',
    question: '${json['question'] ?? ''}',
    why: '${json['why'] ?? ''}',
    available: json['available'] == true,
    contribution: (json['contribution'] as num?)?.toDouble() ?? 0,
    featureCount: (json['feature_count'] as num?)?.toInt() ?? 0,
    factors: [
      for (final f in (json['factors'] as List? ?? const []))
        if (f is Map<String, dynamic>) InsightFactorModel.fromJson(f),
    ],
    note: json['note']?.toString(),
  );
}

/// The Location Fit index, as produced by the backend.
class LocationScoreModel {
  final String label;
  final int value;
  final int scale;
  final String band;
  final String meaning;
  final String kindLabel;

  const LocationScoreModel({
    required this.label,
    required this.value,
    required this.scale,
    required this.band,
    required this.meaning,
    required this.kindLabel,
  });

  factory LocationScoreModel.fromJson(Map<String, dynamic> json) => LocationScoreModel(
    label: '${json['label'] ?? 'Location Fit'}',
    value: (json['value'] as num?)?.round() ?? 0,
    scale: (json['scale'] as num?)?.round() ?? 100,
    band: '${json['band'] ?? ''}',
    meaning: '${json['meaning'] ?? ''}',
    kindLabel: '${json['kind_label'] ?? 'Location similarity'}',
  );
}

/// One selectable map layer. [mapped] false means counts only, no positions.
class MapLayerModel {
  final String key;
  final String label;
  final String color;
  final bool mapped;
  final int? count500m;
  final int? count1000m;
  final double? nearestM;
  final String? note;

  const MapLayerModel({
    required this.key,
    required this.label,
    required this.color,
    required this.mapped,
    required this.count500m,
    required this.count1000m,
    required this.nearestM,
    this.note,
  });

  factory MapLayerModel.fromJson(Map<String, dynamic> json) => MapLayerModel(
    key: '${json['key'] ?? ''}',
    label: '${json['label'] ?? 'Layer'}',
    color: '${json['color'] ?? '#1d4ed8'}',
    mapped: json['mapped'] == true,
    count500m: (json['count_500m'] as num?)?.toInt(),
    count1000m: (json['count_1000m'] as num?)?.toInt(),
    nearestM: (json['nearest_m'] as num?)?.toDouble(),
    note: json['note']?.toString(),
  );

  /// "12 within 1 km", or an honest fallback when nothing was measured.
  String countLabel({int radiusMeters = 500}) {
    final count = radiusMeters >= 1000 ? count1000m : count500m;
    if (count == null) return 'not measured';
    return '$count within ${radiusMeters >= 1000 ? '1 km' : '500 m'}';
  }
}

/// The property's completed 360° panorama, if one genuinely exists.
class PanoramaModel {
  final bool available;
  final String status;
  final String? url;
  final String? reason;

  const PanoramaModel({
    required this.available,
    required this.status,
    required this.url,
    required this.reason,
  });

  factory PanoramaModel.fromJson(Map<String, dynamic> json) => PanoramaModel(
    available: json['available'] == true,
    status: '${json['status'] ?? 'unavailable'}',
    url: json['url']?.toString(),
    reason: json['reason']?.toString(),
  );

  String? get readyUrl {
    final value = url?.trim() ?? '';
    return available && status == 'ready' && value.isNotEmpty ? value : null;
  }
}

/// The whole insights payload for one property.
class PropertyInsightsModel {
  final String propertyId;
  final LocationScoreModel? score;
  final List<InsightFactorModel> factors;
  final List<InsightCategoryModel> categories;
  final List<MapLayerModel> mapLayers;
  final PanoramaModel panorama;
  final String modelName;
  final String? modelVersion;
  final String? reasonMessage;

  const PropertyInsightsModel({
    required this.propertyId,
    required this.score,
    required this.factors,
    required this.categories,
    required this.mapLayers,
    required this.panorama,
    required this.modelName,
    required this.modelVersion,
    this.reasonMessage,
  });

  factory PropertyInsightsModel.fromJson(Map<String, dynamic> json) {
    final scoreJson = json['score'];
    final explanation = json['explanation'];
    final explanationMap =
        explanation is Map<String, dynamic> ? explanation : const <String, dynamic>{};
    final model = json['model'];
    final modelMap = model is Map<String, dynamic> ? model : const <String, dynamic>{};
    final map = json['map'];
    final panorama = json['panorama'];
    final reason = json['reason'];

    return PropertyInsightsModel(
      propertyId: '${json['property_id'] ?? ''}',
      score: scoreJson is Map<String, dynamic> && scoreJson['available'] == true
          ? LocationScoreModel.fromJson(scoreJson)
          : null,
      factors: [
        for (final f in (explanationMap['factors'] as List? ?? const []))
          if (f is Map<String, dynamic>) InsightFactorModel.fromJson(f),
      ],
      categories: [
        for (final c in (json['categories'] as List? ?? const []))
          if (c is Map<String, dynamic>) InsightCategoryModel.fromJson(c),
      ],
      mapLayers: map is Map<String, dynamic>
          ? [
              for (final l in (map['layers'] as List? ?? const []))
                if (l is Map<String, dynamic>) MapLayerModel.fromJson(l),
            ]
          : const [],
      panorama: panorama is Map<String, dynamic>
          ? PanoramaModel.fromJson(panorama)
          : const PanoramaModel(
              available: false,
              status: 'unavailable',
              url: null,
              reason: 'No completed 360° panorama is linked to this property.',
            ),
      modelName: '${modelMap['layer1_model'] ?? modelMap['name'] ?? 'Unknown model'}',
      modelVersion: modelMap['version']?.toString(),
      reasonMessage:
          reason is Map<String, dynamic> ? reason['message']?.toString() : null,
    );
  }

  bool get hasScore => score != null;

  /// The category that moved the score the most, so the panel opens on the
  /// most informative tab.
  InsightCategoryModel? get leadCategory {
    final usable = categories.where((c) => c.available).toList();
    if (usable.isEmpty) return null;
    usable.sort((a, b) => b.contribution.abs().compareTo(a.contribution.abs()));
    return usable.first;
  }
}
