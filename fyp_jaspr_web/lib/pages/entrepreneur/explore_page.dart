import 'dart:async';
import 'dart:convert';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/combined_explore_dom.dart';
import '../../components/filter_panel.dart';
import '../../components/map_dom.dart';
import '../../components/property_card.dart';
import '../../components/ui.dart';
import '../../data/app_locator.dart';
import '../../layouts/app_layout.dart';

/// Combined SiteWise Entrepreneur Explore page.
///
/// Layout: filter controls across the top, then a real Leaflet map on the left
/// and commercial-property listings on the right. One FastAPI-backed inventory
/// drives both views. Selecting a property activates a 500 m / 1 km catchment.
///
/// Data flow (PostgreSQL → FastAPI → shared_logic → Riverpod → this page →
/// Leaflet): the inventory is the authenticated catalogue repository
/// (`/api/v1/catalog/properties` via [ApiPropertyRepository]) surfaced through
/// `entrepreneurNotifierProvider`. The browser bridge in
/// `combined_explore_dom.dart` only forwards a selected property id back into
/// Dart — every record, filter, radius and distance lives in Dart/shared_logic
/// state, and the JS layer never holds data of its own.
///
/// Nearby commercial properties are computed with the shared great-circle
/// helper ([GeoUtils.haversineMeters]) over the already-loaded filtered set —
/// the same validated Haversine the mobile app uses — and are a DIFFERENT
/// dataset from the F&B competitor research counts, which stay on their own
/// analysis endpoint and are never shown as property counts.
///
/// The optional public-transport layer fetches OpenStreetMap/Overpass records
/// from the browser only after a user opts in (cached, user-initiated, honest
/// empty/error states); OSM stops are NOT live service schedules.
@client
class ExplorePage extends StatefulComponent {
  /// Retained for existing app.dart route compatibility: `?id=map` scrolls to
  /// the map section, and the legacy `/entrepreneur/map` route reuses this
  /// page with [startInMap] set.
  final bool startInMap;

  /// Property id from `?id=` to preselect (marker + circle + listing).
  final String? initialPropertyId;

  const ExplorePage({
    super.key,
    this.startInMap = false,
    this.initialPropertyId,
  });

  @override
  State<ExplorePage> createState() => _ExplorePageState();
}

class _ExplorePageState extends State<ExplorePage> {
  /// Current notifier state. Safe anywhere: the root build watches the whole
  /// state, so any change re-runs this build and these reads are never stale
  /// inside it.
  EntrepreneurState get _model => context.read(entrepreneurNotifierProvider);

  PropertyFilter filter = PropertyFilter.empty;
  ExploreSort sort = ExploreSort.imported;

  /// Selected property id (marker click, card Locate, or `?id=`).
  String? selectedId;

  /// Applied catchment radius. 500 m and 1 km are the documented research
  /// radii; the 1 km count CONTAINS the 500 m ring.
  int radiusM = 1000;
  bool showTransport = false;
  int visibleLimit = 24;
  Timer? _queryDebounce;
  Future<LocationAnalysis?>? _analysisFuture;

  // Per-property request guard: a second tap cannot reverse a pending save.
  final Set<String> _savingPropertyIds = <String>{};
  String? _saveError;

  @override
  void initState() {
    super.initState();
    final initialId = component.initialPropertyId;
    if (initialId != null && initialId.isNotEmpty) {
      selectedId = initialId;
      _analysisFuture = _readAnalysis(initialId);
    }
    Future.microtask(() {
      if (!mounted) return;
      unawaited(
        context.read(entrepreneurNotifierProvider.notifier).loadExplore(),
      );
      if (component.startInMap) {
        Future.delayed(const Duration(milliseconds: 400), () {
          if (mounted) scrollDomIntoView('swcx-map-section');
        });
      }
    });
  }

  @override
  void dispose() {
    _queryDebounce?.cancel();
    super.dispose();
  }

  /// The inventory is provided by the existing FastAPI catalogue repository,
  /// not a hardcoded JavaScript array or an Excel-only snapshot.
  // Filter/sort once per source list + criteria instead of repeating the
  // O(n log n) work for the toolbar, map, cards and filter panel each build.
  List<CommercialProperty>? _filteredMemo;
  List<CommercialProperty>? _filteredSource;
  PropertyFilter? _filteredCriteria;
  ExploreSort? _filteredSort;

