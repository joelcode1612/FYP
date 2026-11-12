/// Read-only client for `/api/v1/catalog/properties/{id}/insights`.
///
/// The backend answers with the *deployed* PU artifact's own output and its
/// permutation-SHAP decomposition over the property's resolved feature vector.
/// Two properties therefore never share an explanation, and nothing here is
/// computed client-side: this file only decodes and formats.
///
/// Honesty rules encoded in the types:
/// * [PropertyInsights.score] is `null` only when neither a validated stored
///   score nor live inference is available; SHAP failure does not hide a score;
/// * [LocationScore.sourceLabel] carries whether the score was stored or
///   calculated live, rather than implying every score is a fresh prediction;
/// * [InsightFactor.label] is always the plain-English label the backend
///   supplies; [InsightFactor.technical] keeps the raw column name for the
///   optional technical view and must never be the primary text;
/// * [InsightCategory.available] is `false` when no model feature maps to that
///   category, so the panel shows an unavailable state rather than zeroes.
library;

import 'auth_service.dart';

/// One feature's signed contribution to the model output.
class InsightFactor {
  /// The raw model column, e.g. `pop_500m`. For audit only.
  final String technical;

  /// The entrepreneur-facing label, e.g. "People living within 500 m".
  final String label;
  final double contribution;
  final String direction;
  final num? value;
  final String valueDisplay;
  final String unit;
  final bool isDistance;
  final String category;
  final String categoryLabel;

  const InsightFactor({
    required this.technical,
    required this.label,
    required this.contribution,
    required this.direction,
    required this.value,
    required this.valueDisplay,
    required this.unit,
    required this.isDistance,
    required this.category,
    required this.categoryLabel,
  });

  factory InsightFactor.fromJson(Map<String, dynamic> json) => InsightFactor(
    technical: '${json['technical'] ?? ''}',
    label: '${json['label'] ?? json['technical'] ?? 'Unnamed factor'}',
    contribution: (json['contribution'] as num?)?.toDouble() ?? 0,
    direction: '${json['direction'] ?? 'neutral'}',
    value: json['value'] as num?,
    valueDisplay: '${json['value_display'] ?? 'not measured'}',
    unit: '${json['unit'] ?? ''}',
    isDistance: json['is_distance'] == true,
    category: '${json['category'] ?? 'other'}',
    categoryLabel: '${json['category_label'] ?? 'Other'}',
  );

  bool get increases => contribution > 0;
  bool get decreases => contribution < 0;

  /// The contribution as a signed proportion of the largest one in a set.
  /// Used only for bar width; never displayed as a number.
  double shareOf(double maxAbs) => maxAbs <= 0 ? 0 : contribution.abs() / maxAbs;
}

/// One of the five analysis categories, with its own factors.
class InsightCategory {
  final String key;
  final String label;
  final String question;
  final String why;
  final bool available;
  final double contribution;
  final String direction;
  final int featureCount;
  final List<InsightFactor> factors;
  final String? note;

  const InsightCategory({
    required this.key,
    required this.label,
    required this.question,
    required this.why,
    required this.available,
    required this.contribution,
    required this.direction,
    required this.featureCount,
    required this.factors,
    this.note,
  });

  factory InsightCategory.fromJson(Map<String, dynamic> json) => InsightCategory(
    key: '${json['key'] ?? ''}',
    label: '${json['label'] ?? 'Category'}',
    question: '${json['question'] ?? ''}',
    why: '${json['why'] ?? ''}',
    available: json['available'] == true,
    contribution: (json['contribution'] as num?)?.toDouble() ?? 0,
    direction: '${json['direction'] ?? 'neutral'}',
    featureCount: (json['feature_count'] as num?)?.toInt() ?? 0,
    factors: [
      for (final f in (json['factors'] as List? ?? const []))
        if (f is Map<String, dynamic>) InsightFactor.fromJson(f),
    ],
    note: json['note']?.toString(),
  );
}

/// The Location Fit index, as produced by the backend.
class LocationScore {
  final String label;
  final int value;
  final int scale;
  final double raw;
  final String band;
  final String meaning;
  final String kindLabel;
  final String source;
  final String sourceLabel;

