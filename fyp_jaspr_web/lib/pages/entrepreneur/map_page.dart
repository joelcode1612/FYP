import 'dart:async';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/ui.dart';
import '../../data/app_locator.dart';
import '../../layouts/app_layout.dart';

/// Standalone map and location analysis, laid out as the source's `map.html`.
///
/// ```text
/// .page-head   "Location analysis" · "Map & surroundings"
/// .map-layout
///   .map-pane  layer bar · pins (real zoom) · legend
///   .analysis  selected property + aggregate location intelligence
/// ```
///
/// The shared dataset has no point-level competitor, demand-generator or
/// transit records and neither app has a map SDK, so the surface is the same
/// stylised Klang Valley projection the Explore page uses. Layer toggles are
/// disabled and the page says why; the analysis column renders every aggregate
/// figure the service actually returns.
@client
class MapPage extends StatefulComponent {
  /// A property chosen from the `?id=` query param, if any.
  final String? initialId;

  const MapPage({super.key, this.initialId});

  @override
  State<MapPage> createState() => _MapPageState();
}

class _MapPageState extends State<MapPage> {
  /// Current notifier state; safe anywhere because the root build watches the
  /// whole state.
  EntrepreneurState get _model => context.read(entrepreneurNotifierProvider);

  String? selectedId;
  int zoom = 1;

  static const _zoomLevels = [1, 2, 4];

  @override
  void initState() {
    super.initState();
    selectedId = component.initialId;
    Future.microtask(() {
      if (!mounted) return;
      unawaited(
        context.read(entrepreneurNotifierProvider.notifier).loadExplore(),
      );
    });
  }

  List<CommercialProperty> get _properties => _model.explore
      .where((property) => property.latitude != 0 || property.longitude != 0)
      .toList();

  CommercialProperty? get _selected {
    final list = _properties;
    if (list.isEmpty) return null;
    final id = selectedId;
    if (id != null) {
      for (final p in list) {
        if (p.id == id) return p;
      }
    }
    return list.first;
  }

  @override
  Component build(BuildContext context) {
    final state = context.watch(entrepreneurNotifierProvider);
    final selected = _selected;
    return AppLayout(
      role: AppRole.entrepreneur,
      currentRoute: '/entrepreneur/map',
      title: 'Map & surroundings',
      eyebrow: 'Location analysis',
      subtitle:
          'Select a pin to inspect its surroundings. Each panel states '
          'the analysis radius and the source of the figure; where a '
          'source returned nothing we say so — “0 records found” and '
          '“data unavailable” are different things and are never mixed '
          'up.',
      child: state.loading
          ? const _Loading()
          : state.error != null
          ? EmptyState(
              title: 'Could not load the map',
              body:
                  'The shared property service did not return '
                  'listings, so there is nothing to plot yet.',
              action: ActionButton(
                'Try again',
                onClick: () => context
                    .read(entrepreneurNotifierProvider.notifier)
                    .loadExplore(),
              ),
            )
          : _properties.isEmpty
          ? const EmptyState(
              title: 'No available properties',
              body: 'There are no approved available listings to map yet.',
              action: ActionLink(
                'Back to explore',
                href: '/entrepreneur/explore',
                variant: 'primary',
              ),
            )
          : div(classes: 'stack stack--sections', [
              div(classes: 'notice notice-warn', [
                Component.text(
                  'Point-level competitor, demand-generator and transit '
                  'layers are not present in the shared dataset. The '
                  'map plots approved listings only; the aggregate '
                  'figures for the selected property are shown below.',
                ),
              ]),
              div(classes: 'map-layout', [
                _mapPane(),
                _analysisColumn(selected),
              ]),
            ]),
    );
  }

  // ---------------------------------------------------------------------- map