  List<CommercialProperty> get _filtered {
    final source = _model.explore;
    if (identical(source, _filteredSource) &&
        identical(filter, _filteredCriteria) &&
        sort == _filteredSort &&
        _filteredMemo != null) {
      return _filteredMemo!;
    }
    final result = sortForExplore(filter.apply(source), sort);
    _filteredSource = source;
    _filteredCriteria = filter;
    _filteredSort = sort;
    return _filteredMemo = result;
  }

  /// Coordinates usable for plotting and distance math. The (0, 0) pair is
  /// this codebase's "no coordinates" sentinel; a listing without coordinates
  /// is skipped, never placed at an invented location.
  static bool _validPoint(CommercialProperty p) =>
      p.latitude.isFinite &&
          p.longitude.isFinite &&
          p.latitude.abs() <= 90 &&
          p.longitude.abs() <= 180 &&
          p.hasCoordinates;

  /// Great-circle distance in metres from the shared_logic helper — the same
  /// implementation the mobile app uses. This is NOT a walking or driving
  /// route, and every UI label says so.
  static double? _metres(CommercialProperty a, CommercialProperty b) =>
      GeoUtils.haversineMeters(
        a.latitude,
        a.longitude,
        b.latitude,
        b.longitude,
      );

  CommercialProperty? get _center {
    final id = selectedId;
    if (id == null) return null;
    for (final property in _filtered) {
      if (property.id == id && _validPoint(property)) return property;
    }
    return null;
  }

  /// Radius limits the property LIST, not the background map inventory.
  /// Keeping other pins visible lets a user choose a different center.
  List<CommercialProperty> get _listed {
    final center = _center;
    if (center == null) return _filtered;
    final matches = _filtered
        .where(
          (candidate) =>
      candidate.id == center.id ||
          (_validPoint(candidate) &&
              (_metres(center, candidate) ?? double.infinity) <= radiusM),
    )
        .toList();
    if (sort == ExploreSort.imported) {
      matches.sort(
            (left, right) => (_metres(center, left) ?? double.infinity).compareTo(
          _metres(center, right) ?? double.infinity,
        ),
      );
    }
    return matches;
  }

  /// Other listings within [limitM] of [center] — the selection itself is
  /// never counted as its own neighbour, and records without usable
  /// coordinates are excluded rather than placed at a made-up distance.
  int _nearbyCount(CommercialProperty center, int limitM) => _filtered
      .where(
        (candidate) =>
    candidate.id != center.id &&
        _validPoint(candidate) &&
        (_metres(center, candidate) ?? double.infinity) <= limitM,
  )
      .length;

  Future<LocationAnalysis?> _readAnalysis(String propertyId) async {
    try {
      return await AppLocator.recommendations.analysis(propertyId);
    } on Object {
      return null; // Unavailable analysis must not break the map or listings.
    }
  }

  void _choose(CommercialProperty property, {bool scrollToMap = false}) {
    if (!_validPoint(property)) return;
    setState(() {
      if (selectedId != property.id) {
        _analysisFuture = _readAnalysis(property.id);
      }
      selectedId = property.id;
      visibleLimit = 24;
    });
    if (scrollToMap) {
      Future.delayed(const Duration(milliseconds: 40), () {
        if (mounted) scrollDomIntoView('swcx-map-section');
      });
    }
  }

  void _clearCenter() => setState(() {
    selectedId = null;
    _analysisFuture = null;
    showTransport = false;
    visibleLimit = 24;
  });

  void _changeFilter(PropertyFilter value) => setState(() {
    filter = value;
    visibleLimit = 24;
    // Never retain a selected property excluded by the new filters.
    if (_center == null) {
      selectedId = null;
      _analysisFuture = null;
      showTransport = false;
    }
  });

  void _reset() {
    _queryDebounce?.cancel();
    setState(() {
      filter = PropertyFilter.empty;
      sort = ExploreSort.imported;
      radiusM = 1000;
      selectedId = null;
      showTransport = false;
      _analysisFuture = null;
      visibleLimit = 24;
    });
    // The keyword lives in the shared EntrepreneurController, not this widget.
    // Clear it too so Clear filters really restores the complete catalogue.
    context.read(entrepreneurNotifierProvider.notifier).setQuery('');
  }

