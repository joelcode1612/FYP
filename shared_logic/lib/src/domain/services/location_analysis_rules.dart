import '../entities/location_intelligence.dart';
import '../entities/sitewise_records.dart';

/// The derivation rules behind one location reading: which band a figure falls
/// into, what the factor is called, and what evidence sentence explains it.
///
/// This is the business half of the old `ApiLocationIntelligenceRepository`;
/// the transport half stayed there. The two are split so a threshold change
/// never means touching a network call, and so the rules are reachable without
/// a client at all.
///
/// Every value below is a presentation band over a number the server already
/// computed. No score is recomputed here and none of it is a verified
/// commercial-success probability — the research formulas live in Python
/// (`backend/src/sitewise/services/explore_service.py`), so Dart cannot drift
/// from them by re-deriving a figure. A payload without backing data yields no
/// factor rather than an invented one.
abstract final class LocationAnalysisRules {
  static String rating(double score) {
    if (score >= 75) return 'Strong';
    if (score >= 60) return 'Good';
    if (score >= 45) return 'Moderate';
    return 'Weak';
  }

  /// Presentation bands for F&B competition density. These are fixed
  /// display thresholds chosen for readability — NOT model thresholds.
  static (String, String) competitionRating(int count500m) {
    if (count500m <= 15) return ('Strong', 'Positive');
    if (count500m <= 40) return ('Moderate', 'Neutral');
    return ('Weak', 'Risk');
  }

  static (String, String) populationRating(double? pop1km) {
    if (pop1km == null) return ('Moderate', 'Neutral');
    if (pop1km >= 50000) return ('Strong', 'Positive');
    if (pop1km >= 15000) return ('Good', 'Positive');
    if (pop1km >= 5000) return ('Moderate', 'Neutral');
    return ('Weak', 'Risk');
  }

  /// Display order of the measurement groups. Mirrors the backend category
  /// keys in `expanded64_enrichment.CATEGORIES`.
  static const measurementGroupOrder = <String>[
    'population',
    'age',
    'socioeconomic',
    'residential',
    'demand',
    'competition',
    'transit',
    'network',
    'parking',
  ];

  static const measurementGroupTitles = <String, String>{
    'population': 'Nearby population',
    'age': 'Population by age',
    'socioeconomic': 'Household and income',
    'residential': 'Residential surroundings',
    'demand': 'Nearby demand generators',
    'competition': 'Food and beverage competition',
    'transit': 'Public transport',
    'network': 'Road, walking and driving access',
    'parking': 'Parking',
  };

