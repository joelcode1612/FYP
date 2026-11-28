import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';
import 'package:sitewise_jaspr_web/shared/presentation/components/ui.dart';

/// The Admin location evidence view. Scores and measurements come from the
/// review API. Only their presentation and grouping are handled here.
class LocationIntelligencePanel extends StatefulComponent {
  final VerificationDetail detail;
  final LocationResearchAssociation location;
  final Component map;
  final bool inProgress;

  const LocationIntelligencePanel({
    super.key,
    required this.detail,
    required this.location,
    required this.map,
    required this.inProgress,
  });

  @override
  State<LocationIntelligencePanel> createState() =>
      _LocationIntelligenceState();
}

class _LocationIntelligenceState extends State<LocationIntelligencePanel> {
  bool _wide = false;
  VerificationDetail get detail => component.detail;
  LocationResearchAssociation get location => component.location;
  String get _radius => _wide ? '1 km' : '500 m';
  String get _suffix => _wide ? '1000m' : '500m';

  static const _groups = <String, List<String>>{
    'Population': ['population', 'age', 'residential'],
    'Accessibility': ['network', 'transit', 'parking'],
    'Nearby businesses': ['businesses'],
    'Competition': ['competition'],
    'Surrounding facilities': ['demand'],
  };

  static bool _isBusiness(String key) =>
      key.startsWith('office_') ||
      key.startsWith('retail_') ||
      key.startsWith('malls_') ||
      key.startsWith('supermarkets_');

  static final _featureLabels = {
    for (final rows in LocationAnalysisRules.measurementRows.values)
      for (final (key, label, _) in rows) key: label,
  };

  @override
  Component build(BuildContext context) {
    return section(
      id: 'vd-panel-intelligence',
      classes: 'li-panel stack',
      attributes: const {
        'role': 'tabpanel',
        'aria-labelledby': 'vd-tab-intelligence',
      },
      [
        div(classes: 'li-dashboard-head', [
          h2([const Component.text('Location intelligence')]),
          div(
            classes: 'li-radius-switch',
            attributes: const {
              'role': 'group',
              'aria-label': 'Measurement radius',
            },
            [
              for (final (wide, label) in [(false, '500 m'), (true, '1 km')])
                button(
                  type: ButtonType.button,
                  attributes: {'aria-pressed': '${_wide == wide}'},
                  events: events(onClick: () => setState(() => _wide = wide)),
                  [Component.text(label)],
                ),
            ],
          ),
        ]),
        div(classes: 'li-dashboard-grid', [
          _suitability(),
          _overview(),
          _populationChart(),
          _factors(),
          _income(),
          _competition(),
          _facilities(),
          _accessibility(),
        ]),
        _section('Environmental information', [
          p([
            const Component.text(
              'Verified environmental and disaster information is unavailable. The level of risk is unknown.',
            ),
          ]),
        ]),
        _section('Property location', [component.map]),
        _measurements(),
      ],
    );
  }

  Component _suitability() {
    final score = location.score;
    final hasScore = location.available && score != null && score.isFinite;
    return _section('Location suitability', [
      if (hasScore)
        div(classes: 'li-score-layout', [
          div(
            classes: 'li-score',
            attributes: {
              'style': '--li-score-fill: ${score.clamp(0, 1) * 100}%',
            },
            [
              div([
                strong([Component.text((score * 100).toStringAsFixed(1))]),
                span([const Component.text('out of 100')]),
              ]),
            ],
          ),
          p([
            const Component.text(
              'A higher score means this location shares more characteristics with the locations used as examples in the study.',
            ),
          ]),
        ]),
      if (component.inProgress)
        p(
          attributes: const {'role': 'status'},
          [const Component.text('Analysis in progress')],
        )
      else if (!hasScore)
        p([const Component.text('Location analysis is not available yet.')]),
    ]);
  }

