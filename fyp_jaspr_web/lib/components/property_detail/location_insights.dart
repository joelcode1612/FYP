import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import '../../data/location_evidence_api.dart';
import '../../data/metric_format.dart';
import '../ui.dart';

/// "What's nearby" tab content — the curated, visual half of the location
/// information for this property.
///
/// The map (a page section above the tabs) answers *where*; this panel
/// answers *how much*. It deliberately shows a small, entrepreneur-facing
/// subset of the evidence payload: a handful of key-fact cards, then three
/// compact visual blocks — population, food competition, and access.
///
/// Data honesty rules encoded here:
/// * Every value comes from the evidence API for THIS property; a missing
///   measurement renders "Not available", never zero.
/// * Every recorded catchment radius is drawn as its own bar, innermost
///   first. There is no radius switch here on purpose — the map above the
///   tabs owns that control, and two selectors would disagree about which
///   distance is selected.
/// * Bar widths are relative to the largest value IN the same block, so a bar
///   reads as a shape, not as a percentage. The number travels with the bar
///   in its text and in the accessible label.
/// * "Other F&B" is the recorded total minus the four categories the backend
///   breaks out. It is rendered only when all five figures exist; an
///   incomplete set stays hidden rather than becoming a guessed remainder.
/// * Nothing here re-scores, re-weights or re-predicts: the model's own
///   numbers live in the "Why this area score?" tab.
@client
class LocationInsightsV4 extends StatefulComponent {
  final String propertyId;
  final num? puScore;
  final bool hasPuScore;

  const LocationInsightsV4({
    super.key,
    required this.propertyId,
    required this.puScore,
    required this.hasPuScore,
  });

  @override
  State<LocationInsightsV4> createState() => _LocationInsightsV4State();
}

class _LocationInsightsV4State extends State<LocationInsightsV4> {
  late Future<PropertyEvidence> _evidence;

  @override
  void initState() {
    super.initState();
    // A `@client` component may only receive primitive parameters, so the
    // evidence future cannot be handed down from the page. This read is the
    // same cached endpoint the page already uses.
    _evidence = LocationEvidenceApi.load(
      component.propertyId,
      catalog: int.tryParse(component.propertyId) == null,
    );
  }

  static const _notAvailable = 'Not available';

  // ------------------------------------------------------------- data access

  /// The flat metric list the evidence payload groups by topic, kept in the
  /// backend's own order.
  static List<EvidenceMetric> _allMetrics(PropertyEvidence evidence) => [
    for (final group in evidence.groups) ...group.metrics,
  ];

  /// One recorded measurement by its key, or null when the backend holds no
  /// such metric. Null is a gap and is always rendered as one.
  static EvidenceMetric? _metric(
    List<EvidenceMetric> all,
    String key,
  ) {
    for (final metric in all) {
      if (metric.key == key) return metric;
    }
    return null;
  }

  static num? _value(List<EvidenceMetric> all, String key) =>
      _metric(all, key)?.value;

  /// A headcount with thousands separators and no unit — the sub-line of a
  /// card, where the label above already names what is being counted.
  static String _number(num? value) =>
      value == null ? _notAvailable : metricGrouped(value.round());

  /// Width of a bar as a share of the largest value in its own block.
  static String _width(num? value, num largest) =>
      value == null || largest <= 0
          ? '0%'
          : '${(value / largest * 100).clamp(2.0, 100.0).toStringAsFixed(1)}%';

  /// Height of a column as a share of the largest value in its block.
  static String _height(num? value, num largest) =>
      value == null || largest <= 0
          ? '0%'
          : '${(value / largest * 100).clamp(3.0, 100.0).toStringAsFixed(1)}%';

  static num _largest(Iterable<num?> values) {
    num best = 0;
    for (final value in values) {
      if (value != null && value > best) best = value;
    }
    return best;
  }

  /// The recorded measurement's own caveat (source, coverage, staleness),
  /// used verbatim when the backend supplies one.
  static String? _noteOf(List<EvidenceMetric> all, String key) {
    final note = _metric(all, key)?.note?.trim();
    return note == null || note.isEmpty ? null : note;
  }

  // ------------------------------------------------------------ key-fact cards