  Component _mapPane() {
    final canZoomIn = zoom < _zoomLevels.last;
    final canZoomOut = zoom > _zoomLevels.first;
    return div(classes: 'map-pane', [
      div(classes: 'layer-bar', [
        for (final layer in const [
          'Nearby F&B competitors',
          'Demand generators',
          'Transport',
          'Population radius',
        ])
          button(
            classes: 'layer-toggle',
            attributes: {
              'type': 'button',
              'aria-pressed': 'false',
              'disabled': 'disabled',
              'title':
                  'Unavailable: the shared dataset has no point-level $layer records.',
            },
            [Component.text(layer)],
          ),
      ]),
      div(classes: 'map-canvas', [
        div(classes: 'visual__grid', []),
        span(classes: 'visual__chip', [
          Component.text('${_properties.length} approved listings'),
        ]),
        for (final p in _properties)
          button(
            classes: p.id == _selected?.id
                ? 'map-pin map-pin--active'
                : 'map-pin',
            attributes: {
              'type': 'button',
              'style': _pinPosition(p, zoom),
              'title': p.title,
              'aria-label': '${p.title}, ${_compactRm(p.rentalRm)}',
            },
            events: events(onClick: () => setState(() => selectedId = p.id)),
            [
              Icon('place', size: 'sm'),
              span(classes: 'map-pin__price', [
                Component.text(_compactRm(p.rentalRm)),
              ]),
            ],
          ),
        div(classes: 'explore__zoom', [
          button(
            classes: canZoomIn
                ? 'explore__zoom-btn'
                : 'explore__zoom-btn is-disabled',
            attributes: {'type': 'button', 'aria-label': 'Zoom in'},
            events: events(
              onClick: canZoomIn
                  ? () => setState(
                      () => zoom = _zoomLevels[_zoomLevels.indexOf(zoom) + 1],
                    )
                  : null,
            ),
            [Icon('add')],
          ),
          button(
            classes: canZoomOut
                ? 'explore__zoom-btn'
                : 'explore__zoom-btn is-disabled',
            attributes: {'type': 'button', 'aria-label': 'Zoom out'},
            events: events(
              onClick: canZoomOut
                  ? () => setState(
                      () => zoom = _zoomLevels[_zoomLevels.indexOf(zoom) - 1],
                    )
                  : null,
            ),
            [Icon('remove')],
          ),
        ]),
        if (zoom > 1)
          span(classes: 'explore__map-zoom', [Component.text('$zoom×')]),
      ]),
      div(classes: 'map-legend', [
        _legendItem('lg-prop', 'Property'),
        _legendItem('lg-comp', 'Competitor (unavailable)'),
        _legendItem('lg-demand', 'Demand generator (unavailable)'),
        _legendItem('lg-transit', 'Transport (unavailable)'),
        _legendItem('lg-pop', 'Population radius (unavailable)'),
      ]),
    ]);
  }

  Component _legendItem(String cls, String label) =>
      span([span(classes: 'lg $cls', []), Component.text(label)]);

  // ----------------------------------------------------------- analysis column