  Component _factors() {
    final raw = location.explanation['contributions'];
    final contributions = <(String, String, num)>[
      if (location.available && raw is Map)
        for (final entry in raw.entries)
          if (_featureLabels[entry.key] case final label?)
            if (entry.value case final num value
                when value.isFinite && value != 0)
              (entry.key.toString(), label, value),
    ]..sort((first, second) => second.$3.abs().compareTo(first.$3.abs()));
    if (contributions.isEmpty) {
      return _section('What influences this score', [
        p([
          const Component.text(
            'Factor contributions are unavailable for this location.',
          ),
        ]),
      ]);
    }
    final factors = contributions.take(8).toList();
    final largest = contributions.first.$3.abs();
    return _section('What influences this score', [
      p([
        const Component.text(
          'These factors have the largest effects on the score. Longer bars show a larger effect.',
        ),
      ]),
      div(classes: 'li-factor-legend', [
        span(classes: 'li-negative', [
          const Component.text('− Lowers the score'),
        ]),
        span([const Component.text('0')]),
        span(classes: 'li-positive', [
          const Component.text('+ Raises the score'),
        ]),
      ]),
      ul(classes: 'li-factors', [
        for (final (index, (key, label, value)) in factors.indexed)
          li(
            classes: 'li-factor',
            attributes: {
              'tabindex': '0',
              'aria-describedby': 'li-factor-note-$index',
            },
            [
              div(classes: 'li-factor-label', [
                span([Component.text(label)]),
                strong(classes: value > 0 ? 'li-positive' : 'li-negative', [
                  Component.text(
                    '${value > 0 ? '+' : '−'}${value.abs().toStringAsFixed(3)}',
                  ),
                ]),
              ]),
              div(
                classes: 'li-factor-track',
                attributes: const {'aria-hidden': 'true'},
                [
                  span(classes: 'li-factor-half', [
                    if (value < 0) _bar(value, largest, 'li-negative'),
                  ]),
                  span(classes: 'li-factor-half', [
                    if (value > 0) _bar(value, largest, 'li-positive'),
                  ]),
                ],
              ),
              span(
                id: 'li-factor-note-$index',
                classes: 'li-factor-note',
                attributes: const {'role': 'tooltip'},
                [Component.text(_factorDescription(key, label, value))],
              ),
            ],
          ),
      ]),
    ]);
  }

  Component _bar(num value, num largest, String classes) => span(
    classes: 'li-factor-bar $classes',
    attributes: {'style': 'width: ${value.abs() / largest * 100}%'},
    [],
  );

  String _factorDescription(String key, String label, num value) {
    final description = switch (key) {
      'nearest_major_road_m' =>
        'Straight-line distance to the closest major road.',
      'nearest_transit_walk_m' =>
        'Walking distance to the closest public transport stop.',
      'nearest_parking_distance_m' =>
        'Distance to the closest mapped parking facility.',
      _ when key.startsWith('pop_age_') =>
        'Estimated residents in this age group within the stated radius.',
      _ when key.startsWith('pop_') =>
        'Estimated residents within the stated radius.',
      _ when key.startsWith('residential_footprint') =>
        'Share of the area covered by residential buildings.',
      _ when key.startsWith('residential_landuse') =>
        'Share of the area classified as residential land.',
      _ when key.contains('density') =>
        '$label measures the amount per square kilometre.',
      _ when key.contains('walk') || key.contains('drive') =>
        '$label describes what can be reached via the local transport network.',
      _ =>
        '$label counts mapped locations of this type within the stated radius.',
    };
    return '$description Its contribution ${value > 0 ? 'raised' : 'lowered'} this location’s score.';
  }

  Component _income() {
    final district = location.districtContext;
    final name = [
      _text(district['district']),
      _text(district['state']),
    ].whereType<String>().toSet().join(', ');
    final median = _number(district['income_median']);
    final mean = _number(district['income_mean']);
    final rawDate = _text(district['date']);
    final date = DateTime.tryParse(rawDate ?? '');
    final release = date == null
        ? rawDate
        : date.toIso8601String().split('T').first;
    return _section('Household and income', [
      dl(classes: 'li-income', [
        _fact('District', name.isEmpty ? 'Unavailable' : name),
        _fact(
          'Source',
          name.isEmpty && median == null && mean == null
              ? 'Unavailable'
              : 'Department of Statistics Malaysia (DOSM)',
        ),
        _fact('Data date', release ?? 'Unavailable'),
      ]),
      div(classes: 'li-income-values', [
        _comparisonBars([
          ('Median monthly household income', median, _incomeValue(median)),
          ('Average monthly household income', mean, _incomeValue(mean)),
        ]),
      ]),
    ]);
  }