  Component _factCard({
    required String icon,
    required String label,
    required String value,
    String? sub,
    bool absent = false,
    String tint = '',
  }) => div(classes: 'sw-viz__card', [
    span(
      classes: 'sw-viz__card-icon',
      attributes: {
        'aria-hidden': 'true',
        if (tint.isNotEmpty) 'style': tint,
      },
      [Icon(icon, size: 'sm')],
    ),
    span(classes: 'sw-viz__card-label', [Component.text(label)]),
    strong(
      classes: absent ? 'sw-viz__card-value is-absent' : 'sw-viz__card-value',
      [Component.text(value)],
    ),
    if (sub != null)
      span(classes: 'sw-viz__card-sub', [Component.text(sub)]),
  ]);

  /// The six figures an entrepreneur actually compares between sites.
  Component _keyFacts(List<EvidenceMetric> all) {
    final pop500 = _value(all, 'pop_500m');
    final pop1km = _value(all, 'pop_1000m');
    final comp500 = _value(all, 'competitor_count_500m');
    final comp1km = _value(all, 'competitor_count_1000m');
    final transit = _value(all, 'nearest_transit_walk_m');
    final parking = _value(all, 'parking_facilities_500m');
    final parkingNearest = _value(all, 'nearest_parking_distance_m');
    final retail = _value(all, 'retail_pois_1000m');
    final offices = _value(all, 'office_pois_1000m');
    final walkable = _metric(all, 'walk_isochrone_10min');

    return div(classes: 'sw-viz__cards', [
      _factCard(
        icon: 'group',
        label: 'Estimated residents within 1 km',
        value: fmtResidents(pop1km) ?? _notAvailable,
        sub: pop500 == null
            ? null
            : '${_number(pop500)} within 500 m',
        absent: pop1km == null,
        tint: 'background:#e8effc;color:#1d4ed8',
      ),
      _factCard(
        icon: 'storefront',
        label: 'F&B outlets within 500 m',
        value: fmtCount(comp500, singular: 'outlet', plural: 'outlets') ??
            _notAvailable,
        sub: comp1km == null
            ? null
            : '${_number(comp1km)} within 1 km',
        absent: comp500 == null,
        tint: 'background:#fdf0e7;color:#c2570f',
      ),
      _factCard(
        icon: 'directions_bus',
        label: 'Nearest public transport',
        value: fmtDistance(transit) ?? _notAvailable,
        sub: _transitSub(all),
        absent: transit == null,
        tint: 'background:#f0eafc;color:#6d4fc4',
      ),
      _factCard(
        icon: 'local_parking',
        label: 'Parking facilities within 500 m',
        value: fmtCount(parking, singular: 'facility', plural: 'facilities') ??
            _notAvailable,
        sub: parkingNearest == null
            ? null
            : 'closest is ${fmtDistance(parkingNearest)}',
        absent: parking == null,
        tint: 'background:#e6f3fb;color:#0f7fb8',
      ),
      _factCard(
        icon: 'location_on',
        label: 'Retail shops within 1 km',
        value: fmtCount(retail, singular: 'retail outlet', plural: 'retail outlets') ??
            _notAvailable,
        sub: offices == null
            ? null
            : '${_number(offices)} offices within 1 km',
        absent: retail == null,
        tint: 'background:#e7f6ec;color:#1a7f37',
      ),
      _factCard(
        icon: 'directions_walk',
        label: 'Area within walking reach',
        value: walkable?.value == null
            ? _notAvailable
            : fmtEvidenceValue(walkable!.value, walkable.unit) ?? _notAvailable,
        sub: '10-minute walk isochrone, not a headcount',
        absent: walkable?.value == null,
        tint: 'background:#f3ecfb;color:#7c4dbd',
      ),
    ]);
  }

  /// Stops and rail stations inside the same walking band the backend used,
  /// so a distance never reads as an unreachable number.
  static String? _transitSub(List<EvidenceMetric> all) {
    final bus = _value(all, 'bus_stops_500m_walk');
    final rail = _value(all, 'rail_stations_1km_walk');
    if (bus == null && rail == null) return null;
    return [
      if (bus != null) '${_number(bus)} bus stops within a 500 m walk',
      if (rail != null) '${_number(rail)} rail stations within a 1 km walk',
    ].join(' · ');
  }