  /// Every displayed feature: backend key, human label, unit. The unit is what
  /// makes a number readable — a density in `km/km²` is a different statement
  /// from a count of buildings.
  static const measurementRows = <String, List<(String, String, String)>>{
    'population': [
      ('pop_500m', 'Population · 500 m', 'people'),
      ('pop_1000m', 'Population · 1 km', 'people'),
      ('pop_2000m', 'Population · 2 km', 'people'),
      ('pop_3000m', 'Population · 3 km', 'people'),
    ],
    'age': [
      ('pop_age_0_14_500m', 'Age 0–14 · 500 m', 'people'),
      ('pop_age_15_24_500m', 'Age 15–24 · 500 m', 'people'),
      ('pop_age_25_34_500m', 'Age 25–34 · 500 m', 'people'),
      ('pop_age_35_49_500m', 'Age 35–49 · 500 m', 'people'),
      ('pop_age_50_64_500m', 'Age 50–64 · 500 m', 'people'),
      ('pop_age_65_plus_500m', 'Age 65+ · 500 m', 'people'),
      ('pop_age_0_14_1km', 'Age 0–14 · 1 km', 'people'),
      ('pop_age_15_24_1km', 'Age 15–24 · 1 km', 'people'),
      ('pop_age_25_34_1km', 'Age 25–34 · 1 km', 'people'),
      ('pop_age_35_49_1km', 'Age 35–49 · 1 km', 'people'),
      ('pop_age_50_64_1km', 'Age 50–64 · 1 km', 'people'),
      ('pop_age_65_plus_1km', 'Age 65+ · 1 km', 'people'),
    ],
    'residential': [
      ('residential_building_count_500m', 'Residential buildings · 500 m', ''),
      ('residential_building_count_1000m', 'Residential buildings · 1 km', ''),
      (
        'residential_building_density_500m_km2',
        'Residential building density · 500 m',
        'buildings/km²',
      ),
      (
        'residential_building_density_1000m_km2',
        'Residential building density · 1 km',
        'buildings/km²',
      ),
      (
        'residential_footprint_coverage_500m_pct',
        'Residential footprint coverage · 500 m',
        '%',
      ),
      (
        'residential_footprint_coverage_1000m_pct',
        'Residential footprint coverage · 1 km',
        '%',
      ),
      (
        'residential_landuse_coverage_500m_pct',
        'Residential land-use coverage · 500 m',
        '%',
      ),
      (
        'residential_landuse_coverage_1000m_pct',
        'Residential land-use coverage · 1 km',
        '%',
      ),
    ],
    'demand': [
      ('office_pois_500m', 'Offices · 500 m', ''),
      ('office_pois_1000m', 'Offices · 1 km', ''),
      ('schools_count_500m', 'Schools · 500 m', ''),
      ('schools_count_1000m', 'Schools · 1 km', ''),
      (
        'universities_colleges_count_500m',
        'Universities and colleges · 500 m',
        '',
      ),
      (
        'universities_colleges_count_1000m',
        'Universities and colleges · 1 km',
        '',
      ),
      ('retail_pois_500m', 'Retail outlets · 500 m', ''),
      ('retail_pois_1000m', 'Retail outlets · 1 km', ''),
      ('malls_count_500m', 'Malls · 500 m', ''),
      ('malls_count_1000m', 'Malls · 1 km', ''),
      ('hospitals_count_500m', 'Hospitals · 500 m', ''),
      ('hospitals_count_1000m', 'Hospitals · 1 km', ''),
      ('supermarkets_count_500m', 'Supermarkets · 500 m', ''),
      ('supermarkets_count_1000m', 'Supermarkets · 1 km', ''),
    ],
    'competition': [
      ('fnb_competitors_500m', 'F&B competitors · 500 m', ''),
      ('fnb_competitors_1000m', 'F&B competitors · 1 km', ''),
      ('cafe_count_500m', 'Cafés · 500 m', ''),
      ('cafe_count_1000m', 'Cafés · 1 km', ''),
      ('restaurant_count_500m', 'Restaurants · 500 m', ''),
      ('restaurant_count_1000m', 'Restaurants · 1 km', ''),
      ('fast_food_count_500m', 'Fast food · 500 m', ''),
      ('fast_food_count_1000m', 'Fast food · 1 km', ''),
      (
        'bakery_dessert_beverage_count_500m',
        'Bakeries, dessert and beverage · 500 m',
        '',
      ),
      (
        'bakery_dessert_beverage_count_1000m',
        'Bakeries, dessert and beverage · 1 km',
        '',
      ),
    ],
    'transit': [
      ('nearest_transit_walk_m', 'Nearest transit stop (walking)', 'm'),
      ('transit_stops_500m_walk', 'Transit stops · 500 m walking', ''),
      ('transit_stops_1km_walk', 'Transit stops · 1 km walking', ''),
      (
        'weekday_transit_routes_1km_walk',
        'Weekday transit routes · 1 km walking',
        '',
      ),
      (
        'weekday_departures_500m_walk_am',
        'Weekday morning departures · 500 m walking',
        '',
      ),
    ],
    'network': [
      ('nearest_major_road_m', 'Nearest major road', 'm'),
      (
        'road_intersection_density_500m_km2',
        'Road intersection density · 500 m',
        'intersections/km²',
      ),
      ('road_length_density_500m_km_km2', 'Road density · 500 m', 'km/km²'),
      (
        'osm_walkway_length_density_500m_km_km2',
        'Walkway density · 500 m',
        'km/km²',
      ),
      ('road_length_density_1km_km_km2', 'Road density · 1 km', 'km/km²'),
      (
        'walk_isochrone_area_10min_km2',
        'Walkable area · 10 min',
        'km²',
      ),
      (
        'worldpop_walk_reachable_10min',
        'Population reachable on foot · 10 min',
        'people',
      ),
      (
        'drive_isochrone_area_10min_km2',
        'Drivable area · 10 min',
        'km²',
      ),
    ],
    'parking': [
      ('parking_facilities_500m', 'Parking facilities · 500 m', ''),
      ('parking_facilities_1km', 'Parking facilities · 1 km', ''),
      ('nearest_parking_distance_m', 'Nearest parking', 'm'),
    ],
  };

  /// District-level socio-economic rows, read from the backend
  /// `district_context` block rather than from a feature value. Each is a DOSM
  /// district statistic — never a property-level measurement.
  static const _districtRows = <(String, String, String, String)>[
    ('income_median', 'Median household income (district)', 'RM/month', 'income'),
    ('income_mean', 'Mean household income (district)', 'RM/month', 'income'),
    ('expenditure_mean', 'Mean household expenditure (district)', 'RM/month', 'income'),
    ('gini', 'Income inequality, Gini (district)', '', 'ratio'),
    ('poverty', 'Poverty rate (district)', '%', 'rate'),
  ];

