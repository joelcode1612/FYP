/// Presentation-only formatting for the Full Analysis page.
///
/// Every number rendered here is already resolved by the backend (a measured
/// feature value, a signed SHAP contribution, the model output). This file
/// only turns those numbers into human-readable text: units and labels are
/// derived from the model's own feature names, never invented. A null stays
/// "Not recorded" — it is never coerced to zero.
library;

import 'package:shared_logic/shared_logic.dart';

/// Formats a resolved number with thousands separators and fixed decimals.
/// Null / non-finite renders as "Not recorded", matching the evidence panels.
String faNum(double? value, {int decimals = 0}) {
  if (value == null || !value.isFinite) return 'Not recorded';
  final fixed = value.abs().toStringAsFixed(decimals);
  final parts = fixed.split('.');
  final whole = parts[0];
  final grouped = StringBuffer();
  for (var i = 0; i < whole.length; i++) {
    if (i > 0 && (whole.length - i) % 3 == 0) grouped.write(',');
    grouped.write(whole[i]);
  }
  final sign = value < 0 ? '−' : '';
  final fraction = parts.length > 1 ? '.${parts[1]}' : '';
  return '$sign$grouped$fraction';
}

/// A signed contribution, e.g. `+0.066` / `−0.269`. Null is "Not recorded".
String faSigned(double? value, {int decimals = 3}) {
  if (value == null || !value.isFinite) return 'Not recorded';
  final sign = value >= 0 ? '+' : '−';
  return '$sign${faNum(value.abs(), decimals: decimals)}';
}

/// A research-association percentage. Null is "Not recorded", never `0%`.
String faPct(double? value, {int decimals = 1}) {
  if (value == null || !value.isFinite) return 'Not recorded';
  return '${faNum(value * 100, decimals: decimals)}%';
}

/// The unit of a model feature, derived from its name exactly as the research
/// export defines it. Features whose unit the source does not state are labelled
/// "source-reported unit" rather than guessed.
String faUnit(String feature) {
  if (feature == 'worldpop_walk_reachable_10min') return 'source-reported unit';
  if (RegExp(
    r'nearest_(transit_walk|major_road|parking_distance)_m$',
  ).hasMatch(feature)) {
    return 'm';
  }
  if (RegExp(r'isochrone_area_10min_km2$').hasMatch(feature)) return 'km²';
  if (feature.contains('road_intersection_density_')) {
    return 'intersections/km²';
  }
  if (feature.contains('road_length_density') ||
      feature.contains('osm_walkway_length_density')) {
    return 'km/km²';
  }
  if (feature.startsWith('pop_') || feature.startsWith('landscan_')) {
    return 'estimated persons';
  }
  if (RegExp(
        r'^(fnb_|cafe_|restaurant_|fast_food_|bakery_|parking_facilities_)',
      ).hasMatch(feature) ||
      feature.contains('_pois_') ||
      feature.contains('_count_') ||
      feature.contains('_stops_') ||
      feature.contains('_routes_') ||
      feature.contains('_departures_')) {
    return 'mapped count';
  }
  return 'source-reported unit';
}

const _faAliases = <String, String>{
  'pop_500m': 'WorldPop estimated population · 500 m',
  'pop_1000m': 'WorldPop estimated population · 1 km',
  'pop_2000m': 'WorldPop estimated population · 2 km',
  'pop_3000m': 'WorldPop estimated population · 3 km',
  'landscan_ambient_pop_1000m': 'LandScan ambient population · 1 km',
  'landscan_ambient_pop_2000m': 'LandScan ambient population · 2 km',
  'landscan_ambient_pop_3000m': 'LandScan ambient population · 3 km',
  'nearest_transit_walk_m': 'Nearest transit · walking distance',
  'nearest_major_road_m': 'Nearest major road · distance',
  'nearest_parking_distance_m': 'Nearest mapped parking · distance',
  'worldpop_walk_reachable_10min': 'WorldPop reachable estimate · 10-min walk',
  'walk_isochrone_area_10min_km2': '10-min walk isochrone area',
  'drive_isochrone_area_10min_km2': '10-min drive isochrone area',
  'road_intersection_density_500m_km2': 'Road intersection density · 500 m',
  'osm_walkway_length_density_500m_km_km2': 'Walkway length density · 500 m',
  'parking_facilities_500m': 'Parking facilities · 500 m',
  'parking_facilities_1km': 'Parking facilities · 1 km',
  'fnb_competitors_500m': 'F&B competitors · 500 m',
  'fnb_competitors_1000m': 'F&B competitors · 1 km',
};

const _faRadiusWords = <String, String>{
  '500m': '500 m',
  '1000m': '1 km',
  '2000m': '2 km',
  '3000m': '3 km',
};

/// A human-readable label for a model feature. Known features use the research
/// export's alias; the rest are de-snaked with radius words and acronyms tidied,
/// so the exact model name is always still recoverable from the table.
String faFeatureLabel(String feature) {
  final alias = _faAliases[feature];
  if (alias != null) return alias;
  var label = feature.replaceAll('_', ' ');
  label = label.replaceAllMapped(
    RegExp(r'\b(500m|1000m|2000m|3000m)\b'),
    (m) => _faRadiusWords[m[1]!]!,
  );
  label = label.replaceAllMapped(
    RegExp(r'\b(pois|fnb|osm)\b', caseSensitive: false),
    (m) => m[1]!.toUpperCase(),
  );
  return label;
}

/// Presentation metadata for one geospatial category: the Material Symbols
/// glyph, the two headline features, and the plain-language meaning/limitation.
/// The category keys mirror the backend's `category_of` grouping (7/14/13/3/10).
final class FaCategorySpec {
  final String icon;
  final String mainFeature;
  final String secondFeature;
  final String description;
  final String limitation;