  const LocationScore({
    required this.label,
    required this.value,
    required this.scale,
    required this.raw,
    required this.band,
    required this.meaning,
    required this.kindLabel,
    required this.source,
    required this.sourceLabel,
  });

  factory LocationScore.fromJson(Map<String, dynamic> json) => LocationScore(
    label: '${json['label'] ?? 'Location Fit'}',
    value: (json['value'] as num?)?.round() ?? 0,
    scale: (json['scale'] as num?)?.round() ?? 100,
    raw: (json['raw'] as num?)?.toDouble() ?? 0,
    band: '${json['band'] ?? ''}',
    meaning: '${json['meaning'] ?? ''}',
    kindLabel: '${json['kind_label'] ?? 'Location similarity'}',
    source: '${json['source'] ?? 'unknown'}',
    sourceLabel: '${json['source_label'] ?? 'PU model output'}',
  );
}

/// The SHAP explanation block.
class InsightExplanation {
  final bool available;
  final String explainer;
  final String? modelVersion;
  final String? artifact;
  final String? artifactSha256;
  final String? backgroundSha256;
  final int featureCount;
  final double baseValue;
  final double output;
  final bool additivityOk;
  final int backgroundSize;
  final List<InsightFactor> factors;
  final List<InsightFactor> strongestSupporting;
  final List<InsightFactor> strongestLowering;

  const InsightExplanation({
    required this.available,
    required this.explainer,
    required this.modelVersion,
    required this.artifact,
    required this.artifactSha256,
    required this.backgroundSha256,
    required this.featureCount,
    required this.baseValue,
    required this.output,
    required this.additivityOk,
    required this.backgroundSize,
    required this.factors,
    required this.strongestSupporting,
    required this.strongestLowering,
  });

  factory InsightExplanation.fromJson(Map<String, dynamic> json) {
    List<InsightFactor> parse(Object? raw) => [
      for (final f in (raw as List? ?? const []))
        if (f is Map<String, dynamic>) InsightFactor.fromJson(f),
    ];
    return InsightExplanation(
      available: json['available'] == true,
      explainer: '${json['explainer'] ?? 'SHAP'}',
      modelVersion: json['model_version']?.toString(),
      artifact: json['artifact']?.toString(),
      artifactSha256: json['artifact_sha256']?.toString(),
      backgroundSha256: json['background_sha256']?.toString(),
      featureCount: (json['feature_count'] as num?)?.toInt() ?? 0,
      baseValue: (json['base_value'] as num?)?.toDouble() ?? 0,
      output: (json['output'] as num?)?.toDouble() ?? 0,
      additivityOk: json['additivity_ok'] == true,
      backgroundSize: (json['background_size'] as num?)?.toInt() ?? 0,
      factors: parse(json['factors']),
      strongestSupporting: parse(json['strongest_supporting']),
      strongestLowering: parse(json['strongest_lowering']),
    );
  }
}

/// A stated reason the backend could not produce a score.
class InsightReason {
  final String code;
  final String message;
  final List<String> missingFeatures;

  const InsightReason({
    required this.code,
    required this.message,
    this.missingFeatures = const [],
  });

  factory InsightReason.fromJson(Map<String, dynamic> json) => InsightReason(
    code: '${json['code'] ?? 'unavailable'}',
    message: '${json['message'] ?? 'Location analysis is unavailable.'}',
    missingFeatures: [
      for (final f in (json['missing_features'] as List? ?? const [])) '$f',
    ],
  );
}

/// One selectable map layer.
///
/// [mapped] is the honesty flag: `true` means the layer has stored coordinates
/// and can be drawn as pins. `false` means only counts were recorded for this
/// property, so the map must not invent positions for it.
class MapLayer {
  final String key;
  final String label;
  final String color;
  final String description;
  final bool mapped;
  final int? count500m;
  final int? count1000m;
  final double? nearestM;
  final List<MapLayerMetric> metrics;
  final String? note;

