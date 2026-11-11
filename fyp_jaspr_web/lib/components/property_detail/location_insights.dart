import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import '../../data/location_evidence_api.dart';

/// V4 Location Insights inside the existing Property Detail page: five
/// category cards, 500 m / 1 km selector, analysis panel and sidebar.
/// Missing measurements render "Not available"; nothing is fabricated.
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
    _evidence = LocationEvidenceApi.load(
      component.propertyId,
      catalog: int.tryParse(component.propertyId) == null,
    );
  }

  static const _categories = [
    ('people', 'People nearby', 'Population and catchment demand'),
    ('food', 'Other food businesses', 'Mapped F&B competition'),
    ('places', 'Nearby places', 'Offices, schools, retail, healthcare'),
    ('transport', 'Getting there', 'Transit, walking and roads'),
    ('parking', 'Parking nearby', 'Verified parking provision'),
  ];

  static bool _hasRadius(String key, String radius) {
    final k = key.toLowerCase();
    final has500 = k.contains('500m') || k.contains('500_m');
    final has1k = k.contains('1km') || k.contains('1000m') || k.contains('1_km');
    if (!has500 && !has1k) return true;
    return radius == '500' ? has500 : has1k;
  }

  static String _tabOf(String key) {
    final k = key.toLowerCase();
    if (k.contains('parking')) return 'parking';
    if (RegExp(r'competitor|fnb|cafe|restaurant|fast_food|bakery|food').hasMatch(k)) {
      return 'food';
    }
    if (RegExp(r'transit|bus|rail|walk|road|isochrone|access').hasMatch(k)) {
      return 'transport';
    }
    if (RegExp(r'office|school|universit|retail|mall|hospital|supermarket|poi')
        .hasMatch(k)) {
      return 'places';
    }
    if (RegExp(r'pop|household|income|density').hasMatch(k)) return 'people';
    return 'places';
  }

  String get _radiusLabel => _radius == '500' ? '500 m' : '1 km';

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
            classes: _tab == c.$1 ? 'sw-v4__cat is-on' : 'sw-v4__cat',
            attributes: {'type': 'button', 'aria-pressed': '${_tab == c.$1}'},
            events: {
              'click': (e) => setState(() => _tab = c.$1),
            },
            [
              span(classes: 'sw-v4__cat-title', [Component.text(c.$2)]),
              span(classes: 'sw-v4__cat-sub', [Component.text(c.$3)]),
            ],
          ),
      ]);

  Component _metricCard(EvidenceMetric m) {
    final known = m.value != null;
    return div(classes: 'sw-v4__metric-card', [
      span(classes: 'sw-v4__metric-label', [Component.text(m.label)]),
      strong(
        classes: known ? 'sw-v4__metric-value' : 'sw-v4__metric-value is-absent',
        [
          Component.text(
            known ? '${m.value}${m.unit.isEmpty ? '' : ' ${m.unit}'}' : 'Not available',
          ),
        ],
      ),
      if (m.note != null && m.note!.isNotEmpty)
        span(classes: 'sw-v4__metric-note', [Component.text(m.note!)]),
    ]);
  }

  Component _sidebar() => aside(classes: 'sw-v4__aside', [
        div(classes: 'sw-v4__aside-card', [
          h4([Component.text('Why this matters')]),
          p([
            Component.text(
              'Foot traffic, competition and access decide whether a concept '
              'can reach enough customers at a rent it can carry.',
            ),
          ]),
        ]),
        div(classes: 'sw-v4__aside-card', [
          h4([Component.text('How to use this')]),
          p([
            Component.text(
              'Compare categories at the same radius, then verify shortlisted '
              'premises in person. Research measurements are evidence, not a '
              'recommendation.',
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
            Component.text('Illustrative $_radiusLabel catchment. Not a map.'),
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
                evidence?.reason ??
                    (error != null
                        ? 'Location evidence could not be loaded. Nothing was substituted.'
                        : 'No analysed location evidence exists for this property.'),
              ),
            ]),
          ]),
          p(classes: 'sw-v4__tip', [
            Component.text('Missing measurements are reported as unavailable — never as zero.'),
          ]),
        ]),
        _sidebar(),
      ]);
    }
    final metrics = [
      for (final g in evidence.groups)
        for (final m in g.metrics)
          if (_hasRadius(m.key, _radius) && _tabOf(m.key) == _tab) m,
    ];
    final prominent = metrics.take(3).toList();
    final rest = metrics.skip(3).toList();
    return div(classes: 'sw-v4__analysis', [
      div(classes: 'sw-v4__analysis-main', [
        div(classes: 'sw-v4__analysis-head', [
          div([
            h3([Component.text(label)]),
            p(classes: 'small', [
              Component.text('Measured within $_radiusLabel of this property.'),
            ]),
          ]),
          _radiusChips(),
        ]),
        if (metrics.isEmpty)
          div(classes: 'sw-v4__empty', [
            p([
              Component.text(
                'No $_radiusLabel measurement is recorded for this category. '
                'Absence is reported, not treated as zero.',
              ),
            ]),
          ])
        else ...[
          div(classes: 'sw-v4__metrics', [
            for (final m in prominent) _metricCard(m),
          ]),
          if (rest.isNotEmpty)
            div(classes: 'sw-v4__rows', [
              for (final m in rest)
                div(classes: 'sw-v4__row', [
                  span([Component.text(m.label)]),
                  span(
                    classes: m.value == null ? 'is-absent' : null,
                    [
                      Component.text(
                        m.value == null
                            ? 'Not available'
                            : '${m.value}${m.unit.isEmpty ? '' : ' ${m.unit}'}',
                      ),
                    ],
                  ),
                ]),
            ]),
        ],
        p(classes: 'sw-v4__tip', [
          Component.text(
            'Source: sitewise_analytics.subject_features · '
            'analysis ${evidence.analysisStatus ?? 'unknown'} · '
            'coverage ${evidence.referenceCoverage ?? 'unknown'} · '
            'snapshot ${evidence.snapshotAt ?? 'not recorded'} · '
            'completeness ${evidence.dataCompletenessPct?.toStringAsFixed(0) ?? '—'}%. '
            'Mapped F&B outlets are not rental-property counts; 0 is a measured '
            'zero and a blank is not recorded.',
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
          span(classes: 'sw-v4__eyebrow', [Component.text('LOCATION INSIGHTS')]),
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
              Component.text('Loading location evidence…'),
            ]);
          }
          return _analysis(snap.data, snap.error);
        },
      ),
    ]);
  }
}