  static double? _number(dynamic value) {
    if (value is num) {
      final asDouble = value.toDouble();
      return asDouble.isFinite ? asDouble : null;
    }
    if (value is String) return double.tryParse(value);
    return null;
  }

  /// Builds the grouped measurement view from the backend
  /// `location_measurements` block.
  ///
  /// Returns an empty list when the backend sent no block at all, so a
  /// catalogue reference with no property record does not render 64 rows of
  /// "not measured". When a block IS present every row is returned with its
  /// own state, so one unavailable feature never hides its neighbours.
  static List<LocationMeasurementGroup> measurementGroups(
    Map<String, dynamic>? block,
  ) {
    if (block == null) return const [];
    final values = (block['feature_values'] as Map?) ?? const {};
    final states = (block['feature_states'] as Map?) ?? const {};
    final sources = (block['feature_sources'] as Map?) ?? const {};
    final methods = (block['feature_methods'] as Map?) ?? const {};
    final categories = (block['categories'] as Map?) ?? const {};
    final district = (block['district_context'] as Map?) ?? const {};

    final groups = <LocationMeasurementGroup>[];
    for (final key in measurementGroupOrder) {
      if (key == 'socioeconomic') {
        final rows = <LocationMeasurement>[
          for (final (field, label, unit, kind) in _districtRows)
            if (district[field] != null)
              LocationMeasurement(
                key: 'district_$field',
                label: label,
                unit: unit,
                value: _number(district[field]),
                state: 'validated',
                source: [
                  district['district'],
                  district['state'],
                ].whereType<Object>().map((v) => '$v').join(', '),
                method: kind == 'income'
                    ? 'DOSM district household statistics'
                    : 'DOSM district household statistics',
              ),
        ];
        if (rows.isNotEmpty) {
          groups.add(
            LocationMeasurementGroup(
              key: key,
              title: measurementGroupTitles[key]!,
              status: 'current',
              rows: List.unmodifiable(rows),
            ),
          );
        }
        continue;
      }
      final definition = measurementRows[key];
      if (definition == null) continue;
      final category = categories[key];
      final categoryMap = category is Map ? category : const {};
      final rows = <LocationMeasurement>[
        for (final (name, label, unit) in definition)
          LocationMeasurement(
            key: name,
            label: label,
            unit: unit,
            value: _number(values[name]),
            state: '${states[name] ?? (values[name] == null ? 'unavailable' : 'validated')}',
            source: sources[name]?.toString(),
            method: methods[name]?.toString(),
          ),
      ];
      groups.add(
        LocationMeasurementGroup(
          key: key,
          title: measurementGroupTitles[key]!,
          status: '${categoryMap['status'] ?? (rows.any((r) => r.measured) ? 'current' : 'not_calculated')}',
          reason: categoryMap['reason']?.toString(),
          rows: List.unmodifiable(rows),
        ),
      );
    }
    return List.unmodifiable(groups);
  }