  void _queryChanged(String value) {
    _queryDebounce?.cancel();
    _queryDebounce = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      context.read(entrepreneurNotifierProvider.notifier).setQuery(value);
    });
  }

  /// Persists an authenticated save/unsave before changing UI state.
  /// The in-flight guard prevents double taps and concurrent requests for the
  /// same property. Visitors keep their existing session-only shortlist.
  Future<void> _toggleSaved(String id) async {
    if (_savingPropertyIds.contains(id)) return;
    final notifier = context.read(appNotifierProvider.notifier);
    if (!AppLocator.isSignedIn) {
      notifier.toggleSaved(id);
      if (_saveError != null && mounted) {
        setState(() => _saveError = null);
      }
      return;
    }

    final wasSaved = context.read(appNotifierProvider).saved.contains(id);
    setState(() {
      _savingPropertyIds.add(id);
      _saveError = null;
    });
    try {
      final failure = await AppLocator.persistToggleSaved(
        id,
        wantSaved: !wasSaved,
      );
      if (!mounted) return;
      if (failure != null) {
        setState(() {
          _saveError = 'Could not ${wasSaved ? 'remove' : 'save'} property '
              '$id. ${failure.message} Please retry.';
        });
        return;
      }
      // The request was accepted. Flip only this property once.
      notifier.toggleSaved(id);
    } catch (_) {
      // Avoid exposing raw server exceptions in the UI.
      if (mounted) {
        setState(() {
          _saveError = 'Could not update saved property $id. '
              'Please check your connection and retry.';
        });
      }
    } finally {
      _savingPropertyIds.remove(id);
      if (mounted) setState(() {});
    }
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
      title: 'Explore commercial properties',
      eyebrow: 'Property discovery',
      subtitle:
      'Search rental listings, view their locations, and examine the '
          'surrounding 500 m or 1 km catchment. Source coordinates may be approximate.',
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
          : div(classes: 'swcx-page', [
        _filterHeader(),
        _toolbar(),
        div(classes: 'swcx-layout', [
          div(classes: 'swcx-map-column', [_mapPanel()]),
          div(classes: 'swcx-list-column', [
            _listingPanel(saved, compared),
          ]),
        ]),
        if (_center != null) _insightsPanel(),
      ]),
    );
  }

  Component _filterHeader() => section(classes: 'swcx-filters', [
    div(classes: 'swcx-section-title', [
      div([
        span(classes: 'eyebrow', [Component.text('SEARCH & FILTER')]),
        h2([Component.text('Find the right commercial space')]),
      ]),
      p(classes: 'small', [
        Component.text(
          'Filters apply to the same records shown on the map and in the property list.',
        ),
      ]),
    ]),
    FilterPanel(
      filter: filter,
      source: _model.explore,
      results: _listed,
      query: _model.query,
      onQueryChanged: _queryChanged,
      onChanged: _changeFilter,
      onReset: _reset,
    ),
  ]);

  Component _toolbar() {
    final center = _center;
    return div(classes: 'swcx-toolbar', [
      div(classes: 'swcx-toolbar-copy', [
        strong([
          Component.text(
            center == null
                ? 'Select a property to inspect its surroundings'
                : 'Exploring ${center.title}',
          ),
        ]),
        span([
          Component.text(
            center == null
                ? '${_filtered.length} matching commercial property records'
                : '${_nearbyCount(center, 500)} other listings ≤500 m · '
                '${_nearbyCount(center, 1000)} other listings ≤1 km',
          ),
        ]),
      ]),
      div(classes: 'swcx-tools', [
        span(classes: 'swcx-tools-label', [Component.text('Radius')]),
        for (final metres in const [500, 1000])
          button(
            classes: radiusM == metres
                ? 'swcx-tool swcx-tool--active'
                : 'swcx-tool',
            attributes: {
              'type': 'button',
              'aria-pressed': radiusM == metres ? 'true' : 'false',
              'aria-label':
              'Select ${metres == 500 ? '500 metres' : '1 kilometre'} radius',
            },
            events: events(
              onClick: () => setState(() {
                radiusM = metres;
                visibleLimit = 24;
              }),
            ),
            [Component.text(metres == 500 ? '500 m' : '1 km')],
          ),
        button(
          classes: showTransport ? 'swcx-tool swcx-tool--active' : 'swcx-tool',
          attributes: {
            'type': 'button',
            'aria-pressed': showTransport ? 'true' : 'false',
            if (center == null) 'disabled': '',
            'title': center == null
                ? 'Select a property before loading nearby transport stops'
                : 'Show OpenStreetMap-recorded public transport stops',
          },
          events: events(
            onClick: () {
              if (_center != null) {
                setState(() => showTransport = !showTransport);
              }
            },
          ),
          [Icon('directions_bus', size: 'sm'), Component.text('Transport')],
        ),
        if (center != null)
          button(
            classes: 'swcx-tool',
            attributes: const {'type': 'button'},
            events: events(onClick: _clearCenter),
            [Component.text('Show all')],
          ),
      ]),
    ]);
  }

  Component _mapPanel() {
    final center = _center;
    // Map contains the full FILTERED property set. Radius membership controls
    // marker appearance and the list. The chosen center remains selectable.
    final json = jsonEncode({
      'selectedId': center?.id,
      'radiusM': radiusM,
      'showTransport': showTransport && center != null,
      'properties': [
        for (final p in _filtered)
          if (_validPoint(p))
            {
              'id': p.id,
              'title': p.title,
              'address': '${p.address}, ${p.city}',
              'lat': p.latitude,
              'lon': p.longitude,
              'rentRm': p.rentalRm,
              'nearby':
              center != null &&
                  (p.id == center.id ||
                      (_metres(center, p) ?? double.infinity) <= radiusM),
            },
      ],
    });
    return section(
      classes: 'swcx-map-panel',
      attributes: const {'id': 'swcx-map-section'},
      [
        div(classes: 'swcx-panel-head', [
          div([
            span(classes: 'eyebrow', [
              Component.text('INTERACTIVE PROPERTY MAP'),
            ]),
            h2([Component.text('Map & surroundings')]),
          ]),
          span(classes: 'swcx-map-counter', [
            Component.text('${_filtered.where(_validPoint).length} mapped'),
          ]),
        ]),
        div(
          classes: 'swcx-map-canvas',
          attributes: {
            'id': 'swcx-leaflet',
            'data-state': json,
            'role': 'region',
            'aria-label': 'Interactive commercial property map',
          },
          [],
        ),
        // JS only forwards the selected property ID. All data and state remain in Dart.
        button(
          classes: 'swcx-hidden-bridge',
          attributes: const {
            'id': 'swcx-selection-bridge',
            'type': 'button',
            'tabindex': '-1',
            'aria-hidden': 'true',
          },
          events: events(
            onClick: () {
              final id = selectedCombinedExplorePropertyId();
              if (id == null) return;
              for (final p in _filtered) {
                if (p.id == id) {
                  _choose(p);
                  return;
                }
              }
            },
          ),
          [],
        ),
        div(classes: 'swcx-map-foot', [
          div(classes: 'swcx-map-legend', [
            span([
              i(classes: 'swcx-dot swcx-dot--selected', []),
              Component.text('Selected'),
            ]),
            span([
              i(classes: 'swcx-dot swcx-dot--near', []),
              Component.text('Within radius'),
            ]),
            span([
              i(classes: 'swcx-dot swcx-dot--other', []),
              Component.text('Other listings'),
            ]),
            span([
              i(classes: 'swcx-dot swcx-dot--transport', []),
              Component.text('Transport'),
            ]),
          ]),
          p(classes: 'small', [
            Component.text(
              'Distances are straight-line estimates from catalogue coordinates, '
                  'not travel times. 500 m is included in the 1 km total.',
            ),
          ]),
        ]),
        div(classes: 'swcx-transport-block', [
          div(classes: 'swcx-transport-heading', [
            h3([Component.text('Nearby public transport')]),
            span([Component.text('OpenStreetMap · not real-time')]),
          ]),
          p(
            classes: 'swcx-transport-status',
            attributes: const {
              'id': 'swcx-transport-status',
              'aria-live': 'polite',
            },
            [
              Component.text(
                center == null
                    ? 'Select a property, then turn on Transport.'
                    : showTransport
                    ? 'Checking mapped stops near this property…'
                    : 'Turn on Transport to load available map records.',
              ),
            ],
          ),
          div(
            classes: 'swcx-transport-results',
            attributes: const {'id': 'swcx-transport-results'},
            [],
          ),
        ]),
      ],
    );
  }

  Component _listingPanel(Set<String> saved, Set<String> compared) {
    final results = _listed;
    return section(classes: 'swcx-list-panel', [
      div(classes: 'swcx-panel-head', [
        div([
          span(classes: 'eyebrow', [Component.text('COMMERCIAL PROPERTIES')]),
          h2([
            Component.text(
              _center == null
                  ? 'Property listings'
                  : 'Properties within ${radiusM == 500 ? '500 m' : '1 km'}',
            ),
          ]),
        ]),
        span(classes: 'swcx-map-counter', [
          Component.text('${results.length} listed'),
        ]),
      ]),
      if (_saveError != null)
        div(
          classes: 'swcx-save-error',
          attributes: const {'role': 'alert'},
          [
            p([Component.text(_saveError!)]),
            button(
              classes: 'swcx-save-error__dismiss',
              attributes: const {
                'type': 'button',
                'aria-label': 'Dismiss save error',
              },
              events: events(onClick: () => setState(() => _saveError = null)),
              [Component.text('Dismiss')],
            ),
          ],
        ),
      div(classes: 'swcx-list-sort', [
        span(classes: 'field__label', [Component.text('Sort by')]),
        select(
          attributes: const {'aria-label': 'Sort commercial properties'},
          events: events<List<String>>(
            onInput: (values) => setState(() {
              sort = values.isEmpty
                  ? ExploreSort.imported
                  : ExploreSort.values.byName(values.first);
              visibleLimit = 24;
            }),
          ),
          [
            for (final value in ExploreSort.values)
              option(
                value: value.name,
                attributes: {if (value == sort) 'selected': ''},
                [Component.text(_sortLabel(value))],
              ),
          ],
        ),
      ]),
      if (results.isEmpty)
        div(classes: 'swcx-list-empty', [
          Icon('search_off', size: 'lg'),
          h3([Component.text('No matching properties')]),
          p([Component.text('Try another radius or clear some filters.')]),
          ActionButton('Clear filters', onClick: _reset),
        ])
      else
        div(classes: 'swcx-list-scroll', [
          div(classes: 'pgrid swcx-property-grid', [
            for (final p in results.take(visibleLimit))
              PropertyCard(
                property: p,
                href:
                '/entrepreneur/property-detail?id=${Uri.encodeComponent(p.id)}',
                assessHref:
                '/entrepreneur/assessment?id=${Uri.encodeComponent(p.id)}',
                anchorId: 'swcx-property-${p.id}',
                selected: p.id == selectedId,
                saved: saved.contains(p.id),
                compared: compared.contains(p.id),
                saving: _savingPropertyIds.contains(p.id),
                onLocate: () => _choose(p, scrollToMap: true),
                onToggleSaved: () => _toggleSaved(p.id),
                onToggleCompared: () => context
                    .read(appNotifierProvider.notifier)
                    .toggleCompared(p.id),
              ),
          ]),
          if (results.length > visibleLimit)
            ActionButton(
              'Show more properties',
              onClick: () => setState(() {
                visibleLimit += 24;
              }),
            ),
        ]),
    ]);
  }

  Component _insightsPanel() {
    final center = _center;
    if (center == null) return const div([]);
    final nearby500 = _nearbyCount(center, 500);
    final nearby1km = _nearbyCount(center, 1000);
    return section(classes: 'swcx-insights', [
      div(classes: 'swcx-panel-head', [
        div([
          span(classes: 'eyebrow', [Component.text('PROPERTY CONTEXT')]),
          h2([Component.text('Selected property information')]),
        ]),
        ActionLink(
          'Assess this property',
          href: '/entrepreneur/assessment?id=${Uri.encodeComponent(center.id)}',
        ),
      ]),
      div(classes: 'swcx-insights-layout', [
        div(classes: 'swcx-selected-card', [
          h3([Component.text(center.title)]),
          p([
            Component.text(
              '${center.address}, ${center.city}, ${center.state}',
            ),
          ]),
          dl(classes: 'swcx-facts', [
            div([
              dt([Component.text('Monthly rent')]),
              dd([Component.text(center.rentalDisplay)]),
            ]),
            div([
              dt([Component.text('Floor area')]),
              dd([
                Component.text('${center.sizeSqft.toStringAsFixed(0)} sq ft'),
              ]),
            ]),
            div([
              dt([Component.text('Property type')]),
              dd([Component.text(center.propertyType)]),
            ]),
            div([
              dt([Component.text('Property ID')]),
              dd([Component.text(center.id)]),
            ]),
            div([
              dt([Component.text('Verification')]),
              dd([Component.text(center.verification.label)]),
            ]),
            div([
              dt([Component.text('Surrounding listings')]),
              dd([
                Component.text(
                  '$nearby500 within 500 m · '
                      '${nearby1km - nearby500} more in the 500 m–1 km ring',
                ),
              ]),
            ]),
          ]),
          ActionLink(
            'View full property details',
            href:
            '/entrepreneur/property-detail?id=${Uri.encodeComponent(center.id)}',
            variant: 'secondary',
          ),
        ]),
        div(classes: 'swcx-analysis-card', [
          h3([Component.text('Location intelligence')]),
          FutureBuilder<LocationAnalysis?>(
            future: _analysisFuture,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return p([Component.text('Loading location intelligence…')]);
              }
              final analysis = snap.data;
              if (analysis == null) {
                return p([
                  Component.text(
                    'No analysis is available for this listing. The map and nearby '
                        'property counts remain available.',
                  ),
                ]);
              }
              return div(classes: 'swcx-analysis-content', [
                p([Component.text('Verdict: ${analysis.verdict}')]),
                p([
                  Component.text(
                    'F&B competitor count (analysis source): '
                        '${analysis.competitorCount}',
                  ),
                ]),
                if (analysis.demandSummary.isNotEmpty)
                  p([Component.text(analysis.demandSummary)]),
                if (analysis.factors.isNotEmpty)
                  ul([
                    for (final factor in analysis.factors.take(5))
                      li([Component.text('${factor.name}: ${factor.rating}')]),
                  ]),
              ]);
            },
          ),
          p(classes: 'small', [
            Component.text(
              'Competition is a separate F&B dataset; the map radius above '
                  'counts commercial property listings only.',
            ),
          ]),
        ]),
      ]),
    ]);
  }

  static String _sortLabel(ExploreSort value) => switch (value) {
    ExploreSort.imported => 'Default / nearest when selected',
    ExploreSort.rentalLow => 'Rent: low to high',
    ExploreSort.rentalHigh => 'Rent: high to low',
    ExploreSort.areaLarge => 'Floor area: large first',
    ExploreSort.areaSmall => 'Floor area: small first',
  };
}

enum ExploreSort { imported, rentalLow, rentalHigh, areaLarge, areaSmall }

/// Applies [sort] to [input]. Dart's sort is not stable, so ties break on id —
/// the grid and the map read the same deterministic sequence.
List<CommercialProperty> sortForExplore(
    List<CommercialProperty> input,
    ExploreSort sort,
    ) {
  if (sort == ExploreSort.imported) return List.of(input);
  return [...input]..sort((left, right) {
    final score = switch (sort) {
      ExploreSort.imported => 0,
      ExploreSort.rentalLow => left.rentalRm.compareTo(right.rentalRm),
      ExploreSort.rentalHigh => right.rentalRm.compareTo(left.rentalRm),
      ExploreSort.areaLarge => right.sizeSqft.compareTo(left.sizeSqft),
      ExploreSort.areaSmall => left.sizeSqft.compareTo(right.sizeSqft),
    };
    return score == 0 ? left.id.compareTo(right.id) : score;
  });
}

class _Loading extends StatelessComponent {
  const _Loading();

  @override
  Component build(BuildContext context) => div(classes: 'loading', [
    span(classes: 'spinner', []),
    Component.text('Loading commercial properties…'),
  ]);
}