  // -------------------------------------------------------------- chart blocks

  /// One labelled bar. The block it sits in scales it against that block's
  /// largest value, and the accessible label carries the real number.
  Component _bar({
    required String label,
    required String valueText,
    required String width,
    required String color,
    required String ariaValue,
    bool absent = false,
  }) => div(
    classes: 'sw-viz__bar${absent ? ' is-absent' : ''}',
    attributes: {
      'role': 'img',
      'aria-label': '$label: $ariaValue',
    },
    [
      span(classes: 'sw-viz__bar-label', [Component.text(label)]),
      span(classes: 'sw-viz__bar-track', [
        span(
          classes: 'sw-viz__bar-fill',
          attributes: {
            'style': 'width:$width;--sw-viz-color:$color',
          },
          const [],
        ),
      ]),
      span(classes: 'sw-viz__bar-value', [Component.text(valueText)]),
    ],
  );

  Component _block({
    required String title,
    required String caption,
    required List<Component> children,
    String? footnote,
  }) => div(classes: 'sw-viz__block', [
    div(classes: 'sw-viz__block-head', [
      h3([Component.text(title)]),
      p([Component.text(caption)]),
    ]),
    ...children,
    if (footnote != null)
      p(classes: 'sw-viz__block-note', [Component.text(footnote)]),
  ]);

  /// Residents behind the demand: every recorded catchment radius, innermost
  /// first, drawn as vertical columns the way the catchment grows outward.
  Component _populationBlock(List<EvidenceMetric> all) {
    final rows = <(String, num?, String)>[
      ('500 m', _value(all, 'pop_500m'), '#9db8e8'),
      ('1 km', _value(all, 'pop_1000m'), '#1d4ed8'),
      ('2 km', _value(all, 'pop_2000m'), '#1e3a8a'),
      ('3 km', _value(all, 'pop_3000m'), '#172554'),
    ];
    final largest = _largest([for (final row in rows) row.$2]);
    final note = _noteOf(all, 'pop_500m') ??
        _noteOf(all, 'pop_1000m') ??
        _noteOf(all, 'pop_2000m') ??
        _noteOf(all, 'pop_3000m');

    return _block(
      title: 'Population catchment',
      caption:
          'Estimated residents inside each recorded catchment of this property.',
      children: [
        if (largest <= 0)
          p(classes: 'sw-viz__empty', [
            Component.text(
              'No resident estimate is recorded for this location, so nothing '
              'is drawn here.',
            ),
          ])
        else
          div(classes: 'sw-viz__columns', [
            for (final (radius, value, color) in rows)
              div(
                classes:
                    'sw-viz__column${value == null ? ' is-absent' : ''}',
                attributes: {
                  'role': 'img',
                  'aria-label':
                      'Estimated residents within $radius: ${value == null ? 'not available' : _number(value)}',
                },
                [
                  span(classes: 'sw-viz__column-value', [
                    Component.text(_number(value)),
                  ]),
                  span(
                    classes: 'sw-viz__column-bar',
                    attributes: {
                      'style':
                          'height:${_height(value, largest)};--sw-viz-color:$color',
                    },
                    const [],
                  ),
                  span(classes: 'sw-viz__column-label', [
                    Component.text(radius),
                  ]),
                ],
              ),
          ]),
      ],
      footnote: note ??
          'A neighbourhood estimate, not a headcount — and not the age mix of '
          'the people who live here.',
    );
  }

