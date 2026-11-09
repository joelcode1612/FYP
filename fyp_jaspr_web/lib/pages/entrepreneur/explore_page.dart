import 'dart:async';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/filter_panel.dart';
import '../../components/map_dom.dart';
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
/// count line        + sort control
/// .pgrid            property cards
/// section           "Map & surroundings"
///   .map-layout     .map-pane (layers + pins + legend) | .analysis (.a-card…)
/// ```
///
/// One sequence drives everything: `_results` is the filtered-and-sorted list,
/// and both the grid and the map read it, so the two can never disagree.
/// Selecting a pin highlights its card; a card's Locate button centers its pin
/// and scrolls to the map section.
///
/// Honesty constraints:
///  * there is **no map SDK** in either tree, so the surface is the stylised
///    projection panel the mobile app uses — but the interactions are real:
///    zoom re-projects every pin, drag pans the view, and dense cells collapse
///    into count clusters rather than a pile of overlapping pins;
///  * pins that fall outside the canvas are clipped by the overflow, never
///    clamped onto unrelated positions;
///  * where the dataset has no coordinates the map says so instead of plotting
///    nothing silently.
@client
class ExplorePage extends StatefulComponent {
  /// Open scrolled to the map section (route passes `id == 'map'`).
  final bool startInMap;

  const ExplorePage({super.key, this.startInMap = false});

  @override
  State<ExplorePage> createState() => _ExplorePageState();
}

class _ExplorePageState extends State<ExplorePage> {
  /// Current notifier state. Safe anywhere: the root build watches the whole
  /// state, so any change re-runs this build and these reads are never stale
  /// inside it.
  EntrepreneurState get _model => context.read(entrepreneurNotifierProvider);

  /// The structured filter, applied on top of the view model's query results.
  PropertyFilter filter = PropertyFilter.empty;

  /// Sort applied after filtering — the grid and the map read the same order.
  ExploreSort sort = ExploreSort.imported;

  /// Property chosen from a pin, shown in the map popup and highlighted in
  /// the grid.
  String? selectedId;

  /// Analysis future for the current selection, created once per selection:
  /// re-creating it on every rebuild (each pan frame, each filter edit) would
  /// re-request the analysis and flicker the column back to its loading state.
  Future<LocationAnalysis?>? _analysisFuture;

  /// Real zoom factor applied to the pin projection.
  int zoom = 1;

  /// Pan offset in percent of the canvas, added on top of the projection.
  double panX = 0;
  double panY = 0;

  // Drag-to-pan bookkeeping.
  bool _dragging = false;
  double _dragClientX = 0;
  double _dragClientY = 0;
  double _panStartX = 0;
  double _panStartY = 0;

  Timer? _queryDebounce;
  int _visibleLimit = 24;

  static const _zoomLevels = [1, 2, 4];