  const FaCategorySpec({
    required this.icon,
    required this.mainFeature,
    required this.secondFeature,
    required this.description,
    required this.limitation,
  });
}

const faCategorySpecs = <String, FaCategorySpec>{
  'population': FaCategorySpec(
    icon: 'groups',
    mainFeature: 'pop_1000m',
    secondFeature: 'pop_500m',
    description:
        'WorldPop and LandScan estimate population around a property. They are '
        'not sales or pedestrian counts.',
    limitation:
        'Raster coverage and estimation method may vary. These values are not '
        'observed café customers or real-time footfall.',
  ),
  'demand_generators': FaCategorySpec(
    icon: 'storefront',
    mainFeature: 'office_pois_500m',
    secondFeature: 'retail_pois_500m',
    description:
        'Counts of offices, shops, education and healthcare facilities indicate '
        'nearby activity sources, not visitor numbers.',
    limitation:
        'Mapped POIs may be incomplete or outdated; nearby facilities are not '
        'necessarily accessible or relevant to your target customers.',
  ),
  'accessibility': FaCategorySpec(
    icon: 'directions_transit',
    mainFeature: 'nearest_transit_walk_m',
    secondFeature: 'nearest_major_road_m',
    description:
        'Transport stops, walking accessibility, road networks and modeled '
        'travel areas describe how a location connects to its surroundings.',
    limitation:
        'Distances have different network and buffer definitions. A nearby road '
        'does not guarantee direct access, parking or a legal entrance.',
  ),
  'parking': FaCategorySpec(
    icon: 'local_parking',
    mainFeature: 'parking_facilities_500m',
    secondFeature: 'parking_facilities_1km',
    description:
        'Mapped facility counts and distances describe nearby parking '
        'infrastructure, not guaranteed available spaces.',
    limitation:
        'Parking capacity, public access, pricing and actual availability '
        'require separate verification.',
  ),
  'competitors': FaCategorySpec(
    icon: 'restaurant',
    mainFeature: 'fnb_competitors_500m',
    secondFeature: 'fnb_competitors_1000m',
    description:
        'Nearby F&B outlet counts and categories describe the competitive '
        'environment, which may also indicate market activity.',
    limitation:
        'Competitor presence does not establish sales performance or whether a '
        'category is oversupplied.',
  ),
};

/// A deterministic, grounded narrative assembled from the persisted model
/// outputs. This is a template, NOT a live LLM response — the page labels it as
/// such. It makes no claim about commercial success, footfall or causality.
final class FaNarrative {
  final String intro;
  final String up;
  final String down;
  final String caution;

  const FaNarrative({
    required this.intro,
    required this.up,
    required this.down,
    required this.caution,
  });

  /// The plain-text version the Copy button writes to the clipboard.
  String get plain => [intro, up, down, caution].join('\n\n');
}

/// Builds [FaNarrative] from a validated explanation. Call only when
/// `analysis.hasValidShap` is true, so every figure reconstructs the output.
FaNarrative faNarrative(FullAnalysis analysis) {
  final explanation = analysis.explanation!;
  final output = explanation.output;
  final baseline = explanation.baseValue;
  final net = explanation.netContribution;
  final featureCount = explanation.featureCount ?? analysis.measurements.length;

  final cats = [
    for (final c in analysis.categories)
      if (c.contribution != null) (label: c.label, value: c.contribution!),
  ];
  final ups = cats.where((c) => c.value > 0).toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  final downs = cats.where((c) => c.value < 0).toList()
    ..sort((a, b) => a.value.compareTo(b.value));

  final ranked = [
    for (final m in analysis.measurements)
      if (m.shap != null) m,
  ]..sort((a, b) => b.shap!.abs().compareTo(a.shap!.abs()));
  FeatureMeasurement? strongUp;
  FeatureMeasurement? strongDown;
  for (final m in ranked) {
    if (m.shap! > 0) strongUp ??= m;
    if (m.shap! < 0) strongDown ??= m;
  }

  final intro =
      'The saved PU research model outputs ${faPct(output)} for property '
      '${analysis.propertyId}, compared with a reference SHAP baseline of '
      '${faPct(baseline)}. All $featureCount features together shifted the '
      'score by ${faSigned(net * 100, decimals: 2)} percentage points.';

  final String up;
  if (ups.isNotEmpty && strongUp != null) {
    up =
        '${ups.first.label} increased the score by '
        '${faSigned(ups.first.value * 100, decimals: 2)} percentage points. '
        'Across the full model, the strongest positive feature is '
        '${faFeatureLabel(strongUp.name)} (recorded value '
        '${faNum(strongUp.value, decimals: 3)}; SHAP '
        '${faSigned(strongUp.shap, decimals: 4)}).';
  } else {
    up =
        'No category has a positive net contribution. Some individual '
        'features may still increase the output.';
  }

  final String down;
  if (downs.isNotEmpty && strongDown != null) {
    down =
        '${downs.first.label} decreased the score by '
        '${faSigned(downs.first.value * 100, decimals: 2)} percentage points. '
        'Across the full model, the strongest negative feature is '
        '${faFeatureLabel(strongDown.name)} (recorded value '
        '${faNum(strongDown.value, decimals: 3)}; SHAP '
        '${faSigned(strongDown.shap, decimals: 4)}).';
  } else {
    down =
        'No category has a negative net contribution. Some individual '
        'features may still decrease the output.';
  }

  const caution =
      'SHAP explains this fitted model, not whether the premises will succeed '
      'commercially. Population and POI counts are not measured customer '
      'visits; property conditions and business requirements require separate '
      'checks.';

  return FaNarrative(intro: intro, up: up, down: down, caution: caution);
}