  Component _analysisColumn(CommercialProperty? selected) {
    if (selected == null) {
      return div(classes: 'analysis', [
        const EmptyState(
          title: 'Select a property',
          body: 'Choose a pin on the map to load its location analysis.',
        ),
      ]);
    }

    return div(classes: 'analysis', [
      _selectedCard(selected),
      FutureBuilder<LocationAnalysis>(
        future: AppLocator.recommendations.analysis(selected.id),
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return div(classes: 'a-card', [
              div(classes: 'loading', [
                span(classes: 'spinner', []),
                Component.text('Loading location analysis…'),
              ]),
            ]);
          }
          if (!snap.hasData) {
            return div(classes: 'a-card', [
              h3([Component.text('Location analysis')]),
              p(classes: 'what', [
                Component.text(
                  'No aggregate analysis is available for this property.',
                ),
              ]),
            ]);
          }
          return div(classes: 'stack stack--sm', _cardsFor(snap.data!));
        },
      ),
    ]);
  }

  Component _selectedCard(CommercialProperty prop) => div(classes: 'a-card', [
    h3([Component.text(prop.title)]),
    p(classes: 'what', [
      Component.text(
        '${prop.address}, ${prop.city} · ${prop.rentalDisplay} · '
        '${prop.sizeSqft.toStringAsFixed(0)} sq ft',
      ),
    ]),
    div(classes: 'chips', [
      StatusBadge(
        'Verification: ${prop.verification.label.toLowerCase()}',
        tone: toneForVerification(prop.verification),
      ),
      StatusBadge(
        'Suitability: ${prop.suitabilityScore.toStringAsFixed(0)}/100',
        tone: _scoreTone(prop.suitabilityScore),
      ),
    ]),
    div(classes: 'actions-row', [
      ActionLink(
        'Full details',
        href: '/entrepreneur/property-detail?id=${prop.id}',
        variant: 'secondary',
      ),
      ActionLink(
        'Why this score',
        href: '/entrepreneur/explanation?property=${prop.id}',
        variant: 'secondary',
      ),
      ActionLink(
        'Location report',
        href: '/entrepreneur/report?id=${prop.id}',
        variant: 'secondary',
      ),
    ]),
  ]);

  List<Component> _cardsFor(LocationAnalysis a) {
    final competition = _factor(a, const ['Competition']);
    final population = _factor(a, const ['Population']);
    final accessibility = _factor(a, const ['Accessibility', 'Transportation']);
    final demand = _factor(a, const ['Demand']);

    return [
      _card(
        'Suitability',
        'A relative decision-support indicator built from the factors below. '
            'It is not a probability of success or a revenue forecast.',
        div(classes: 'stat-row', [
          div(classes: 'stat', [
            strong([Component.text(a.suitabilityScore.toStringAsFixed(0))]),
            span([Component.text('Out of 100')]),
          ]),
          div(classes: 'stat', [
            strong([Component.text(a.verdict)]),
            span([Component.text('Verdict')]),
          ]),
        ]),
        'Computed from the indicators listed at the end.',
      ),

      _card(
        'Nearby F&B competitors',
        'Other food and drink operators close to this property. Higher '
            'density means more competition for the same catchment.',
        div(classes: 'stat-row', [
          div(classes: 'stat', [
            strong([Component.text('${a.competitorCount}')]),
            span([Component.text('Records nearby')]),
          ]),
        ]),
        competition == null
            ? 'The competition factor was not returned for this property.'
            : '${competition.rating} · ${competition.evidence}',
        footnote:
            'Aggregate count only. Exact competitor coordinates are not in the '
            'shared dataset, so no competitor pins are drawn.',
      ),

      _card(
        'Accessibility',
        'How easy the property is to reach by road and by public transport.',
        accessibility == null
            ? p(classes: 'what', [
                Component.text('The accessibility factor was not returned.'),
              ])
            : div(classes: 'stat-row', [
                div(classes: 'stat', [
                  strong([Component.text(accessibility.rating)]),
                  span([Component.text('Rating')]),
                ]),
              ]),
        accessibility?.evidence ??
            'No accessibility evidence was returned for this property.',
        footnote:
            'Aggregate rating only. Nearest transit stops are not in the shared '
            'dataset, so no transit pins are drawn.',
      ),

      _card(
        'Demand generators',
        'Offices, colleges and residential blocks that create customer demand.',
        demand == null
            ? p(classes: 'what', [
                Component.text('The demand factor was not returned.'),
              ])
            : div(classes: 'stat-row', [
                div(classes: 'stat', [
                  strong([Component.text(demand.rating)]),
                  span([Component.text('Rating')]),
                ]),
              ]),
        a.demandSummary,
        footnote:
            'Aggregate summary only. Individual demand-generator coordinates '
            'are not in the shared dataset.',
      ),

      if (a.socioeconomicSummary.isNotEmpty)
        _card(
          'Socioeconomic context',
          'How densely populated the area is and what households there earn.',
          p(classes: 'body', [Component.text(a.socioeconomicSummary)]),
          'Source: DOSM household income survey · demo value',
        ),

      if (population != null)
        _card(
          'Population',
          'The resident catchment used by the recommendation engine.',
          div(classes: 'stat-row', [
            div(classes: 'stat', [
              strong([Component.text(population.rating)]),
              span([Component.text('Rating')]),
            ]),
            div(classes: 'stat', [
              strong([Component.text(population.score.toStringAsFixed(0))]),
              span([Component.text('Score')]),
            ]),
          ]),
          population.evidence,
          footnote:
              'Aggregate rating only. 500 m / 1 km radius counts are not in the '
              'shared dataset.',
        ),

      if (a.factors.isNotEmpty)
        _card(
          'Location indicators used for scoring',
          'Exactly the spatial values that were passed to the recommendation '
              'engine for this property.',
          ul([
            for (final f in a.factors)
              li([
                Component.text(
                  '${f.name} — ${f.score.toStringAsFixed(0)}/100 · '
                  '${f.rating} · ${f.impact}',
                ),
              ]),
          ]),
          '${a.factors.length} indicators · model output',
        ),

      _card(
        'Map layers not available',
        'The following source layers are absent, so their toggles are disabled '
            'rather than rendered as empty-but-live.',
        ul([
          li([Component.text('Point-level competitor locations')]),
          li([Component.text('Demand-generator locations')]),
          li([Component.text('Nearest transit stops')]),
          li([Component.text('500 m / 1 km population radius counts')]),
        ]),
        'Aggregate figures above still come from the shared service.',
      ),
    ];
  }

  Component _card(
    String title,
    String description,
    Component body,
    String footer, {
    String? footnote,
  }) {
    return div(classes: 'a-card', [
      h3([Component.text(title)]),
      p(classes: 'what', [Component.text(description)]),
      body,
      p(classes: 'meta', [Component.text(footer)]),
      if (footnote != null) p(classes: 'what', [Component.text(footnote)]),
    ]);
  }

  LocationFactor? _factor(LocationAnalysis a, List<String> names) {
    for (final f in a.factors) {
      if (names.contains(f.name)) return f;
    }
    return null;
  }

  // ------------------------------------------------------------------ helpers

  /// Same projection as Explore and the Flutter `SitewiseMapPanel`.
  static String _pinPosition(CommercialProperty prop, int zoom) {
    final x = (prop.longitude - 100.3) / (3.5 / zoom);
    final y = -((prop.latitude - 1.5) / (4.0 / zoom));
    final left = ((x + 1) / 2 * 100).toStringAsFixed(2);
    final top = ((1 - y) / 2 * 100).toStringAsFixed(2);
    return 'left:$left%;top:$top%;';
  }

  static String _scoreTone(double score) {
    if (score >= 75) return 'success';
    if (score >= 55) return 'action';
    if (score >= 40) return 'warning';
    return 'danger';
  }

  static String _compactRm(double v) {
    if (v >= 1000) {
      final k = v / 1000;
      final text = k == k.roundToDouble()
          ? k.toStringAsFixed(0)
          : k.toStringAsFixed(1);
      return 'RM ${text}k';
    }
    return 'RM ${v.toStringAsFixed(0)}';
  }
}

class _Loading extends StatelessComponent {
  const _Loading();

  @override
  Component build(BuildContext context) => div(classes: 'loading', [
    span(classes: 'spinner', []),
    Component.text('Loading map…'),
  ]);
}
