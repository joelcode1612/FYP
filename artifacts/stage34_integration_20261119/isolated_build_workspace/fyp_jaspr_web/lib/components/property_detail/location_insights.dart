import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import '../../data/location_evidence_api.dart';
import '../../data/metric_format.dart';
import '../ui.dart';

/// One display slot in the analysis panel: either a real metric or an
/// explicitly-labelled gap ("not measured at the selected radius").
/// [district] marks a DOSM row so it is badged as district-wide.
class _Slot {
  final EvidenceMetric? metric;

  /// For a gap slot: the topic label with the radius swapped to the
  /// selected one ("Cafes within 1 km"), and the selected radius label.
  final String? label;
  final String? unavailableAt;
  final bool district;

  const _Slot.metric(this.metric, {this.district = false})
      : label = null,
        unavailableAt = null;
  const _Slot.gap(this.label, this.unavailableAt)
      : metric = null,
        district = false;
}

/// V4 Location Insights — the "What's nearby?" categories inside the
/// existing Property Detail page.
///
/// Five topic cards, ONE shared 500 m / 1 km selector (top-right of the
/// section), and a single bordered panel for the selected topic. The map
/// below this section is owned by the page and is not touched here.
///
/// Data honesty rules encoded here:
/// * Every value comes from the evidence API for THIS property; missing
///   measurements render "Not available", never zero.
/// * A metric recorded only at the other radius is labelled
///   "Not measured at 500 m / 1 km" instead of silently standing in for
///   the selected distance.
/// * DOSM district rows (population, household income) are always shown
///   but explicitly badged as district-wide statistics — they never read
///   as 500 m or 1 km measurements, and never change with the selector.
/// * Values are formatted by `metric_format.dart` from the raw numbers;
///   no rounding leaks back into any model input.
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
  String _tab = 'people';
  String _radius = '500';
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

  /// Topic cards, in presentation order. The icon names are Material
  /// Symbols ligatures rendered through the shared `Icon` component
  /// (decorative — the card title carries the accessible name).
  static const _categories = [
    ('people', 'People nearby', 'Population and residential surroundings', 'group'),
    ('food', 'Food competition', 'Restaurants, cafés and competing businesses', 'storefront'),
    ('places', 'Nearby places', 'Schools, offices, shops and other facilities', 'location_on'),
    ('transport', 'Getting around', 'Public transport, roads and walking access', 'directions_bus'),
    ('parking', 'Parking', 'Nearby parking facilities and accessibility', 'directions_car'),
  ];

  /// The selector radius a metric is bound to, derived from its key:
  /// `competitor_count_500m` -> 500, `pop_1000m` / `retail_pois_1000m` /
  /// `rail_stations_1km_walk` -> 1000, `fnb_competitors_2000m` -> 2000.
  /// Null when the key carries no radius — point measurements
  /// (`nearest_transit_walk_m`) and DOSM district rows.
  static String? _radiusOf(String key) {
    final match = RegExp(r'(?:^|_)(\d+)(?:m|km)(?=_|$)').firstMatch(key);
    final digits = match?.group(1);
    if (digits == null) return null;
    // `1km` and `1000m` are the same selector radius.
    return digits == '1' ? '1000' : digits;
  }

  /// Radii the selector can choose; any other recorded radius (the wider
  /// 2 km food catchment) is a fixed measurement whose own label states
  /// its distance, so it shows at both selector positions.
  static const _selectorRadii = {'500', '1000'};

  static bool _isDistrictMetric(String key) => key.startsWith('district_');

  /// Pairs radius-bound metric keys across the selector (`..._500m` vs
  /// `..._1000m`) by blanking the radius token, so a 500 m-only
  /// measurement can be labelled as missing at 1 km instead of vanishing.
  static String _baseKey(String key) =>
      key.replaceFirst(RegExp(r'(\d+)(m|km)(?=_|$)'), '@radius@');

  static String _tabOf(String key) {
    final k = key.toLowerCase();
    if (_isDistrictMetric(k)) return 'people';
    if (k.contains('parking')) return 'parking';
    if (RegExp(r'competitor|fnb|cafe|restaurant|fast_food|bakery|food').hasMatch(k)) {
      return 'food';
    }
    if (RegExp(r'transit|bus|rail|walk|road|isochrone|access|departures').hasMatch(k)) {
      return 'transport';
    }
    if (RegExp(r'office|school|universit|retail|mall|hospital|supermarket|poi')
        .hasMatch(k)) {
      return 'places';
    }
    if (RegExp(r'pop|household|income|building|footprint|density').hasMatch(k)) {
      return 'people';
    }
    return 'places';
  }

  String get _radiusLabel => _radius == '500' ? '500 m' : '1 km';

  /// The calendar date an evidence snapshot was taken, without the technical
  /// payload metadata the analyst-facing API also carries.
  static String _checkedOn(String iso) =>
      iso.length >= 10 ? iso.substring(0, 10) : iso;

  Component _radiusChips() => div(
        classes: 'sw-v4__radius',
        attributes: {'role': 'group', 'aria-label': 'Search radius'},
        [
          for (final r in [('500', '500 m'), ('1000', '1 km')])
            button(
              classes: _radius == r.$1 ? 'sw-v4__chip is-on' : 'sw-v4__chip',
              attributes: {'type': 'button', 'aria-pressed': '${_radius == r.$1}'},
              events: {
                'click': (e) => setState(() => _radius = r.$1),
              },
              [Component.text(r.$2)],
            ),
        ],
      );

  Component _catCards() => div(classes: 'sw-v4__cats', [
        for (final c in _categories)
          button(
            classes:
                'sw-v4__cat sw-v4__cat--${c.$1}${_tab == c.$1 ? ' is-on' : ''}',
            attributes: {'type': 'button', 'aria-pressed': '${_tab == c.$1}'},
            events: {
              'click': (e) => setState(() => _tab = c.$1),
            },
            [
              span(classes: 'sw-v4__cat-icon', [
                Icon(c.$4),
              ]),
              span(classes: 'sw-v4__cat-text', [
                span(classes: 'sw-v4__cat-title', [Component.text(c.$2)]),
                span(classes: 'sw-v4__cat-sub', [Component.text(c.$3)]),
              ]),
            ],
          ),
      ]);

  /// The display slots for the selected tab and radius, in the backend's
  /// own order. Radius-bound metrics are paired across the selector by
  /// base key: the selected radius renders its value, and a base with no
  /// measurement at the selected radius renders an explicit gap row.
  List<_Slot> _slotsFor(List<EvidenceMetric> all) {
    final tabMetrics = [
      for (final m in all) if (_tabOf(m.key) == _tab) m,
    ];
    final slots = <_Slot>[];
    final emittedGaps = <String>{};
    for (final m in tabMetrics) {
      if (_isDistrictMetric(m.key)) {
        slots.add(_Slot.metric(m, district: true));
        continue;
      }
      final radius = _radiusOf(m.key);
      if (radius == null || !_selectorRadii.contains(radius)) {
        // Point measurement (nearest transit stop) or a fixed wider
        // catchment (the 2 km food scene) — its label states its own
        // distance, so it shows at both selector positions.
        slots.add(_Slot.metric(m));
        continue;
      }
      if (radius == _radius) {
        slots.add(_Slot.metric(m));
        continue;
      }
      // Recorded at the other radius only: an explicit, labelled gap.
      final base = _baseKey(m.key);
      final selectedExists = tabMetrics.any(
        (x) =>
            _radiusOf(x.key) == _radius &&
            _baseKey(x.key) == base &&
            !_isDistrictMetric(x.key),
      );
      if (!selectedExists && emittedGaps.add(base)) {
        // The sibling's label reads "... within 1 km" / "... within 500 m";
        // swap the radius so the gap describes the SELECTED distance.
        slots.add(_Slot.gap(
          m.label.replaceFirst(
            _radius == '500' ? '1 km' : '500 m',
            _radiusLabel,
          ),
          _radiusLabel,
        ));
      }
    }
    return slots;
  }

  /// The display text for a metric's value: formatted from the raw number
  /// by unit, or "Not available" when the backend has no value.
  String _formatted(EvidenceMetric m) =>
      fmtEvidenceValue(m.value, m.unit) ?? 'Not available';

  Component _metricCard(_Slot slot) {
    final m = slot.metric!;
    final known = m.value != null;
    final notes = [
      if (slot.district)
        'District-wide (DOSM) statistic — not a 500 m / 1 km measurement.',
      if (m.note != null && m.note!.isNotEmpty) m.note!,
    ];
    return div(classes: 'sw-v4__metric-card', [
      span(classes: 'sw-v4__metric-label', [Component.text(m.label)]),
      strong(
        classes: known ? 'sw-v4__metric-value' : 'sw-v4__metric-value is-absent',
        [
          Component.text(known ? _formatted(m) : 'Not available'),
        ],
      ),
      for (final note in notes)
        span(
          classes:
              'sw-v4__metric-note${note.startsWith('District-wide') ? ' is-district' : ''}',
          [Component.text(note)],
        ),
    ]);
  }

  /// A prominent card for a measurement the backend records only at the
  /// other radius: an honest gap, never a stand-in value.
  Component _gapCard(_Slot slot) =>
      div(classes: 'sw-v4__metric-card', [
        span(classes: 'sw-v4__metric-label', [Component.text(slot.label!)]),
        strong(classes: 'sw-v4__metric-value is-absent', [
          Component.text('Not measured at ${slot.unavailableAt}'),
        ]),
        span(classes: 'sw-v4__metric-note', [
          Component.text(
            'The analysis pipeline has no measurement for this topic at the '
            'selected distance. Switch the radius to see what is recorded.',
          ),
        ]),
      ]);

  Component _slotRow(_Slot slot) {
    final m = slot.metric;
    if (m == null) {
      return div(classes: 'sw-v4__row', [
        span([Component.text(slot.label!)]),
        span(classes: 'is-absent', [
          Component.text('Not measured at ${slot.unavailableAt}'),
        ]),
      ]);
    }
    final known = m.value != null;
    return div(classes: 'sw-v4__row', [
      span([Component.text(m.label)]),
      span(
        classes: known ? null : 'is-absent',
        [Component.text(known ? _formatted(m) : 'Not available')],
      ),
    ]);
  }

  Component _sidebar() => aside(classes: 'sw-v4__aside', [
        div(classes: 'sw-v4__aside-card', [
          h4([Component.text('Why this matters')]),
          p([
            Component.text(
              'How busy the area is, who you would compete with and how easily '
              'people can get here all shape whether a business can reach '
              'enough customers.',
            ),
          ]),
        ]),
        div(classes: 'sw-v4__aside-card', [
          h4([Component.text('How to use this')]),
          p([
            Component.text(
              'Compare topics at the same distance, then check shortlisted premises '
              'in person. These measurements are evidence, not a recommendation.',
            ),
          ]),
        ]),
        div(classes: 'sw-v4__aside-card', [
          h4([Component.text("Area we're checking")]),
          div(classes: 'sw-v4__area-art', [
            span(classes: 'sw-v4__area-ring', const []),
            span(classes: 'sw-v4__area-dot', const []),
          ]),
          p(classes: 'small', [
            Component.text('Shows the $_radiusLabel area around this property. This is not an exact boundary.'),
          ]),
        ]),
      ]);

  Component _analysis(PropertyEvidence? evidence, Object? error) {
    final label = _categories.firstWhere((c) => c.$1 == _tab).$2;
    if (evidence == null || !evidence.available) {
      return div(classes: 'sw-v4__analysis', [
        div(classes: 'sw-v4__analysis-main', [
          h3([Component.text(label)]),
          div(classes: 'sw-v4__empty', [
            p([
              Component.text(
                error != null
                    ? 'We could not load the nearby area information right now.'
                    : 'We do not have nearby area information for this property yet.',
              ),
            ]),
          ]),
          p(classes: 'sw-v4__tip', [
            Component.text(
              'Where something is not recorded we say so, instead of showing a '
              'zero that would look like a measurement.',
            ),
          ]),
        ]),
        _sidebar(),
      ]);
    }
    final slots = _slotsFor([
      for (final g in evidence.groups) ...g.metrics,
    ]);
    final prominent = slots.take(3).toList();
    final rest = slots.skip(3).toList();
    return div(classes: 'sw-v4__analysis', [
      div(classes: 'sw-v4__analysis-main', [
        div(classes: 'sw-v4__analysis-head', [
          div([
            h3([Component.text(label)]),
            p(classes: 'small', [
              Component.text('Measured within $_radiusLabel of this property.'),
            ]),
          ]),
          // One shared 500 m / 1 km selector lives in the section head above;
          // this panel deliberately renders no second copy of it.
        ]),
        if (slots.isEmpty)
          div(classes: 'sw-v4__empty', [
            p([
              Component.text(
                'Nothing is recorded for this topic at $_radiusLabel. That is '
                'different from a measured zero.',
              ),
            ])
          ])
        else ...[
          div(classes: 'sw-v4__metrics', [
            for (final slot in prominent)
              slot.metric != null ? _metricCard(slot) : _gapCard(slot),
          ]),
          if (rest.isNotEmpty)
            div(classes: 'sw-v4__rows', [
              for (final slot in rest) _slotRow(slot),
            ]),
        ],
        p(classes: 'sw-v4__tip', [
          Component.text(
            [
              if (evidence.snapshotAt != null)
                'Area information last checked ${_checkedOn(evidence.snapshotAt!)}.',
              'Where a measurement is missing we say so rather than showing zero.',
              'Nearby food businesses are counted from mapped outlets, which is '
                  'not the same as the number of properties for rent.',
            ].join(' '),
          ),
        ]),
      ]),
      _sidebar(),
    ]);
  }

  @override
  Component build(BuildContext context) {
    return section(classes: 'sw-v4__insights', [
      div(classes: 'sw-v4__section-head', [
        div([
          span(classes: 'sw-v4__eyebrow', [Component.text('THE SURROUNDING AREA')]),
          h2([Component.text('What is around this property')]),
        ]),
        _radiusChips(),
      ]),
      _catCards(),
      FutureBuilder<PropertyEvidence>(
        future: _evidence,
        builder: (c, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return div(classes: 'loading', [
              Component.text('Loading nearby area information…'),
            ]);
          }
          return _analysis(snap.data, snap.error);
        },
      ),
    ]);
  }
}
