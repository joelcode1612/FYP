import 'dart:async';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/bloc.dart';
import '../../components/filter_panel.dart';
import '../../components/property_card.dart';
import '../../components/ui.dart';
import '../../data/app_locator.dart';
import '../../layouts/app_layout.dart';

/// Web explore, laid out as the source's `explore.html` with the `map.html`
/// section appended — the target serves both source pages from this one route.
///
/// ```text
/// .page-head        "Explore" · "Commercial properties" · description
/// .filters          keyword · rent/area ranges · type/state/city · verification
/// count line
/// .pgrid            property cards
/// section           "Map & surroundings"
///   .map-layout     .map-pane (layers + pins + legend) | .analysis (.a-card…)
/// ```
///
/// The previous version was a split panel (list on the left, map on the right)
/// with the filter form hidden behind a toggle — a layout from an older mockup,
/// not this design. The filter form is now always visible, as in the source, and
/// the map moved into its own labelled section instead of occupying the whole
/// viewport.
///
/// Two honesty constraints are unchanged:
///  * there is **no map SDK** in either tree, so the surface is the stylised
///    panel the mobile app uses; only the interaction is real;
///  * zoom is **real** — it scales the lat/lng projection, so pins genuinely
///    move and clip.
class ExplorePage extends StatefulComponent {
  /// Open scrolled to the map section (route passes `id == 'map'`).
  final bool startInMap;

  const ExplorePage({super.key, this.startInMap = false});

  @override
  State<ExplorePage> createState() => _ExplorePageState();
}

class _ExplorePageState extends State<ExplorePage> {
  late final EntrepreneurCubit vm;

  /// The structured filter, applied on top of the cubit's query results.
  PropertyFilter filter = PropertyFilter.empty;

  /// Property chosen from a pin, shown in the map's first analysis card.
  String? selectedId;

  /// Real zoom factor applied to the pin projection.
  int zoom = 1;

  static const _zoomLevels = [1, 2, 4];

  @override
  void initState() {
    super.initState();
    vm = AppLocator.newEntrepreneurCubit();
    unawaited(vm.loadExplore());
  }

  @override
  void dispose() {
    unawaited(vm.close());
    super.dispose();
  }

  List<CommercialProperty> get _results => filter.apply(vm.explore);

  /// Listings that can actually be plotted. A listing with no coordinates would
  /// otherwise land at 0,0 in the projection.
  List<CommercialProperty> get _mappable => _results
      .where((prop) => prop.latitude != 0 || prop.longitude != 0)
      .toList();

  CommercialProperty? get _selected {
    final id = selectedId;
    if (id == null) return null;
    for (final p in _results) {
      if (p.id == id) return p;
    }
    return null;
  }

  void _setFilter(PropertyFilter next) => setState(() {
    filter = next;
    if (selectedId != null && !_results.any((prop) => prop.id == selectedId)) {
      selectedId = null;
    }
  });

  void _reset() => setState(() {
    filter = PropertyFilter.empty;
    selectedId = null;
  });

  @override
  Component build(BuildContext context) {
    return CubitBuilder<AppCubit, AppState>(
      cubit: AppLocator.appCubit,
      builder: (context, _) {
        final appCubit = AppLocator.appCubit;
        return CubitBuilder<EntrepreneurCubit, EntrepreneurState>(
          cubit: vm,
          builder: (context, _) {
            return AppLayout(
              role: AppRole.entrepreneur,
              currentRoute: '/entrepreneur/explore',
              title: 'Commercial properties',
              eyebrow: 'Explore',
              subtitle:
                  'Search verified listings. Only administrator-approved and '
                  'currently available properties are shown; pending or rejected '
                  'records are never presented as available.',
              child: vm.loading
                  ? const _Loading()
                  : div(classes: 'stack stack--sections', [
                      _filterSection(),
                      _resultsSection(appCubit),
                      _mapSection(),
                    ]),
            );
          },
        );
      },
    );
  }

  // -------------------------------------------------------------- filter form

  Component _filterSection() => FilterPanel(
    filter: filter,
    source: vm.explore,
    results: _results,
    query: vm.query,
    onQueryChanged: vm.setQuery,
    onChanged: _setFilter,
    onReset: _reset,
  );