  const MapLayer({
    required this.key,
    required this.label,
    required this.color,
    required this.description,
    required this.mapped,
    required this.count500m,
    required this.count1000m,
    required this.nearestM,
    required this.metrics,
    required this.note,
  });

  factory MapLayer.fromJson(Map<String, dynamic> json) => MapLayer(
    key: '${json['key'] ?? ''}',
    label: '${json['label'] ?? 'Layer'}',
    color: '${json['color'] ?? '#1d4ed8'}',
    description: '${json['description'] ?? ''}',
    mapped: json['mapped'] == true,
    count500m: (json['count_500m'] as num?)?.toInt(),
    count1000m: (json['count_1000m'] as num?)?.toInt(),
    nearestM: (json['nearest_m'] as num?)?.toDouble(),
    metrics: [
      for (final m in (json['metrics'] as List? ?? const []))
        if (m is Map<String, dynamic>) MapLayerMetric.fromJson(m),
    ],
    note: json['note']?.toString(),
  );

  /// The count for a chosen radius, or null when it was never measured.
  int? countFor(int radiusMeters) => radiusMeters >= 1000 ? count1000m : count500m;

  /// A short "12 within 1 km" phrase, or an honest fallback.
  String countLabel(int radiusMeters) {
    final count = countFor(radiusMeters);
    if (count == null) return 'not measured';
    final where = radiusMeters >= 1000 ? '1 km' : '500 m';
    return '$count within $where';
  }
}

/// One contributing measurement behind a layer's total.
class MapLayerMetric {
  final String label;
  final String valueDisplay;

  const MapLayerMetric({required this.label, required this.valueDisplay});

  factory MapLayerMetric.fromJson(Map<String, dynamic> json) => MapLayerMetric(
    label: '${json['label'] ?? ''}',
    valueDisplay: '${json['value_display'] ?? 'not measured'}',
  );
}

/// The property's own coordinate, echoed by the backend.
class MapOrigin {
  final double lat;
  final double lon;

  const MapOrigin({required this.lat, required this.lon});

  bool get isValid =>
      lat.isFinite &&
      lon.isFinite &&
      lat >= -90 &&
      lat <= 90 &&
      lon >= -180 &&
      lon <= 180 &&
      !(lat == 0 && lon == 0);
}

/// The completed 360° panorama for a property, if one genuinely exists.
class PanoramaInfo {
  final bool available;
  final String status;
  final String? url;
  final String? reason;

  const PanoramaInfo({
    required this.available,
    required this.status,
    required this.url,
    required this.reason,
  });

  factory PanoramaInfo.fromJson(Map<String, dynamic> json) => PanoramaInfo(
    available: json['available'] == true,
    status: '${json['status'] ?? 'unavailable'}',
    url: json['url']?.toString(),
    reason: json['reason']?.toString(),
  );

  /// A URL is only usable when the backend marked it ready *and* supplied one.
  String? get readyUrl {
    final value = url?.trim() ?? '';
    return available && status == 'ready' && value.isNotEmpty ? value : null;
  }

  static const unavailable = PanoramaInfo(
    available: false,
    status: 'unavailable',
    url: null,
    reason: 'No completed 360° panorama is linked to this property.',
  );
}

/// The whole insights payload for one property.
class PropertyInsights {
  final String propertyId;
  final LocationScore? score;
  final InsightExplanation? explanation;
  final List<InsightCategory> categories;
  final String modelName;
  final String? modelVersion;
  final String? modelArtifact;
  final String? modelArtifactSha256;
  final bool? modelProductionReady;
  final List<String> modelNotes;
  final InsightReason? reason;
  final MapOrigin? origin;
  final List<MapLayer> mapLayers;
  final PanoramaInfo panorama;

  const PropertyInsights({
    required this.propertyId,
    required this.score,
    required this.explanation,
    required this.categories,
    required this.modelName,
    required this.modelVersion,
    this.modelArtifact,
    this.modelArtifactSha256,
    this.modelProductionReady,
    this.modelNotes = const [],
    this.reason,
    this.origin,
    this.mapLayers = const [],
    this.panorama = PanoramaInfo.unavailable,
  });