  num? _reading(String key) => _savedMeasurement(key, _fallbackMeasurements);
  num? get _parking =>
      _reading(_wide ? 'parking_facilities_1km' : 'parking_facilities_500m');

  Component _overview() => _section('Area at a glance · $_radius', [
    div(classes: 'li-stat-grid li-overview-stats', [
      _stat('groups', 'Population', [_value(_reading('pop_$_suffix'))]),
      _stat('restaurant', 'F&B businesses', [
        _value(_reading('fnb_competitors_$_suffix')),
      ]),
      _stat('apartment', 'Residential buildings', [
        _value(_reading('residential_building_count_$_suffix')),
      ]),
      _stat('local_parking', 'Parking facilities', [_value(_parking)]),
    ]),
  ]);

  Component _populationChart() => _section('Population by age · $_radius', [
    _categoryBars(const [
      ('0_14', 'Ages 0–14'),
      ('15_24', 'Ages 15–24'),
      ('25_34', 'Ages 25–34'),
      ('35_49', 'Ages 35–49'),
      ('50_64', 'Ages 50–64'),
      ('65_plus', 'Ages 65+'),
    ], (key) => _reading('pop_age_${key}_${_wide ? '1km' : '500m'}')),
  ]);

  Component _competition() {
    final total = _reading('fnb_competitors_$_suffix');
    return _section('Food and drink competition · $_radius', [
      p([Component.text('Total F&B businesses · ${_value(total)}')]),
      _categoryBars(const [
        ('restaurant_count', 'Restaurants'),
        ('cafe_count', 'Cafés'),
        ('fast_food_count', 'Fast food'),
        ('bakery_dessert_beverage_count', 'Bakeries, dessert and drinks'),
      ], (key) => _reading('${key}_$_suffix')),
    ]);
  }

  Component _facilities() => _section('Nearby facilities · $_radius', [
    _categoryBars(const [
      ('office_pois', 'Offices'),
      ('retail_pois', 'Retail outlets'),
      ('malls_count', 'Shopping malls'),
      ('supermarkets_count', 'Supermarkets'),
      ('schools_count', 'Schools'),
      ('universities_colleges_count', 'Universities and colleges'),
      ('hospitals_count', 'Hospitals'),
    ], (key) => _reading('${key}_$_suffix')),
  ]);

  Component _categoryBars(
    List<(String, String)> categories,
    num? Function(String) read,
  ) => _comparisonBars([
    for (final (key, label) in categories)
      if (read(key) case final value?)
        (label, value, _value(value))
      else
        (label, null, 'Unavailable'),
  ]);

  Component _accessibility() {
    final fallback = _fallbackMeasurements;
    final transit = detail.locationAnalysis.partB.accessibility.transit;
    final measurements = [
      (
        'directions_bus',
        'Transit stops · $_radius walk',
        _reading('transit_stops_${_wide ? '1km' : '500m'}_walk'),
        '',
      ),
      (
        'directions_bus',
        'Bus stops · 500 m walk',
        transit['bus_stops_500m_walk'],
        '',
      ),
      (
        'train',
        'Rail stations · 1 km walk',
        transit['rail_stations_1km_walk'],
        '',
      ),
      (
        'directions_walk',
        'Walk to nearest transit stop',
        _savedMeasurement('nearest_transit_walk_m', fallback),
        'm',
      ),
      ('local_parking', 'Parking facilities · $_radius', _parking, ''),
      (
        'local_parking',
        'Distance to nearest parking',
        _savedMeasurement('nearest_parking_distance_m', fallback),
        'm',
      ),
      (
        'directions_walk',
        'Area reachable in a 10-minute walk',
        _savedMeasurement('walk_isochrone_area_10min_km2', fallback),
        'km²',
      ),
      (
        'groups',
        'People within a 10-minute walk',
        _savedMeasurement('worldpop_walk_reachable_10min', fallback),
        'people',
      ),
    ];
    final stats = [
      for (final (icon, label, value, unit) in measurements)
        _stat(icon, label, [_value(value, unit)]),
    ];
    return _section('Transport and parking', [
      div(classes: 'li-stat-grid', stats),
    ]);
  }