  // ------------------------------------------------------------------ results

  Component _resultsSection(AppCubit appCubit) {
    final results = _results;
    if (results.isEmpty) {
      return EmptyState(
        title: 'No properties match these filters',
        body:
            'No approved listing satisfies every active criterion. Widen your '
            'budget or floor-area range, remove a property type, or clear all '
            'filters to see everything available.',
        action: ActionButton('Clear all filters', onClick: _reset),
      );
    }

    return div(classes: 'stack stack--md', [
      p(classes: 'small', [
        Component.text(
          '${results.length} ${results.length == 1 ? 'property' : 'properties'} '
          'match your filters.',
        ),
      ]),
      div(classes: 'pgrid', [
        for (final p in results)
          PropertyCard(
            property: p,
            href: '/entrepreneur/property-detail?id=${p.id}',
            saved: appCubit.isSaved(p.id),
            compared: appCubit.isCompared(p.id),
            onToggleSaved: () => appCubit.toggleSaved(p.id),
            onToggleCompared: () => appCubit.toggleCompared(p.id),
          ),
      ]),
    ]);
  }

  // ---------------------------------------------------------------------- map

  Component _mapSection() {
    final selected = _selected;
    return section(
      classes: 'stack stack--md',
      attributes: const {'id': 'map'},
      [
        div(classes: 'stack', [
          span(classes: 'eyebrow', [Component.text('Location analysis')]),
          h2(classes: 'title-lg', [Component.text('Map & surroundings')]),
          p(classes: 'small', [
            Component.text(
              'Select a pin to inspect its surroundings. Each panel states the '
              'analysis radius and the source of the figure; where a source returned '
              'nothing we say so — "0 records found" and "data unavailable" are '
              'different things and are never mixed up.',
            ),
          ]),
        ]),
        div(classes: 'map-layout', [_mapPane(), _analysisColumn(selected)]),
      ],
    );
  }

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
              'aria-pressed': layer == 'Nearby F&B competitors'
                  ? 'true'
                  : 'false',
            },
            events: events(onClick: () => _toastLayer(layer)),
            [Component.text(layer)],
          ),
      ]),
      div(classes: 'map-canvas', [
        div(classes: 'visual__grid', []),
        if (_mappable.isEmpty)
          span(classes: 'visual__chip', [
            Component.text('No properties to plot'),
          ]),
        for (final p in _mappable)
          button(
            classes: p.id == selectedId ? 'map-pin map-pin--active' : 'map-pin',
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
        // Zoom is real: it re-projects every pin.
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
        _legendItem('lg-comp', 'Competitor'),
        _legendItem('lg-demand', 'Demand generator'),
        _legendItem('lg-transit', 'Transport'),
        _legendItem('lg-pop', 'Population radius'),
      ]),
    ]);
  }

  Component _legendItem(String cls, String label) =>
      span([span(classes: 'lg $cls', []), Component.text(label)]);

  void _toastLayer(String layer) {
    // Layer toggles are presentation-only in the source too: no tile layer is
    // fetched. Selecting the property pin is what drives the analysis column.
    setState(() {});
  }

  // ----------------------------------------------------------- analysis column

  Component _analysisColumn(CommercialProperty? selected) {
    return div(classes: 'analysis', [
      if (selected != null) _selectedCard(selected),
      ..._analysisCards(selected),
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
    p([
      ActionLink(
        'Full details',
        href: '/entrepreneur/property-detail?id=${prop.id}',
        variant: 'secondary',
      ),
    ]),
  ]);

  List<Component> _analysisCards(CommercialProperty? selected) {
    final id = selected?.id;
    final cards = <Component>[];

    if (id == null) {
      cards.add(
        div(classes: 'a-card', [
          h3([Component.text('Select a property')]),
          p(classes: 'what', [
            Component.text(
              'Choose a pin on the map to load its location analysis: population, '
              'nearby competitors, accessibility and the indicators used for '
              'scoring.',
            ),
          ]),
        ]),
      );
      return cards;
    }

    // The cubit loads one analysis at a time, so the column reflects the last
    // `loadAnalysis` call rather than the pin the user just clicked. Show the
    // pending state instead of the previous property's numbers.
    return [
      FutureBuilder<LocationAnalysis?>(
        future: AppLocator.recommendations.analysis(id),
        builder: (context, snap) {
          if (!snap.hasData) {
            return div(classes: 'a-card', [
              div(classes: 'loading', [
                span(classes: 'spinner', []),
                Component.text('Loading location analysis…'),
              ]),
            ]);
          }
          final a = snap.data;
          if (a == null) {
            return div(classes: 'a-card', [
              h3([Component.text('Location analysis')]),
              p(classes: 'what', [
                Component.text('No analysis is available for this property.'),
              ]),
            ]);
          }
          return div(classes: 'analysis', _cardsFor(a));
        },
      ),
    ];
  }

  List<Component> _cardsFor(LocationAnalysis a) {
    final factors = a.factors;
    return [
      // --- Suitability -----------------------------------------------------
      div(classes: 'a-card', [
        h3([Component.text('Suitability')]),
        p(classes: 'what', [
          Component.text(
            'A relative decision-support indicator built from the factors below. '
            'It is not a probability of success or a revenue forecast.',
          ),
        ]),
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
        p(classes: 'meta', [
          Component.text('Computed from the indicators listed at the end. '),
          span(classes: 'prov prov-demo', [Component.text('Demo value')]),
        ]),
      ]),

      // --- Nearby competitors ----------------------------------------------
      div(classes: 'a-card', [
        h3([Component.text('Nearby F&B competitors')]),
        p(classes: 'what', [
          Component.text(
            'Other food and drink operators close to this property. Higher '
            'density means more competition for the same catchment.',
          ),
        ]),
        div(classes: 'stat-row', [
          div(classes: 'stat', [
            strong([Component.text('${a.competitorCount}')]),
            span([Component.text('Records nearby')]),
          ]),
          div(classes: 'stat', [
            strong([Component.text(a.competitorCount == 0 ? '0' : 'Measured')]),
            span([Component.text('Density')]),
          ]),
        ]),
        p(classes: 'what', [Component.text(a.demandSummary)]),
        p(classes: 'meta', [
          Component.text(
            'Method: nearby F&B records within the analysis radius. ',
          ),
          span(classes: 'prov prov-demo', [Component.text('Demo value')]),
        ]),
      ]),

      // --- Socioeconomic ----------------------------------------------------
      if (a.socioeconomicSummary.isNotEmpty)
        div(classes: 'a-card', [
          h3([Component.text('Socioeconomic context')]),
          p(classes: 'what', [
            Component.text(
              'How densely populated the area is and what households there earn.',
            ),
          ]),
          p(classes: 'body', [Component.text(a.socioeconomicSummary)]),
          p(classes: 'meta', [
            Component.text('Source: DOSM household income survey · '),
            span(classes: 'prov prov-demo', [Component.text('Demo value')]),
          ]),
        ]),

      // --- Indicators used for scoring --------------------------------------
      if (factors.isNotEmpty)
        div(classes: 'a-card', [
          h3([Component.text('Location indicators used for scoring')]),
          p(classes: 'what', [
            Component.text(
              'Exactly the spatial values that were passed to the recommendation '
              'engine for this property.',
            ),
          ]),
          ul([
            for (final f in factors)
              li([
                Component.text(
                  '${f.name} — ${f.score.toStringAsFixed(0)}/100 · ${f.rating}',
                ),
              ]),
          ]),
          p(classes: 'meta', [
            Component.text('${factors.length} indicators · '),
            span(classes: 'prov prov-model', [Component.text('Model output')]),
          ]),
        ]),
    ];
  }

  // ------------------------------------------------------------------ helpers

  /// Same projection as the Flutter `SitewiseMapPanel`. Zoom divides the span, so
  /// a higher zoom spreads the same coordinates further apart; pins that fall
  /// outside are clipped by the map's overflow rather than clamped to the edge,
  /// which would pile unrelated properties on top of each other.
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

  /// `7000` -> `RM 7k`. Compact enough for a map label.
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
    Component.text('Loading listings…'),
  ]);
}