  factory PropertyInsights.fromJson(Map<String, dynamic> json) {
    final scoreJson = json['score'];
    final explanationJson = json['explanation'];
    final model = json['model'];
    final modelMap = model is Map<String, dynamic> ? model : const <String, dynamic>{};
    final reasonJson = json['reason'];
    final originJson = json['origin'];
    final mapJson = json['map'];
    final panoramaJson = json['panorama'];

    return PropertyInsights(
      propertyId: '${json['property_id'] ?? ''}',
      score: scoreJson is Map<String, dynamic> && scoreJson['available'] == true
          ? LocationScore.fromJson(scoreJson)
          : null,
      explanation:
          explanationJson is Map<String, dynamic> && explanationJson['available'] == true
          ? InsightExplanation.fromJson(explanationJson)
          : null,
      categories: [
        for (final c in (json['categories'] as List? ?? const []))
          if (c is Map<String, dynamic>) InsightCategory.fromJson(c),
      ],
      modelName: '${modelMap['layer1_model'] ?? modelMap['name'] ?? 'Unknown model'}',
      modelVersion: modelMap['version']?.toString(),
      modelArtifact: modelMap['artifact']?.toString(),
      modelArtifactSha256: modelMap['artifact_sha256']?.toString(),
      modelProductionReady: modelMap['production_ready'] as bool?,
      modelNotes: [
        for (final note in (modelMap['notes'] as List? ?? const []))
          if ('$note'.trim().isNotEmpty) '$note',
      ],
      reason: reasonJson is Map<String, dynamic>
          ? InsightReason.fromJson(reasonJson)
          : null,
      origin: originJson is Map<String, dynamic> &&
              originJson['lat'] is num &&
              originJson['lon'] is num
          ? MapOrigin(
              lat: (originJson['lat'] as num).toDouble(),
              lon: (originJson['lon'] as num).toDouble(),
            )
          : null,
      mapLayers: mapJson is Map<String, dynamic>
          ? [
              for (final l in (mapJson['layers'] as List? ?? const []))
                if (l is Map<String, dynamic>) MapLayer.fromJson(l),
            ]
          : const [],
      panorama: panoramaJson is Map<String, dynamic>
          ? PanoramaInfo.fromJson(panoramaJson)
          : PanoramaInfo.unavailable,
    );
  }

  /// A payload that carries only a reason — never a fabricated score.
  factory PropertyInsights.unavailable(String propertyId, String message) =>
      PropertyInsights(
        propertyId: propertyId,
        score: null,
        explanation: null,
        categories: const [],
        modelName: 'Unavailable',
        modelVersion: null,
        reason: InsightReason(code: 'request_failed', message: message),
      );

  bool get hasScore => score != null;
  bool get hasExplanation => explanation != null && explanation!.factors.isNotEmpty;

  /// The category whose factors should be shown first: the one that moved the
  /// score the most, so the panel opens on the most informative tab.
  InsightCategory? get leadCategory {
    final usable = categories.where((c) => c.available).toList();
    if (usable.isEmpty) return null;
    usable.sort((a, b) => b.contribution.abs().compareTo(a.contribution.abs()));
    return usable.first;
  }
}

/// Fetches [PropertyInsights] for a catalogue property.
class PropertyInsightsApi {
  const PropertyInsightsApi._();

  /// [catalog] is false for the legacy numeric id universe, which has no
  /// verified mapping to the research subject the model scores.
  static Future<PropertyInsights> load(String propertyId, {bool catalog = true}) async {
    if (!catalog) {
      return PropertyInsights.unavailable(
        propertyId,
        'This listing has no verified link to the location model, so no score '
        'is shown rather than an unrelated one.',
      );
    }
    try {
      final response = await WebAuth.request(
        '/api/v1/catalog/properties/${Uri.encodeComponent(propertyId)}/insights',
      );
      return PropertyInsights.fromJson(response);
    } on Object catch (error) {
      return PropertyInsights.unavailable(
        propertyId,
        'The location analysis could not be loaded. $error',
      );
    }
  }
}