  num? _savedMeasurement(String key, Map<String, num?> fallback) =>
      _number(location.featureValues[key] ?? fallback[key]);

  Component _stat(String icon, String label, List<String> values) =>
      div(classes: 'li-stat', [
        Icon(icon, size: 'sm'),
        div([
          h4([Component.text(label)]),
          for (final value in values) strong([Component.text(value)]),
        ]),
      ]);

  Component _measurements() => details(classes: 'li-section li-detail', [
    summary([const Component.text('Detailed location data')]),
    div(classes: 'li-measurements stack', [
      p([
        const Component.text(
          'Distances are measured in a straight line unless marked as walking or driving. Unavailable measurements are marked separately from zero.',
        ),
      ]),
      for (final group in _groups.entries)
        _measurementGroup(group.key, group.value),
    ]),
  ]);

  Component _measurementGroup(String title, List<String> categories) {
    final fallback = _fallbackMeasurements;
    final rows = <(String, String)>[
      for (final category in categories)
        for (final (key, label, unit)
            in LocationAnalysisRules.measurementRows[category == 'businesses'
                ? 'demand'
                : category]!)
          if (category == 'businesses'
              ? _isBusiness(key)
              : category != 'demand' || !_isBusiness(key))
            (label, _measurementValue(key, unit, fallback[key])),
      ..._extraMeasurements(title),
    ];
    return details(classes: 'li-group stack', [
      summary([Component.text(title)]),
      dl(classes: 'li-data-list', [
        for (final (label, value) in rows) _fact(label, value),
      ]),
      if (title == 'Surrounding facilities' &&
          detail.demandGenerators.isNotEmpty)
        div(classes: 'stack', [
          h5([const Component.text('Activity destinations within 1 km')]),
          dl(classes: 'li-data-list', [
            for (final destination in detail.demandGenerators)
              _fact(
                destination.name.isEmpty
                    ? destination.category ?? 'Nearby destination'
                    : destination.name,
                _value(destination.distanceM, 'm'),
              ),
          ]),
        ]),
    ]);
  }

  String _measurementValue(String key, String unit, num? fallback) {
    final value = location.featureValues[key];
    if (value == null) return _value(fallback, unit);
    final note = switch (location.featureStates[key]) {
      'stale' => ' · needs updating',
      'calculated_unvalidated' => ' · needs confirmation',
      _ => '',
    };
    return '${_value(value, unit)}$note';
  }

  Map<String, num?> get _fallbackMeasurements {
    final data = detail.locationAnalysis.partB;
    final geo = detail.geoFeatures;
    final population = detail.population;
    final food = data.fnbEnvironment;
    final access = data.accessibility;
    return {
      'pop_500m':
          data.population.pop500m ?? population?.pop500m ?? geo?.population500m,
      'pop_1000m':
          data.population.pop1km ?? population?.pop1km ?? geo?.population1km,
      'pop_3000m': data.population.pop3km,
      'fnb_competitors_500m':
          food.competitorCount500m ?? geo?.competitorCount500m,
      'fnb_competitors_1000m':
          food.competitorCount1km ?? geo?.competitorCount1km,
      'cafe_count_500m': food.competitorBreakdown500m['cafes_500m'],
      'restaurant_count_500m': food.competitorBreakdown500m['restaurants_500m'],
      'fast_food_count_500m': food.competitorBreakdown500m['fast_food_500m'],
      'office_pois_500m': food.nearbyAnchors['office_poi_500m'],
      'malls_count_1000m': food.nearbyAnchors['malls_1km'],
      'schools_count_1000m': food.nearbyAnchors['schools_1km'],
      'universities_colleges_count_1000m':
          food.nearbyAnchors['universities_1km'],
      'hospitals_count_1000m': food.nearbyAnchors['hospitals_1km'],
      'nearest_major_road_m':
          access.nearestMajorRoadM ?? geo?.nearestMajorRoadM,
      'nearest_transit_walk_m': access.transit['nearest_transit_walk_m'],
      'parking_facilities_500m': access.parking['facilities_500m'],
      'parking_facilities_1km': access.parking['facilities_1km'],
      'nearest_parking_distance_m': access.parking['nearest_parking_m'],
    };
  }