  /// Cluster cell size as a percent of the canvas: pins landing in the same
  /// cell collapse into one count pill.
  static const double _clusterCell = 8.0;

  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      if (!mounted) return;
      unawaited(
        context.read(entrepreneurNotifierProvider.notifier).loadExplore(),
      );
    });
  }

  @override
  void dispose() {
    _queryDebounce?.cancel();
    super.dispose();
  }

  List<CommercialProperty> get _results =>
      sortForExplore(filter.apply(_model.explore), sort);

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
    _visibleLimit = 24;
    filter = next;
    _clearSelectionIfMissing();
  });

  void _reset() => setState(() {
    _visibleLimit = 24;
    filter = PropertyFilter.empty;
    selectedId = null;
    _analysisFuture = null;
  });

  void _clearSelectionIfMissing() {
    if (selectedId != null && !_results.any((prop) => prop.id == selectedId)) {
      selectedId = null;
      _analysisFuture = null;
    }
  }

  void _setSort(ExploreSort next) => setState(() => sort = next);

  void _showAll() => setState(() {
    zoom = _zoomLevels.first;
    panX = 0;
    panY = 0;
  });

  /// Selects [prop] for the map popup and the grid highlight, making sure the
  /// highlighted card is rendered past the visible limit.
  void _select(CommercialProperty prop) => setState(() {
    selectedId = prop.id;
    final future = AppLocator.recommendations.analysis(prop.id);
    // The repository reports unavailable analysis by failing this future. The
    // FutureBuilder subscribes only on the next rebuild, so without a listener
    // attached now the error escapes to the zone as uncaught.
    unawaited(future.then<void>((_) {}, onError: (Object e, StackTrace s) {}));
    _analysisFuture = future;
    final index = _results.indexWhere((r) => r.id == prop.id);
    if (index >= _visibleLimit) _visibleLimit = index + 1;
  });

  /// Saves/removes a shortlist property. A signed-in account persists to the
  /// server first and the shortlist only moves once the server accepted the
  /// change, so what the bookmark shows is what the account holds. A visitor
  /// keeps the cookie-backed selection. On a failed request nothing changes.
  Future<void> _toggleSaved(String id) async {
    final notifier = context.read(appNotifierProvider.notifier);
    if (!AppLocator.isSignedIn) {
      notifier.toggleSaved(id);
      return;
    }
    final savedNow = context.read(appNotifierProvider).saved.contains(id);
    final failure = await AppLocator.persistToggleSaved(
      id,
      wantSaved: !savedNow,
    );
    if (failure != null) return;
    notifier.toggleSaved(id);
  }

  /// Locates a listing on the map: select it, pan the canvas so its pin sits
  /// centered, then bring the map section into view.
  void _locate(CommercialProperty prop) {
    _select(prop);
    final (left, top) = _project(prop, zoom);
    setState(() {
      panX = (50 - left).clamp(-50, 50).toDouble();
      panY = (50 - top).clamp(-50, 50).toDouble();
    });
    Future.delayed(const Duration(milliseconds: 80), () {
      scrollDomIntoView('map');
    });
  }

  void _onQueryChanged(String value) {
    // The notifier refetches and notifies for every query change, which
    // would flash the whole page per keystroke — settle first.
    _queryDebounce?.cancel();
    _queryDebounce = Timer(const Duration(milliseconds: 250), () {
      context.read(entrepreneurNotifierProvider.notifier).setQuery(value);
    });
  }

  @override
  Component build(BuildContext context) {
    final state = context.watch(entrepreneurNotifierProvider);
    final saved = context.watch(appNotifierProvider.select((app) => app.saved));
    final compared = context.watch(
      appNotifierProvider.select((app) => app.compared),
    );

    return AppLayout(
      role: AppRole.entrepreneur,
      currentRoute: '/entrepreneur/explore',
      title: 'Commercial properties',
      eyebrow: 'Explore',
      subtitle:
          'Accepted property records from your imported workbook. Dataset '
          'quality checks do not establish current availability or administrator verification.',
      child: state.loading
          ? const _Loading()
          : state.error != null
          ? EmptyState(
              title: 'Properties could not load',
              body: state.error!,
              action: ActionButton(
                'Try again',
                onClick: () => context
                    .read(entrepreneurNotifierProvider.notifier)
                    .loadExplore(),
              ),
            )
          : div(classes: 'stack stack--sections', [
              _filterSection(),
              _resultsSection(saved, compared),
              _mapSection(),
            ]),
    );
  }

  // -------------------------------------------------------------- filter form

  Component _filterSection() => FilterPanel(
    filter: filter,
    source: _model.explore,
    results: _results,
    query: _model.query,
    onQueryChanged: _onQueryChanged,
    onChanged: _setFilter,
    onReset: _reset,
  );

  // ------------------------------------------------------------------ results

  Component _resultsSection(Set<String> saved, Set<String> compared) {
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
      div(classes: 'explore__results-head', [
        p(classes: 'small', [
          Component.text(
            '${results.length} ${results.length == 1 ? 'property' : 'properties'} '
            'match your filters.',
          ),
        ]),
        div(classes: 'explore__sort', [
          span(classes: 'field__label', [Component.text('Sort by')]),
          select(
            attributes: const {'aria-label': 'Sort listings'},
            events: events<List<String>>(
              onInput: (values) => _setSort(
                values.isNotEmpty
                    ? ExploreSort.values.byName(values.first)
                    : ExploreSort.imported,
              ),
            ),
            [
              for (final s in ExploreSort.values)
                option(
                  value: s.name,
                  attributes: {if (s == sort) 'selected': ''},
                  [Component.text(_sortLabel(s))],
                ),
            ],
          ),
        ]),
      ]),
      div(classes: 'pgrid', [
        for (final p in results.take(_visibleLimit))
          PropertyCard(
            property: p,
            href: '/entrepreneur/property-detail?id=${p.id}',
            assessHref: '/entrepreneur/assessment?id=${p.id}',
            selected: p.id == selectedId,
            anchorId: 'pcard-${p.id}',
            saved: saved.contains(p.id),
            compared: compared.contains(p.id),
            onToggleSaved: () => _toggleSaved(p.id),
            onToggleCompared: () =>
                context.read(appNotifierProvider.notifier).toggleCompared(p.id),
            onLocate: () => _locate(p),
          ),
      ]),
      if (results.length > _visibleLimit)
        ActionButton(
          'Show more properties',
          onClick: () => setState(() => _visibleLimit += 24),
        ),
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
              'Drag to pan, zoom to spread the pins apart, and select a pin to '
              'inspect its surroundings. Where a source returned nothing we say '
              'so — "0 records found" and "data unavailable" are different '
              'things and are never mixed up.',
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
    final pins = _mapPins();
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
      div(
        classes: _dragging ? 'map-canvas map-canvas--dragging' : 'map-canvas',
        events: {
          'pointerdown': _onPointerDown,
          'pointermove': _onPointerMove,
          'pointerup': (_) => _onPointerEnd(),
          'pointercancel': (_) => _onPointerEnd(),
          'pointerleave': (_) => _onPointerEnd(),
        },
        [
          div(classes: 'visual__grid', []),
          if (pins.isEmpty)
            div(classes: 'explore__map-empty', [
              Icon('location_off', size: 'lg'),
              strong([Component.text('Nothing to plot')]),
              p(classes: 'small', [
                Component.text(
                  'None of the matching listings has coordinates in the '
                  'dataset, so there is nothing to place on the map. The '
                  'listings above are unaffected.',
                ),
              ]),
            ]),
          ...pins,
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
            button(
              classes: 'explore__zoom-btn',
              attributes: {
                'type': 'button',
                'aria-label': 'Show all properties',
                'title': 'Show all properties',
              },
              events: events(onClick: _showAll),
              [Icon('public')],
            ),
          ]),
          if (zoom > 1)
            span(classes: 'explore__map-zoom', [Component.text('$zoom×')]),
        ],
      ),
      div(classes: 'map-legend', [
        _legendItem('lg-prop', 'Property'),
        _legendItem('lg-comp', 'Competitor'),
        _legendItem('lg-demand', 'Demand generator'),
        _legendItem('lg-transit', 'Transport'),
        _legendItem('lg-pop', 'Population radius'),
      ]),
    ]);
  }

  /// Buckets the mappable listings into grid cells of [_clusterCell] percent.
  /// A cell with a single pin renders that pin; a shared cell renders one
  /// count cluster instead of a pile of overlapping pins.
  List<Component> _mapPins() {
    final cells = <String, List<CommercialProperty>>{};
    for (final p in _mappable) {
      final (left, top) = _project(p, zoom);
      final key =
          '${(left / _clusterCell).floor()}:${(top / _clusterCell).floor()}';
      (cells[key] ??= []).add(p);
    }
    return [
      for (final group in cells.values)
        group.length == 1 ? _pin(group.single) : _cluster(group),
    ];
  }

  Component _pin(CommercialProperty p) => button(
    classes: p.id == selectedId ? 'map-pin map-pin--active' : 'map-pin',
    attributes: {
      'type': 'button',
      'style': _pinStyle(p, zoom, panX, panY),
      'title': p.title,
      'aria-label': '${p.title}, ${_compactRm(p.rentalRm)}',
    },
    events: events(onClick: () => _select(p)),
    [
      Icon('place', size: 'sm'),
      span(classes: 'map-pin__price', [Component.text(_compactRm(p.rentalRm))]),
    ],
  );

  Component _cluster(List<CommercialProperty> group) {
    final anchor = group.first;
    final (left, top) = _project(anchor, zoom);
    final active = group.any((g) => g.id == selectedId);
    return button(
      classes: active ? 'map-cluster map-cluster--active' : 'map-cluster',
      attributes: {
        'type': 'button',
        'style':
            'left:${(left + panX).toStringAsFixed(2)}%;top:${(top + panY).toStringAsFixed(2)}%;',
        'title': '${group.length} properties share this area',
        'aria-label':
            'Cluster of ${group.length} properties; zoom in to separate them',
      },
      events: events(onClick: () => _expandCluster(group)),
      [Component.text('${group.length}')],
    );
  }

  void _expandCluster(List<CommercialProperty> group) {
    if (zoom < _zoomLevels.last) {
      setState(() => zoom = _zoomLevels[_zoomLevels.indexOf(zoom) + 1]);
    } else {
      // At maximum zoom the members stay merged — select the first record
      // rather than pretending the cluster opened up.
      _select(group.first);
    }
  }

  // Drag-to-pan. The browser-specific coordinate reads live behind the
  // stub/browser split in `map_dom.dart`; the 3px threshold keeps a pin click
  // from being misread as a pan.
  void _onPointerDown(Object e) {
    setState(() {
      _dragging = true;
      _dragClientX = pointerClientX(e);
      _dragClientY = pointerClientY(e);
      _panStartX = panX;
      _panStartY = panY;
    });
  }

  void _onPointerMove(Object e) {
    if (!_dragging) return;
    final dx = pointerClientX(e) - _dragClientX;
    final dy = pointerClientY(e) - _dragClientY;
    if (dx.abs() < 3 && dy.abs() < 3) return;
    setState(() {
      // px -> percent of the canvas, clamped so the projection cannot be
      // dragged arbitrarily far off.
      panX = (_panStartX + dx / windowInnerWidth() * 100)
          .clamp(-50, 50)
          .toDouble();
      panY = (_panStartY + dy / windowInnerHeight() * 100)
          .clamp(-50, 50)
          .toDouble();
    });
  }

  void _onPointerEnd() {
    if (!_dragging) return;
    setState(() => _dragging = false);
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
    p(classes: 'meta', [Component.text('#${prop.id} · ${prop.propertyType}')]),
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
        'View listing',
        href: '/entrepreneur/property-detail?id=${prop.id}',
        variant: 'secondary',
      ),
    ]),
  ]);

  List<Component> _analysisCards(CommercialProperty? selected) {
    final id = selected?.id;
    final future = _analysisFuture;

    if (id == null || future == null) {
      return [
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
      ];
    }

    return [
      FutureBuilder<LocationAnalysis?>(
        future: future,
        builder: (context, snap) {
          if (!snap.hasData) {
            // A failed request is "no analysis available", not a spinner: the
            // web tree has no analysis backend and must say so.
            if (snap.hasError) {
              return div(classes: 'a-card', [
                h3([Component.text('Location analysis')]),
                p(classes: 'what', [
                  Component.text('No analysis is available for this property.'),
                ]),
              ]);
            }
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

  /// Same projection as the Flutter `SitewiseMapPanel`. Zoom divides the span,
  /// so a higher zoom spreads the same coordinates further apart; pan shifts
  /// the result by a percent of the canvas. Pins that fall outside are clipped
  /// by the map's overflow rather than clamped to the edge, which would pile
  /// unrelated properties on top of each other.
  static (double, double) _project(CommercialProperty prop, int zoom) {
    final x = (prop.longitude - 100.3) / (3.5 / zoom);
    final y = -((prop.latitude - 1.5) / (4.0 / zoom));
    final left = (x + 1) / 2 * 100;
    final top = (1 - y) / 2 * 100;
    return (left, top);
  }

  static String _pinStyle(
    CommercialProperty prop,
    int zoom,
    double panX,
    double panY,
  ) {
    final (left, top) = _project(prop, zoom);
    return 'left:${(left + panX).toStringAsFixed(2)}%;'
        'top:${(top + panY).toStringAsFixed(2)}%;';
  }

  static String _sortLabel(ExploreSort s) => switch (s) {
    ExploreSort.imported => 'Default order',
    ExploreSort.rentalLow => 'Rent: low to high',
    ExploreSort.rentalHigh => 'Rent: high to low',
    ExploreSort.areaLarge => 'Floor area: large first',
    ExploreSort.areaSmall => 'Floor area: small first',
  };

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

/// Sort orders for the explore results. `imported` keeps the dataset order the
/// API returned; the rest sort on real fields only.
enum ExploreSort { imported, rentalLow, rentalHigh, areaLarge, areaSmall }

/// Applies [sort] to [input]. Dart's sort is not stable, so ties break on id —
/// the grid and the map read the same deterministic sequence.
List<CommercialProperty> sortForExplore(
  List<CommercialProperty> input,
  ExploreSort sort,
) {
  if (sort == ExploreSort.imported) return List.of(input);
  return [...input]..sort((x, y) {
    final primary = switch (sort) {
      ExploreSort.rentalLow => x.rentalRm.compareTo(y.rentalRm),
      ExploreSort.rentalHigh => y.rentalRm.compareTo(x.rentalRm),
      ExploreSort.areaLarge => y.sizeSqft.compareTo(x.sizeSqft),
      ExploreSort.areaSmall => x.sizeSqft.compareTo(y.sizeSqft),
      ExploreSort.imported => 0,
    };
    return primary != 0 ? primary : x.id.compareTo(y.id);
  });
}

class _Loading extends StatelessComponent {
  const _Loading();

  @override
  Component build(BuildContext context) => div(classes: 'loading', [
    span(classes: 'spinner', []),
    Component.text('Loading listings…'),
  ]);
}