  /// Who is already selling food nearby, split by the categories the backend
  /// records separately, with the wider totals kept visible as text.
  Component _competitionBlock(List<EvidenceMetric> all) {
    final restaurants = _value(all, 'restaurant_count_500m');
    final cafes = _value(all, 'cafe_count_500m');
    final fastFood = _value(all, 'fast_food_count_500m');
    final bakeries = _value(all, 'bakery_dessert_beverage_count_500m');
    final total500 = _value(all, 'competitor_count_500m');
    final total1km = _value(all, 'competitor_count_1000m');
    final total2km = _value(all, 'fnb_competitors_2000m');

    // The remainder is only a fact when the total and every recorded
    // category exist. Otherwise the bar is hidden, never zero-filled — the
    // total is never added to the category bars, so no business is counted
    // twice.
    final complete =
        total500 != null &&
        restaurants != null &&
        cafes != null &&
        fastFood != null &&
        bakeries != null;
    final other = complete
        ? total500 - (restaurants + cafes + fastFood + bakeries)
        : null;
    final largest = _largest([restaurants, cafes, fastFood, bakeries, other]);

    return _block(
      title: 'Nearby F&B businesses',
      caption:
          'Food and beverage outlets already recorded around this property. '
          'The breakdown is measured within 500 m.',
      children: [
        if (largest <= 0 && !complete)
          p(classes: 'sw-viz__empty', [
            Component.text(
              'No competitor counts are recorded for this location yet.',
            ),
          ])
        else ...[
          _bar(
            label: 'Restaurants',
            valueText: _number(restaurants),
            width: _width(restaurants, largest),
            color: '#9db8e8',
            ariaValue: restaurants == null
                ? 'not available'
                : '${_number(restaurants)} within 500 m',
            absent: restaurants == null,
          ),
          _bar(
            label: 'Cafés',
            valueText: _number(cafes),
            width: _width(cafes, largest),
            color: '#7195dd',
            ariaValue: cafes == null
                ? 'not available'
                : '${_number(cafes)} within 500 m',
            absent: cafes == null,
          ),
          _bar(
            label: 'Fast food',
            valueText: _number(fastFood),
            width: _width(fastFood, largest),
            color: '#4d74c9',
            ariaValue: fastFood == null
                ? 'not available'
                : '${_number(fastFood)} within 500 m',
            absent: fastFood == null,
          ),
          _bar(
            label: 'Bakery & Drinks',
            valueText: _number(bakeries),
            width: _width(bakeries, largest),
            color: '#2b57b8',
            ariaValue: bakeries == null
                ? 'not available'
                : '${_number(bakeries)} within 500 m',
            absent: bakeries == null,
          ),
          if (other != null && other >= 0)
            _bar(
              label: 'Other F&B',
              valueText: _number(other),
              width: _width(other, largest),
              color: '#172554',
              ariaValue: '${_number(other)} within 500 m',
            ),
        ],
      ],
      footnote: [
        if (total500 != null || total1km != null)
          'All types: '
              '${[
                if (total500 != null) '${_number(total500)} within 500 m',
                if (total1km != null) '${_number(total1km)} within 1 km',
              ].join(' · ')}.',
        if (other != null && complete)
          '"Other F&B" is the recorded total minus the four categories above.',
        if (total2km != null)
          '${_number(total2km)} within 2 km, for a wider view of the trade.',
      ].join(' '),
    );
  }

  /// How customers arrive: one recorded access figure per row, with the
  /// recorded caveat kept where the backend supplies one.
  Component _accessBlock(List<EvidenceMetric> all) {
    final road = _value(all, 'nearest_major_road_m');
    final routes = _metric(all, 'weekday_transit_routes_1km_walk');
    final parking1km = _metric(all, 'parking_facilities_1km');
    final walkPaths = _metric(all, 'walking_path_density_500m');

    return _block(
      title: 'Access and convenience',
      caption: 'How people reach this front door, as recorded today.',
      children: [
        div(classes: 'sw-viz__rows', [
          _row(
            icon: 'near_me',
            label: 'Nearest major road',
            value: fmtDistance(road) ?? _notAvailable,
            absent: road == null,
          ),
          _row(
            icon: 'directions_transit',
            label: 'Transit routes (≤ 1 km)',
            value: routes != null && routes.available
                ? '${_number(routes.value)} routes'
                : _notAvailable,
            absent: routes == null || !routes.available,
          ),
          _row(
            icon: 'local_parking',
            label: 'Parking facilities (≤ 1 km)',
            value: parking1km != null && parking1km.available
                ? '${_number(parking1km.value)} facilities'
                : _notAvailable,
            absent: parking1km == null || !parking1km.available,
          ),
          _row(
            icon: 'directions_walk',
            label: 'Walking paths (≤ 500 m)',
            value: walkPaths != null && walkPaths.available
                ? fmtEvidenceValue(walkPaths.value, walkPaths.unit) ??
                      _notAvailable
                : _notAvailable,
            absent: walkPaths == null || !walkPaths.available,
          ),
        ]),
        if (_noteOf(all, 'nearest_major_road_m') != null)
          p(classes: 'sw-viz__block-note', [
            Component.text(_noteOf(all, 'nearest_major_road_m')!),
          ]),
      ],
      footnote:
          'Distances follow the walking and road network where the source '
          'records one, so they are not the straight-line circles on the map.',
    );
  }

  /// One access figure as a full-width row: icon, what was measured, value.
  Component _row({
    required String icon,
    required String label,
    required String value,
    required bool absent,
  }) => div(classes: 'sw-viz__row${absent ? ' is-absent' : ''}', [
    span(
      classes: 'sw-viz__row-icon',
      attributes: const {'aria-hidden': 'true'},
      [Icon(icon, size: 'sm')],
    ),
    span(classes: 'sw-viz__row-label', [Component.text(label)]),
    strong(classes: 'sw-viz__row-value', [Component.text(value)]),
  ]);

  // ------------------------------------------------------------------ states

  Component _unavailable(String? reason, Object? error) => div(
    classes: 'sw-viz__unavailable',
    [
      Icon('info', size: 'sm'),
      p([
        Component.text(
          reason ??
              (error != null
                  ? 'We could not load the nearby area information right now.'
                  : 'We do not have nearby area information for this property '
                        'yet.'),
        ),
      ]),
      p(classes: 'small', [
        Component.text(
          'Where something is not recorded we leave the gap visible instead of '
          'showing a zero that would look like a measurement.',
        ),
      ]),
    ],
  );

  /// The page header. The coverage badge counts the metrics the evidence
  /// payload actually returned, so it never claims a fixed total — a property
  /// with gaps shows its real available count.
  Component _head(PropertyEvidence? evidence) {
    final all = evidence == null ? const <EvidenceMetric>[] : _allMetrics(evidence);
    final available = all.where((metric) => metric.available).length;
    return div(classes: 'sw-viz__head sw-viz__head--main', [
      h2([Component.text('Location overview')]),
      p([
        Component.text('Key insights about the surrounding area.'),
      ]),
      if (evidence != null && all.isNotEmpty)
        span(
          classes: 'sw-viz__badge',
          attributes: {
            'title':
                'Measured location features this property has values for. '
                'The rest are shown as "Not available" below.',
          },
          [
            const Icon('check_circle', size: 'sm'),
            Component.text('$available / ${all.length} location features available'),
          ],
        ),
    ]);
  }

  Component _body(PropertyEvidence evidence) {
    final all = _allMetrics(evidence);
    final checked = evidence.snapshotAt;
    return div(classes: 'sw-viz__body', [
      _head(evidence),
      _keyFacts(all),
      div(classes: 'sw-viz__chart-grid', [
        _populationBlock(all),
        _competitionBlock(all),
        _accessBlock(all),
      ]),
      div(classes: 'sw-viz__foot', [
        const Icon('info', size: 'sm'),
        p([
          Component.text(
            'These figures describe the surrounding area based on the latest '
            'location analysis'
            '${checked != null && checked.length >= 10 ? ' (checked ${checked.substring(0, 10)})' : ''}. '
            'They help you understand the area, not a prediction of business '
            'success.',
          ),
        ]),
      ]),
    ]);
  }

  @override
  Component build(BuildContext context) {
    return section(classes: 'sw-viz', [
      FutureBuilder<PropertyEvidence>(
        future: _evidence,
        builder: (c, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return div(classes: 'sw-viz__body', [
              _head(null),
              div(classes: 'loading', [
                Component.text('Loading nearby area information…'),
              ]),
            ]);
          }
          final evidence = snap.data;
          if (evidence == null || !evidence.available) {
            return div(classes: 'sw-viz__body', [
              _head(null),
              _unavailable(evidence?.reason, snap.error),
            ]);
          }
          return _body(evidence);
        },
      ),
    ]);
  }
}