  List<(String, String)> _extraMeasurements(String group) {
    final data = detail.locationAnalysis.partB;
    final geo = detail.geoFeatures;
    final population = detail.population;
    return switch (group) {
      'Population' => [
        (
          'Population density · 1 km',
          _value(
            data.population.density1km ?? population?.popDensityKm2,
            'people/km²',
          ),
        ),
        (
          'Estimated households · 1 km',
          _value(
            data.population.estimatedHouseholds1km ??
                population?.estimatedHouseholds1km,
            'households',
          ),
        ),
        (
          'Young adults aged 20–34 · 1 km',
          _value(data.population.pctAge2034, '%'),
        ),
        (
          'Working-age residents aged 15–64 · 1 km',
          _value(data.population.pctAge1564, '%'),
        ),
        if (data.population.landscanAmbient1km != null)
          (
            'People typically present · 1 km',
            _value(data.population.landscanAmbient1km, 'people'),
          ),
      ],
      'Accessibility' => [
        (
          'Road length within 1 km',
          _value(data.accessibility.roadKm1km ?? geo?.roadKm1km, 'km'),
        ),
        (
          'Bus stops within a 500 m walk',
          _value(data.accessibility.transit['bus_stops_500m_walk']),
        ),
        (
          'Rail stations within a 1 km walk',
          _value(data.accessibility.transit['rail_stations_1km_walk']),
        ),
      ],
      'Competition' => [
        (
          'Nearest food or drink competitor',
          [
            _value(data.fnbEnvironment.nearestCompetitorM, 'm'),
            data.fnbEnvironment.nearestCompetitorName,
            data.fnbEnvironment.nearestCompetitorCategory?.replaceAll('_', ' '),
            data.fnbEnvironment.nearestCompetitorSource,
          ].whereType<String>().where((part) => part.isNotEmpty).join(' · '),
        ),
      ],
      'Surrounding facilities' => [
        (
          'Activity destinations · 500 m',
          _value(
            data.fnbEnvironment.demandGeneratorCount500m ??
                geo?.demandGeneratorCount500m,
          ),
        ),
        (
          'Activity destinations · 1 km',
          _value(
            data.fnbEnvironment.demandGeneratorCount1km ??
                geo?.demandGeneratorCount1km,
          ),
        ),
      ],
      _ => const [],
    };
  }

  Component _section(String title, List<Component> children) =>
      section(classes: 'li-section stack', [
        h3([Component.text(title)]),
        ...children,
      ]);

  Component _fact(String label, String value) => div([
    dt([Component.text(label)]),
    dd([Component.text(value)]),
  ]);

  static String? _text(Object? raw) =>
      raw is String && raw.trim().isNotEmpty ? raw.trim() : null;

  static num? _number(Object? raw) {
    final value = raw is num
        ? raw
        : raw is String
        ? num.tryParse(raw)
        : null;
    return value != null && value.isFinite ? value : null;
  }

  static String _incomeValue(num? amount) =>
      amount == null ? 'Unavailable' : 'RM ${_value(amount)} / month';

  static String _value(num? raw, [String unit = '']) {
    final value = _number(raw);
    if (value == null) return 'Unavailable';
    final amount = value.toStringAsFixed(
      value == value.roundToDouble() ? 0 : 2,
    );
    if (unit.isEmpty) return amount;
    return unit == '%' ? '$amount%' : '$amount $unit';
  }
}

/// Both charts share the same layout. A missing value has no bar and a
/// measured zero keeps its visible numeric label.
Component _comparisonBars(List<(String, num?, String)> rows) {
  final maxValue = rows.fold<num>(
    0,
    (largest, row) => (row.$2 ?? 0) > largest ? row.$2! : largest,
  );
  return ul(classes: 'li-factors', [
    for (final (label, value, formatted) in rows)
      li([
        div(classes: 'li-factor-label', [
          span([Component.text(label)]),
          strong([Component.text(formatted)]),
        ]),
        if (value != null)
          div(
            classes: 'li-comparison-track',
            attributes: const {'aria-hidden': 'true'},
            [
              span(
                attributes: {
                  'style':
                      'width: ${maxValue == 0 ? 0 : value / maxValue * 100}%',
                },
                [],
              ),
            ],
          ),
      ]),
  ]);
}