  /// Maps the analysis payload to the business-language [LocationAnalysis].
  static LocationAnalysis analyse(
    String propertyId,
    Map<String, dynamic> data,
  ) {
    final geo = data['geospatial_features'] as Map<String, dynamic>?;
    final counts =
        data['competitor_counts'] as Map<String, dynamic>? ?? const {};
    final research = data['research_link'] as Map<String, dynamic>?;
    final population = data['population'] as Map<String, dynamic>?;
    // Measured surroundings. Absent for references that have no property
    // record yet; present-but-empty when the property has coordinates but has
    // not been measured, which the UI states explicitly.
    final measurementBlock =
        data['location_measurements'] as Map<String, dynamic>?;
    final groups = measurementGroups(measurementBlock);

    // Use the precomputed location score when available, then the expanded64
    // catalogue research index.
    final double? locationScore = (geo?['overall_location_score'] as num?)
        ?.toDouble();
    final double? catalogScore = (data['catalog_suitability_score'] as num?)
        ?.toDouble();
    // No backing score means no score. The legacy non-nullable field keeps a
    // zero for old callers, but [measuredScore] stays null so a UI can say
    // "not measured" instead of presenting an invented zero.
    final double? score = locationScore ?? catalogScore;

    final int? comp500 =
        (geo?['competitor_count_500m'] as num?)?.toInt() ??
        (counts['competitor_count_500m'] as num?)?.toInt();
    final int? comp1km =
        (geo?['competitor_count_1km'] as num?)?.toInt() ??
        (counts['competitor_count_1km'] as num?)?.toInt();
    final double? pop1km =
        (geo?['population_1km'] as num?)?.toDouble() ??
        (population?['pop_total_1km'] as num?)?.toDouble();
    final double? pop500m =
        (geo?['population_500m'] as num?)?.toDouble() ??
        (population?['pop_ring_0_500m'] as num?)?.toDouble();
    final double? accessibility = (geo?['accessibility_score'] as num?)
        ?.toDouble();
    final double? income =
        (geo?['income_median'] as num?)?.toDouble() ??
        (research?['district_income_median_myr'] as num?)?.toDouble();

    final factors = <LocationFactor>[];
    if (pop1km != null || pop500m != null) {
      final (rating, impact) = populationRating(pop1km);
      factors.add(
        LocationFactor(
          name: 'Nearby population',
          score: rating == 'Strong'
              ? 85
              : rating == 'Good'
              ? 70
              : rating == 'Moderate'
              ? 50
              : 30,
          rating: rating,
          evidence:
              'Research population estimates — '
              '${pop500m != null ? '${pop500m.round()} within 500 m' : 'no 500 m figure'}'
              '${pop1km != null ? ', ${pop1km.round()} within 1 km' : ''}.',
          impact: impact,
        ),
      );
    }
    if (comp500 != null) {
      final (rating, impact) = competitionRating(comp500);
      factors.add(
        LocationFactor(
          name: 'F&B competition nearby',
          score: rating == 'Strong'
              ? 80
              : rating == 'Moderate'
              ? 55
              : 30,
          rating: rating,
          evidence:
              '$comp500 F&B outlets within 500 m'
              '${comp1km != null ? ' ($comp1km within 1 km)' : ''} in the '
              'research competitor dataset — a count, not a success forecast.',
          impact: impact,
        ),
      );
    }
    if (accessibility != null) {
      factors.add(
        LocationFactor(
          name: 'Accessibility',
          score: accessibility.clamp(0, 100).toDouble(),
          rating: LocationAnalysisRules.rating(accessibility),
          evidence:
              'Research accessibility score ${accessibility.toStringAsFixed(1)} '
              '(road network within 1 km).',
          impact: accessibility >= 45 ? 'Positive' : 'Risk',
        ),
      );
    }
    if (income != null) {
      factors.add(
        LocationFactor(
          name: 'District income',
          score: 60,
          rating: LocationAnalysisRules.rating(
            income > 0 ? (income / 100).clamp(0, 100) : 0,
          ),
          evidence:
              'Median district income RM ${income.toStringAsFixed(0)} '
              '(research dataset).',
          impact: 'Neutral',
        ),
      );
    }

    final demandParts = <String>[];
    if (comp500 != null) demandParts.add('$comp500 F&B outlets within 500 m');
    if (pop1km != null) {
      demandParts.add('≈${pop1km.round()} residents within 1 km');
    }
    final socioParts = <String>[];
    if (income != null) {
      socioParts.add('median district income RM ${income.toStringAsFixed(0)}');
    }
    final market = geo?['market_segment'] as String?;
    if (market != null && market.isNotEmpty) socioParts.add('segment: $market');

    return LocationAnalysis(
      propertyId: propertyId,
      suitabilityScore: score ?? 0,
      measuredScore: score,
      factors: List.unmodifiable(factors),
      competitorCount: comp500 ?? 0,
      measuredCompetitorCount: comp500,
      demandSummary: demandParts.isEmpty
          ? 'No research demand coverage for this property yet.'
          : demandParts.join(' · '),
      socioeconomicSummary: socioParts.isEmpty ? '' : socioParts.join(' · '),
      measurementGroups: groups,
      hasMeasuredValues: groups.any((group) => group.available),
    );
  }

  /// Strengths and considerations read straight off the factors [analyse]
  /// produced, so an explanation can never disagree with the analysis it
  /// summarises.
  static RecommendationExplanation explain(LocationAnalysis analysis) {
    final strengths = [
      for (final f in analysis.factors)
        if (f.impact == 'Positive') '${f.name} — ${f.rating}',
    ];
    final considerations = [
      for (final f in analysis.factors)
        if (f.impact != 'Positive') '${f.name} is ${f.rating.toLowerCase()}',
    ];
    return RecommendationExplanation(
      propertyId: analysis.propertyId,
      suitabilityScore: analysis.suitabilityScore,
      strengths: strengths,
      considerations: considerations,
      summary:
          'Built from research dataset features (population, competitor and '
          'accessibility counts). These are not verified success '
          'probabilities; validate on site before committing.',
    );
  }
}
