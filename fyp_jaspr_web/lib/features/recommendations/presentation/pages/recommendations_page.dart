import 'dart:async';
import 'dart:convert';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';

import 'package:sitewise_jaspr_web/shared/presentation/components/ui.dart';
import 'package:sitewise_jaspr_web/core/di/app_locator.dart';
import 'package:sitewise_jaspr_web/features/authentication/data/auth_service.dart';
import 'package:sitewise_jaspr_web/features/recommendations/data/recommendation_filter_store.dart';
import 'package:sitewise_jaspr_web/shared/presentation/layouts/app_layout.dart';

/// Entrepreneur discovery — **Recommendations**.
///
/// This page replaced the separate Explore destination (`data/navigation.dart`;
/// `/entrepreneur/explore` redirects here in `app.dart`). Filter
/// selections automatically refresh ranked results. Text inputs are debounced,
/// and a first visit remains empty until a requirement is selected.
///
/// Everything the list shows comes from `POST /api/v1/recommendations/search`:
/// the server filters, orders and pages. This component never sorts, never
/// slices a local copy, and never loads the whole catalogue.
///
/// ```text
/// .rec2              two-column shell
///   .rec2__main      filters · result count · ranked cards · load more
///   .rec2__side      sticky intelligence panel for the selected listing
/// ```

@client
class RecommendationsPage extends StatefulComponent {
  const RecommendationsPage({super.key, this.initialPropertyId});

  /// Legacy `?id=<catalogue id>` deep link (the retired Explore page used it to
  /// open with a unit already selected). Honoured only if that property is part
  /// of the first result page, so a stale id never blanks the panel.
  final String? initialPropertyId;

  @override
  State<RecommendationsPage> createState() => _RecommendationsPageState();
}

class _RecommendationsPageState extends State<RecommendationsPage> {
  // Form edits are local until a brief debounce completes; then the
  // current criteria become the applied request. This avoids sending a search
  // for every character. The session state restores applied filters on return
  // from property details, and the server still owns ranking and pagination.
  /// The APPLIED criteria travel with every property-detail link so the
  /// comparison tab can show the filters that produced this result. Draft
  /// edits are never carried: they have not been searched yet.
  String get _filterQuery {
    final applied =
        context.read(entrepreneurNotifierProvider).recommendationRequest;
    return '&filters=${Uri.encodeQueryComponent(jsonEncode(applied.copyWith(clearNearby: true).toJson()))}';
  }
  String _state = '';
  String _city = '';
  String _propertyType = '';
  String _sizeKey = '';
  bool _moreOpen = false;

  /// Draft advanced selections keyed by the backend field. A key holds a
  /// `"min|max"` range, a value id, or an empty string for "Any".
  final Map<String, String> _advancedKeys = {};

  /// The selected monthly-rental interval, as `"min|max"`; empty means
  /// "Any monthly rental" (both request boundaries cleared). A saved range
  /// the backend does not generate is kept under the same key until changed,
  /// so a custom preference is never silently discarded.
  String _rentKey = '';
  String _targetMarket = '';
  String _query = '';

  // SiteWise web nearby location selector (map/address/coordinates).
  // Text fields are only staged until Apply is clicked. Search and facets
  // continue to be evaluated and paginated by the existing FastAPI endpoint.
  String _nearbyAddress = '';
  String _nearbyLatitudeText = '';
  String _nearbyLongitudeText = '';
  double? _nearbyLatitude;
  double? _nearbyLongitude;
  double _nearbyRadiusKm = 5;
  bool _nearbyGeocoding = false;
  String? _nearbyError;
  String? _nearbyNotice;
  bool _nearbyExpanded = false; // Default: compact location dropdown.

  /// Contextual choices for the DRAFT criteria. The applied choices remain in
  /// the session-scoped notifier state; the results list is never rebuilt
  /// from this payload.
  RecommendationFacets? _draftFacets;
  bool _facetLoading = false;
  String? _facetError;

  /// Draft facet requests are read-only and cheap relative to ranking, but a
  /// slower earlier response must never overwrite a newer selection.
  int _facetSeq = 0;
  Timer? _facetTimer;
  Timer? _autoSearchTimer;

  /// The active ordering. Held as the accepted server key, never a label, so a
  /// rename of the wording cannot silently change the request.
  String _sort = _sortBestMatch;

  static const _sortBestMatch = 'best_match';

  /// Used only when the facets call has not returned (or failed). The server
  /// sends the authoritative list with the facets; this keeps the control
  /// usable — and identical — before that arrives.
  static const _sortFallback = <String, String>{
    _sortBestMatch: 'Best requirement match',
    'rent_asc': 'Lowest monthly rent',
    'rent_desc': 'Highest monthly rent',
    'size_desc': 'Largest floor area',
    'size_asc': 'Smallest floor area',
    'pu_desc': 'Highest PU research index',
  };

  static const _targetMarketOptions = <String>[
    'Students',
    'Office Workers',
    'Residents',
    'General Public',
  ];

  /// Once a real search is applied, show its results until Clear is pressed.
  /// The shared notifier holds the applied request/results across navigation.
  bool _seeded = false;
  bool _hasSearched = false;

  static bool _hasSearchCriteria(RecommendationSearchRequest request) =>
      (request.businessType?.trim().isNotEmpty ?? false) ||
      (request.preferredState?.trim().isNotEmpty ?? false) ||
      (request.preferredArea?.trim().isNotEmpty ?? false) ||
      (request.city?.trim().isNotEmpty ?? false) ||
      (request.propertyType?.trim().isNotEmpty ?? false) ||
      (request.query?.trim().isNotEmpty ?? false) ||
      (request.floorLevel?.trim().isNotEmpty ?? false) ||
      (request.demandGenerator?.trim().isNotEmpty ?? false) ||
      request.minRentalRm != null ||
      request.maxRentalRm != null ||
      request.minSizeSqft != null ||
      request.maxSizeSqft != null ||
      request.transitMaxM != null ||
      request.nearbyParkingMin != null ||
      request.fnbCompetitionMax != null ||
      request.populationMin1000m != null ||
      request.populationMax1000m != null ||
      request.layoutPreferences.isNotEmpty ||
      request.locationLatitude != null;

  EntrepreneurNotifier get _notifier =>
      context.read(entrepreneurNotifierProvider.notifier);

  @override
  void initState() {
    super.initState();
    // Defer reads/writes until after the first widget build.
    Future.microtask(() {
      if (!mounted || _seeded) return;
      _seeded = true;
      final current = context.read(entrepreneurNotifierProvider);
      final applied = current.recommendationRequest;
      // Restore a previous *user-initiated* search, not a default browse.
      if (current.recommendationTotal != null && _hasSearchCriteria(applied)) {
        RecommendationFilterStore.write(applied);
        if (applied.managedOnly) {
          final restored = applied.copyWith(managedOnly: false);
          setState(() {
            _syncDraft(restored);
            _hasSearched = true;
          });
          _notifier.applyRecommendationRequest(restored);
        } else {
          setState(() {
            _syncDraft(applied);
            _hasSearched = true;
          });
        }
        // A bookmarked property can be reselected only from results that
        // were already obtained by a user-initiated search.
        final wanted = component.initialPropertyId;
        if (wanted != null &&
            wanted.isNotEmpty &&
            current.ranked.any((item) => item.property.id == wanted)) {
          _notifier.selectRanked(wanted);
        }
        _refreshFacets();
        return;
      }
      // Restore this signed-in user's last filters after a full browser reload.
      // The selected values are rehydrated BEFORE fetching the new results.
      final persisted = RecommendationFilterStore.read();
      if (persisted != null && _hasSearchCriteria(persisted)) {
        setState(() {
          _syncDraft(persisted);
          _hasSearched = true;
          _moreOpen = persisted.floorLevel != null ||
              persisted.transitMaxM != null ||
              persisted.nearbyParkingMin != null ||
              persisted.fnbCompetitionMax != null ||
              persisted.demandGenerator != null ||
              persisted.populationMin1000m != null ||
              persisted.populationMax1000m != null;
        });
        _notifier.applyRecommendationRequest(persisted);
        _refreshFacets();
        return;
      }
      // New visit: no property-search API call and no misleading saved
      // preference defaults. The initial Recommendations view is genuinely empty.
      setState(() {
        _syncDraft(const RecommendationSearchRequest());
        _hasSearched = false;
      });
      _notifier.clearRecommendationSearch();
      _refreshFacets(); // Facets populate filter choices, NOT result cards.
    });
  }

  @override
  void dispose() {
    _facetTimer?.cancel();
    _autoSearchTimer?.cancel();
    super.dispose();
  }

  /// A stable key for a pair of rental boundaries. The option list is
  /// regenerated as filters change, but the selected budget must stay visible
  /// and comparable by value, never by a label that may be reworded.
  static String _rangeKey(double? min, double? max) => (min == null && max == null)
      ? ''
      : '${min ?? ''}|${max ?? ''}';

  /// Draft rental boundaries, read back from the selected key. A saved range
  /// with one open side is legitimate; an inverted pair is normalised before
  /// it can ever reach FastAPI (which rejects it with 422).
  ({double? min, double? max}) get _rentBounds {
    final bounds = FacetRangeOption.boundsFromKey(_rentKey);
    final min = bounds.min;
    final max = bounds.max;
    if (min != null && max != null && min > max) {
      return (min: max, max: min);
    }
    return (min: min, max: max);
  }

  /// Draft <- applied. Called on mount and after any applied-state change
  /// that did not originate in the form (chip removal, reset).
  void _syncDraft(RecommendationSearchRequest request) {
    _state = request.preferredState ?? '';
    _city = request.city ?? '';
    _propertyType = request.propertyType ?? '';
    _sizeKey = _rangeKey(request.minSizeSqft, request.maxSizeSqft);
    _advancedKeys
      ..clear()
      ..['floor_level'] = request.floorLevel ?? ''
      ..['transit_walk_m'] = _rangeKey(null, request.transitMaxM)
      ..['nearby_parking_500m'] = _rangeKey(request.nearbyParkingMin, null)
      ..['fnb_competition_500m'] = _rangeKey(null, request.fnbCompetitionMax)
      ..['surrounding_population_1000m'] = _rangeKey(
        request.populationMin1000m,
        request.populationMax1000m,
      )
      ..['demand_generator'] = request.demandGenerator ?? '';
    final rentMin = request.minRentalRm;
    final rentMax = request.maxRentalRm;
    // Preserve a saved custom range by value. It stays selected until the
    // entrepreneur picks another interval or clears it, even when the backend
    // does not generate that exact interval for the current filters.
    _rentKey = rentMin == null && rentMax == null
        ? ''
        : _rangeKey(
            rentMin != null && rentMax != null && rentMin > rentMax
                ? rentMax
                : rentMin,
            rentMin != null && rentMax != null && rentMin > rentMax
                ? rentMin
                : rentMax,
          );
    _targetMarket = request.layoutPreferences.join(', ');
    _query = request.query ?? '';
    _nearbyLatitude = request.locationLatitude;
    _nearbyLongitude = request.locationLongitude;
    _nearbyRadiusKm = request.nearbyRadiusKm ?? 5;
    _nearbyLatitudeText = request.locationLatitude?.toStringAsFixed(6) ?? '';
    _nearbyLongitudeText = request.locationLongitude?.toStringAsFixed(6) ?? '';
    _sort = request.sort ?? _sortBestMatch;
  }

  /// Target market is the one requirement with no dedicated catalogue column,
  /// so it travels as the request's layout preferences — the same convention
  /// the preferences page uses. Commas separate several requirements.
  List<String> get _layoutPreferences => [
    for (final part in _targetMarket.split(','))
      if (part.trim().isNotEmpty) part.trim(),
  ];

  /// The request described by the form. Contextual facets and the
  /// automatically applied search use the same criteria.
  RecommendationSearchRequest get _draftRequest {
    final rent = _rentBounds;
    final size = FacetRangeOption.boundsFromKey(_sizeKey);
    final transit = FacetRangeOption.boundsFromKey(
      _advancedKeys['transit_walk_m'] ?? '',
    );
    final parking = FacetRangeOption.boundsFromKey(
      _advancedKeys['nearby_parking_500m'] ?? '',
    );
    final competition = FacetRangeOption.boundsFromKey(
      _advancedKeys['fnb_competition_500m'] ?? '',
    );
    final population = FacetRangeOption.boundsFromKey(
      _advancedKeys['surrounding_population_1000m'] ?? '',
    );
    final floor = _advancedKeys['floor_level'] ?? '';
    final demand = _advancedKeys['demand_generator'] ?? '';
    return RecommendationSearchRequest(
      preferredState: _state.isEmpty ? null : _state,
      city: _city.isEmpty ? null : _city,
      propertyType: _propertyType.isEmpty ? null : _propertyType,
      minRentalRm: rent.min,
      maxRentalRm: rent.max,
      minSizeSqft: size.min,
      maxSizeSqft: size.max,
      floorLevel: floor.isEmpty ? null : floor,
      transitMaxM: transit.max,
      nearbyParkingMin: parking.min,
      fnbCompetitionMax: competition.max,
      demandGenerator: demand.isEmpty ? null : demand,
      populationMin1000m: population.min,
      populationMax1000m: population.max,
      layoutPreferences: _layoutPreferences,
      query: _query.trim().isEmpty ? null : _query.trim(),
      locationLatitude: _nearbyLatitude,
      locationLongitude: _nearbyLongitude,
      nearbyRadiusKm: _nearbyLatitude == null ? null : _nearbyRadiusKm,
      sort: _sort,
      pageSize: 20,
    );
  }

  /// Apply a choice automatically, coalescing rapid changes into one
  /// request. The shared controller already ignores stale search responses.
  /// No search runs without any selected criterion, preserving the empty
  /// first-visit state instead of starting an unsolicited full browse.
  void _scheduleAutoSearch({
    Duration debounce = const Duration(milliseconds: 160),
  }) {
    _autoSearchTimer?.cancel();
    final request = _draftRequest;
    if (!_hasSearchCriteria(request)) {
      if (_hasSearched) {
        setState(() => _hasSearched = false);
        // Invalidate any in-flight result request before it can repaint the
        // empty selection after the last filter is cleared.
        _notifier.clearRecommendationSearch();
      }
      return;
    }
    _autoSearchTimer = Timer(debounce, () {
      if (!mounted) return;
      final next = _draftRequest;
      if (!_hasSearchCriteria(next)) return;
      final applied =
          context.read(entrepreneurNotifierProvider).recommendationRequest;
      // The active criteria are written synchronously by the controller, so
      // comparing request payloads prevents duplicate network calls.
      if (_hasSearched &&
          jsonEncode(next.toJson()) == jsonEncode(applied.toJson())) {
        return;
      }
      setState(() => _hasSearched = true);
      _notifier.applyRecommendationRequest(next);
    });
  }

  /// Dropdowns update quickly. Typing waits 450 ms after the last keystroke.
  /// Facets remain independent; failure to load dropdown options does not
  /// prevent the ranked results from updating.
  void _onDraftChange({
    Duration debounce = const Duration(milliseconds: 160),
  }) {
    RecommendationFilterStore.write(_draftRequest);
    _refreshFacets(debounce: debounce);
    _scheduleAutoSearch(debounce: debounce);
  }

  /// Reads contextual choices for the current draft. The previous choices
  /// stay visible while loading and after a failed request; only the response
  /// for the latest request is published.
  void _refreshFacets({Duration debounce = Duration.zero}) {
    _facetTimer?.cancel();
    // Invalidate a slower prior response immediately, before this timer runs.
    final seq = ++_facetSeq;
    _facetTimer = Timer(debounce, () async {
      if (!mounted || seq != _facetSeq) return;
      final request = _draftRequest;
      setState(() {
        _facetLoading = true;
        _facetError = null;
      });
      try {
        final facets = await _notifier.fetchRecommendationFacets(request);
        if (!mounted || seq != _facetSeq) return;
        setState(() {
          _draftFacets = facets;
          _facetLoading = false;
        });
      } on Object {
        if (!mounted || seq != _facetSeq) return;
        setState(() {
          _facetLoading = false;
          _facetError = 'Filter choices could not be updated.';
        });
      }
    });
  }

  /// The applied facets until a draft refresh completes, so a failed or slow
  /// contextual read never blanks the controls.
  RecommendationFacets? _facetsFor(EntrepreneurState state) =>
      _draftFacets ?? state.recommendationFacets;

  /// Sorting changes the same live criteria as every other control.
  /// If a text input is waiting for its debounce, the sort change applies
  /// both changes together instead of accidentally dropping the typed filter.
  void _applySort(String value) {
    RecommendationFilterStore.write(_draftRequest);
    _scheduleAutoSearch(debounce: Duration.zero);
  }

  /// Commits a new APPLIED request originating outside the form (chip
  /// removal) and mirrors it into the draft so the form cannot disagree.
  void _applyRequest(RecommendationSearchRequest request) {
    RecommendationFilterStore.write(request);
    _autoSearchTimer?.cancel();
    // Removing the last active constraint returns to the initial empty state.
    if (!_hasSearchCriteria(request)) {
      _reset();
      return;
    }
    setState(() {
      _syncDraft(request);
      _hasSearched = true;
    });
    _notifier.applyRecommendationRequest(request);
    _refreshFacets();
  }

  void _reset() {
    RecommendationFilterStore.clear();
    _autoSearchTimer?.cancel();
    const defaults = RecommendationSearchRequest();
    setState(() {
      _syncDraft(defaults);
      _hasSearched = false;
    });
    // Clear the session's results and invalidate in-flight searches.
    _notifier.clearRecommendationSearch();
    _refreshFacets();
  }

  /// Saves/removes a property. A signed-in account persists server-side first
  /// and the shortlist only moves once the server accepted the change.
  String? _saveError;

  Future<void> _toggleSaved(String id) async {
    final notifier = context.read(appNotifierProvider.notifier);
    if (!AppLocator.isSignedIn) {
      notifier.toggleSaved(id);
      return;
    }
    final savedNow = context.read(appNotifierProvider).saved.contains(id);
    final failure = await notifier.persistSaved(
      id,
      wantSaved: !savedNow,
    );
    if (mounted) setState(() => _saveError = failure);
  }

  @override
  Component build(BuildContext context) {
    final state = context.watch(entrepreneurNotifierProvider);
    final saved = context.watch(appNotifierProvider.select((app) => app.saved));
    final compared = context.watch(
      appNotifierProvider.select((app) => app.compared),
    );
    final available = _notifier.hasRecommendationSearch;

    if (!available && state.ranked.isEmpty) {
      return AppLayout(
        role: AppRole.entrepreneur,
        currentRoute: '/entrepreneur/recommendations',
        title: 'Recommendations',
        eyebrow: 'Find a space that fits your vision',
        subtitle: 'Ranked commercial properties for your business.',
        child: const EmptyState(
          title: 'Recommendation search is unavailable',
          body:
              'This build has no recommendation backend configured, so no '
              'ranking can be produced. Property details, saved properties and '
              'assessments are unaffected.',
        ),
      );
    }

    final selected = _hasSearched ? _selected(state) : null;

    return AppLayout(
      role: AppRole.entrepreneur,
      currentRoute: '/entrepreneur/recommendations',
      title: 'Recommendations',
      eyebrow: 'Find a space that fits your vision',
      subtitle: _hasSearched
          ? _subtitle(state)
          : 'Choose your preferences to find a suitable commercial property.',
      child: div(classes: _hasSearched ? 'rec2' : 'rec2 rec2--presearch', [
        div(classes: 'rec2__main', [
          if (_saveError case final error?)
            div(attributes: {'role': 'alert'}, [_errorBanner(error)]),
          _filters(state),
          if (_hasSearched)
            _appliedFilters(state.recommendationRequest),
          if (_hasSearched && state.recommendationError != null)
            _errorBanner(state.recommendationError!),
          if (_hasSearched)
            _resultHead(state),
          if (!_hasSearched)
            const EmptyState(
              title: 'Choose your property filters',
              body: 'Select a location, rental range or other preference '
                  'above. Matching properties appear automatically.', 
            )
          else if (state.recommendationLoading)
            const _Loading()
          else if (state.ranked.isEmpty)
            _empty(state)
          else ...[
            div(classes: 'rec2__list', [
              for (final item in state.ranked)
                _card(item, saved, compared, item.id == state.selectedRankedId),
            ]),
            if (state.recommendationHasMore)
              div(classes: 'rec2__more', [
                ActionButton(
                  state.recommendationRefreshing ? 'Loading…' : 'Load more',
                  variant: 'secondary',
                  icon: 'expand_more',
                  onClick: state.recommendationRefreshing
                      ? null
                      : () => _notifier.loadMoreRecommendations(),
                ),
              ]),
          ],
          if (_hasSearched && state.recommendationModel != null)
            p(classes: 'rec2__provenance', [
              Component.text(_provenance(state)),
            ]),
        ]),
        if (_hasSearched)
          div(classes: 'rec2__side', [
            if (selected == null)
              const _PanelPlaceholder()
            else
              _insightPanel(selected, saved, compared),
          ]),
      ]),
    );
  }

  RankedProperty? _selected(EntrepreneurState state) {
    final id = state.selectedRankedId;
    if (id == null) return null;
    for (final item in state.ranked) {
      if (item.id == id) return item;
    }
    return null;
  }

  String _subtitle(EntrepreneurState state) {
    final total = state.recommendationTotal;
    final parts = <String>[
      if (total != null) '$total properties match your requirements',
      _orderingSummary(state),
    ];
    return parts.join(' · ');
  }

  /// What the list is currently ordered by. The header must agree with the
  /// list: quoting "requirement-fit ordering" while the list is sorted by rent
  /// would be a false statement about the data.
  String _orderingSummary(EntrepreneurState state) {
    final sort = state.recommendationRequest.sort;
    if (sort == null || sort == _sortBestMatch) {
      return 'Based on the needs you selected';
    }
    return 'Ordered by ${_sortLabel(state, sort).toLowerCase()}';
  }

  /// Label for an ordering key, preferring the server's own vocabulary.
  String _sortLabel(EntrepreneurState state, String key) {
    final fromServer = state.recommendationFacets?.sortOptions;
    if (fromServer != null && fromServer.containsKey(key)) {
      return fromServer[key]!;
    }
    return _sortFallback[key] ?? key;
  }

  Map<String, String> _sortOptions(EntrepreneurState state) {
    final fromServer = state.recommendationFacets?.sortOptions;
    return fromServer == null || fromServer.isEmpty
        ? _sortFallback
        : fromServer;
  }

  // SITEWISE_SIMPLE_RECOMMENDATIONS_COPY_V1: explain ordering in plain language.
  String _provenance(EntrepreneurState state) {
    final sort = state.recommendationRequest.sort;
    if (sort != null && sort != _sortBestMatch) {
      return 'Showing properties by ${_sortLabel(state, sort).toLowerCase()}. '
          'Your selected filters decide which properties appear.';
    }
    return 'Properties are shown using your choices and the available listing '
        'details. Location scores describe an area, but cannot '
        'predict sales or business success.';
  }

  // -- filters ---------------------------------------------------------------

  /// The APPLIED criteria as readable, individually removable chips.
  ///
  /// Built from `state.recommendationRequest` — the same request the server
  /// ranked — so the summary can never disagree with the results. Removing a
  /// chip commits a new applied request immediately (it is not a draft edit).
  Component _appliedFilters(RecommendationSearchRequest request) {
    final chips = <({String label, RecommendationSearchRequest next})>[
      if (request.locationLatitude != null && request.locationLongitude != null)
        (
          label: 'Within ${(request.nearbyRadiusKm ?? 5).toStringAsFixed(0)} km of selected point',
          next: request.copyWith(clearNearby: true, clearCursor: true),
        ),
      if (request.preferredState != null)
        (
          label: request.preferredState!,
          next: request.copyWith(clearState: true),
        ),
      if (request.city != null)
        (
          label: request.city!,
          next: request.copyWith(clearCity: true),
        ),
      if (request.propertyType != null)
        (
          label: request.propertyType!,
          next: request.copyWith(clearPropertyType: true),
        ),
      if (request.minRentalRm != null || request.maxRentalRm != null)
        (
          label: _rentChipLabel(request),
          next: request.copyWith(clearRentRange: true),
        ),
      if (request.minSizeSqft != null || request.maxSizeSqft != null)
        (
          label: _sizeChipLabel(request),
          next: request.copyWith(clearSizeRange: true),
        ),
      if (request.floorLevel != null)
        (
          label: request.floorLevel!,
          next: request.copyWith(clearFloorLevel: true),
        ),
      if (request.transitMaxM != null)
        (
          label: 'Transit within ${request.transitMaxM!.round()} m',
          next: request.copyWith(clearTransit: true),
        ),
      if (request.nearbyParkingMin != null)
        (
          label: 'Parking from ${request.nearbyParkingMin!.round()}',
          next: request.copyWith(clearParking: true),
        ),
      if (request.fnbCompetitionMax != null)
        (
          label: 'F&B outlets up to ${request.fnbCompetitionMax!.round()}',
          next: request.copyWith(clearCompetition: true),
        ),
      if (request.demandGenerator != null)
        (
          label: _demandLabel(request.demandGenerator!),
          next: request.copyWith(clearDemand: true),
        ),
      if (request.populationMin1000m != null ||
          request.populationMax1000m != null)
        (
          label: 'Population ${request.populationMin1000m?.round() ?? '0'}–'
              '${request.populationMax1000m?.round() ?? 'any'}',
          next: request.copyWith(clearPopulation: true),
        ),
      if (request.query != null)
        (
          label: '“${request.query}”',
          next: request.copyWith(clearQuery: true),
        ),
      if (request.layoutPreferences.isNotEmpty)
        (
          label: request.layoutPreferences.length == 1
              ? 'Target market: ${request.layoutPreferences.first}'
              : '${request.layoutPreferences.length} target markets',
          next: request.copyWith(layoutPreferences: const []),
        ),
    ];
    if (chips.isEmpty) return Component.fragment([]);
    return div(classes: 'rec2__applied', [
      span(classes: 'rec2__applied-label', [
        Component.text('Applied filters:'),
      ]),
      for (final chip in chips)
        span(classes: 'chip rec2__chip', [
          Component.text(chip.label),
          button(
            classes: 'rec2__chip-remove',
            attributes: {
              'type': 'button',
              'aria-label': 'Remove filter ${chip.label}',
            },
            events: events(onClick: () => _applyRequest(chip.next)),
            [Component.text('×')],
          ),
        ]),
      AppLink(
        to: '#rec2-filters',
        classes: 'rec2__edit-filters',
        children: [Component.text('Edit filters')],
      ),
    ]);
  }

  static String _sizeChipLabel(RecommendationSearchRequest request) {
    final min = request.minSizeSqft;
    final max = request.maxSizeSqft;
    String n(double value) => value.toStringAsFixed(0);
    if (min != null && max != null) return '${n(min)}–${n(max)} sq ft';
    if (min != null) return '${n(min)}+ sq ft';
    return 'Up to ${n(max!)} sq ft';
  }

  static String _demandLabel(String value) => switch (value) {
    'malls_1000m' => 'Malls within 1 km',
    'offices_500m' => 'Offices within 500 m',
    'universities_500m' => 'Universities within 500 m',
    _ => value,
  };

  static String _rentChipLabel(RecommendationSearchRequest request) =>
      _rentText(request.minRentalRm, request.maxRentalRm);

  Component _filters(EntrepreneurState state) {
    final facets = _facetsFor(state);
    final compareCount = context.read(appNotifierProvider).compared.length;
    final states = _optionPairs(facets?.states ?? const <FacetOption>[]);
    final cities = _optionPairs(facets?.cities ?? const <FacetOption>[]);
    final types = _optionPairs(facets?.propertyTypes ?? const <FacetOption>[]);
    final sizes = _rangePairs(facets?.sizeRanges ?? const <FacetRangeOption>[]);
    final count = _hasSearched
        ? (_draftFacets?.matchingTotal ?? state.recommendationTotal)
        : null;

    return div(
      classes: 'rec2__filters',
      attributes: const {'id': 'rec2-filters'},
      [
        div(classes: 'rec2__filter-intro', [
          div(classes: 'rec2__filter-intro-copy', [
            span(classes: 'rec2__eyebrow', [
              Icon('tune', size: 'sm'),
              Component.text('PROPERTY SEARCH'),
            ]),
            h2(classes: 'rec2__filter-title', [
              Component.text('Find the right space'),
            ]),
            p(classes: 'rec2__filter-description', [
              Component.text(
                'Choose a location, budget and size. You can also explore nearby parking, transport and food outlets.',
              ),
            ]),
          ]),
        ]),
        _nearbyPicker(),
        // Row 1 — location and property class. Every option comes from the
        // catalogue; each dropdown is contextual to the other selections.
        div(classes: 'rec2__filters-grid', [
          _dropdownField(
            caption: 'State',
            fieldId: 'rec2-state',
            value: _state,
            emptyLabel: 'Any state',
            options: states,
            onChanged: (v) {
              // Never reset another selection: an incompatible combination
              // stays visible and the backend reports zero matches.
              setState(() => _state = v);
              _onDraftChange();
            },
          ),
          _dropdownField(
            caption: 'City / District',
            fieldId: 'rec2-city',
            value: _city,
            emptyLabel: 'Any city / district',
            options: cities,
            onChanged: (v) {
              setState(() => _city = v);
              _onDraftChange();
            },
          ),
          _dropdownField(
            caption: 'Property type',
            fieldId: 'rec2-property-type',
            value: _propertyType,
            emptyLabel: 'Any property type',
            options: types,
            onChanged: (v) {
              setState(() => _propertyType = v);
              _onDraftChange();
            },
          ),
          // Row 2 — budget, size and stated preference.
          _rentalField(facets),
          _dropdownField(
            caption: 'Floor space (sq ft)',
            fieldId: 'rec2-size',
            value: _sizeKey,
            emptyLabel: 'Any size',
            options: sizes,
            includeSelected: _sizeKey.isNotEmpty &&
                !sizes.any((pair) => pair.$1 == _sizeKey),
            onChanged: (v) {
              setState(() => _sizeKey = v);
              _onDraftChange();
            },
          ),
          _dropdownField(
            caption: 'Target customers (optional)',
            fieldId: 'rec2-target-market',
            value: _targetMarket,
            emptyLabel: 'Any target market',
            options: [for (final value in _targetMarketOptions) (value, value)],
            onChanged: (v) {
              setState(() => _targetMarket = v);
              _onDraftChange();
            },
          ),
          // Row 3 — ordering and text search.
          _sortField(_sortOptions(state)),
          div(classes: 'field rec2__field--wide rec2__field--search', [
            span(classes: 'field__label', [Component.text('Search')]),
            input(
              attributes: {
                'type': 'text',
                'value': _query,
                'placeholder': 'Search area, title or property ID',
                'aria-label': 'Search area, title or property ID',
                'id': 'rec2-search',
              },
              events: events<String>(onInput: (value) {
                setState(() => _query = value);
                _onDraftChange(debounce: const Duration(milliseconds: 450));
              }),
            ),
          ]),
        ]),
        button(
          classes: 'rec2__more-toggle',
          attributes: {
            'type': 'button',
            'aria-expanded': '$_moreOpen',
          },
          events: events(onClick: () => setState(() => _moreOpen = !_moreOpen)),
          [
            Icon('tune', size: 'sm'),
            span([Component.text('More location options')]),
            Icon(_moreOpen ? 'expand_less' : 'expand_more', size: 'sm'),
          ],
        ),
        if (_moreOpen)
          div(classes: 'rec2__more', [
            _advancedGroup(
              'About the space',
              const ['floor_level'],
              facets,
            ),
            _advancedGroup(
              'Getting around and nearby places',
              const [
                'transit_walk_m',
                'nearby_parking_500m',
                'fnb_competition_500m',
                'demand_generator',
                'surrounding_population_1000m',
              ],
              facets,
            ),
          ]),
        _facetStatus(state),
        div(classes: 'rec2__filters-actions', [
          span(classes: 'rec2__match-count', [
            Icon('autorenew', size: 'sm'),
            Component.text('Results update automatically'),
          ]),
          if (count != null)
            span(classes: 'rec2__match-count', [
              Component.text(
                '$count ${count == 1 ? 'matching property' : 'matching properties'}',
              ),
            ]),
          ActionButton('Clear all', variant: 'secondary', onClick: _reset),
          span(classes: 'rec2__compare-bar', [
            Component.text(
              compareCount >= AppState.maxCompare
                  ? '$compareCount of ${AppState.maxCompare} in comparison — remove one to add another'
                  : '$compareCount of ${AppState.maxCompare} in comparison',
            ),
            if (compareCount >= 2)
              const ActionLink(
                'View comparison',
                href: '/entrepreneur/compare',
                variant: 'secondary',
              ),
          ]),
        ]),
      ],
    );
  }

  /// One group of the expanded "More filters" panel. A field the backend did
  /// not report is omitted entirely — no dummy or disabled placeholder.
  // Map, address, or numeric coordinate entry all resolve to the same
  // optional search center. Nothing is sent until Apply location is selected.
  Component _nearbyPicker() => div(
    classes: 'rec2-location',
    attributes: const {'id': 'rec2-nearby-picker'},
    [
      // SITEWISE_LOCATION_DROPDOWN_V1: compact by default; the location filter
      // remains applied even while the advanced entry fields are hidden.
      button(
        classes: 'rec2-location__toggle',
        attributes: {
          'type': 'button',
          'aria-expanded': _nearbyExpanded ? 'true' : 'false',
          'aria-controls': 'rec2-location-controls',
          'aria-label': _nearbyExpanded
              ? 'Collapse search around a point'
              : 'Expand search around a point',
        },
        events: events(onClick: () => setState(() => _nearbyExpanded = !_nearbyExpanded)),
        [
          span(classes: 'rec2-location__toggle-left', [
            Icon('place', size: 'sm'),
            span(classes: 'rec2-location__toggle-label', [
              Component.text('Search around a point'),
            ]),
          ]),
          span(classes: 'rec2-location__toggle-right', [
            span(classes: 'rec2-location__toggle-status', [
              Component.text(_nearbyLatitude == null
                  ? 'Optional location filter'
                  : 'Within ${_nearbyRadiusKm.toStringAsFixed(0)} km'),
            ]),
            span(classes: 'rec2-location__toggle-icon', [
              Icon(_nearbyExpanded ? 'expand_less' : 'expand_more', size: 'sm'),
            ]),
          ]),
        ],
      ),
      if (_nearbyLatitude != null && !_nearbyExpanded)
        p(classes: 'rec2-location__active', [
          Component.text('Selected center: '
              '${_nearbyLatitude!.toStringAsFixed(6)}, '
              '${_nearbyLongitude!.toStringAsFixed(6)} '
              '· ${_nearbyRadiusKm.toStringAsFixed(0)} km radius'),
        ]),
      if (_nearbyExpanded)
        div(
          classes: 'rec2-location__panel',
          attributes: const {'id': 'rec2-location-controls'},
          [
      p(classes: 'rec2-location__intro', [
        Component.text('Use your current location or search for an address. '
            'Drag the map to place the pin at the correct location, then apply '
            'your search radius.'),
      ]),
      div(classes: 'rec2-location__methods', [
        div(classes: 'rec2-location__field rec2-location__field--full', [
          // SITEWISE_INLINE_LOCATION_V3: Leaflet owns the empty map host.
          div(classes: 'rec2-location__map-toolbar', [
            span(classes: 'rec2-location__label', [
              Component.text('Set the location on map'),
            ]),
            button(
              classes: 'rec2-location__btn rec2-location__gps',
              attributes: const {
                'type': 'button',
                'data-sitewise-current-location': 'true',
                'aria-label': 'Use current location',
              },
              [Icon('my_location', size: 'sm'), Component.text(' Use current location')],
            ),
          ]),
          div(
            classes: 'rec2-location__map-host',
            attributes: {
              'data-sitewise-inline-location': 'true',
              'data-lat': _nearbyLatitudeText,
              'data-lon': _nearbyLongitudeText,
            },
            [],
          ),
          input(
            attributes: const {'id': 'rec2-location-pick-value', 'type': 'hidden'},
            events: events<String>(onInput: (value) {
              final parts = value.split(',');
              if (parts.length != 2) return;
              setState(() {
                _nearbyLatitudeText = parts.first.trim();
                _nearbyLongitudeText = parts.last.trim();
                _nearbyError = null;
                _nearbyNotice = 'Point selected. Press Apply location to search.';
              });
            }),
          ),
        ]),
        div(classes: 'rec2-location__field rec2-location__field--full', [
          span(classes: 'rec2-location__label', [Component.text('Find by address')]),
          div(classes: 'rec2-location__address', [
            input(
              attributes: {
                'id': 'rec2-nearby-address',
                'type': 'text',
                'value': _nearbyAddress,
                'placeholder': 'e.g. Taman Equine, Seri Kembangan, Selangor',
                'aria-label': 'Search address in Malaysia',
                'autocomplete': 'off',
                'maxlength': '200',
              },
              events: events<String>(onInput: (value) => setState(() {
                _nearbyAddress = value;
                _nearbyError = null;
              })),
            ),
            button(
              classes: 'rec2-location__btn',
              attributes: {'type': 'button', 'aria-label': 'Look up address'},
              events: events(onClick: _nearbyGeocoding ? null : _lookupNearbyAddress),
              [Component.text(_nearbyGeocoding ? 'Finding…' : 'Find address')],
            ),
          ]),
        ]),
        div(classes: 'rec2-location__field', [
          span(classes: 'rec2-location__label', [Component.text('Latitude')]),
          input(
            attributes: {
              'type': 'text',
              'inputmode': 'decimal',
              'id': 'rec2-nearby-latitude',
              'value': _nearbyLatitudeText,
              'placeholder': '3.139000',
              'aria-label': 'Latitude, decimal degrees',
            },
            events: events<String>(onInput: (value) => setState(() {
              _nearbyLatitudeText = value;
              _nearbyError = null;
            })),
          ),
        ]),
        div(classes: 'rec2-location__field', [
          span(classes: 'rec2-location__label', [Component.text('Longitude')]),
          input(
            attributes: {
              'type': 'text',
              'inputmode': 'decimal',
              'id': 'rec2-nearby-longitude',
              'value': _nearbyLongitudeText,
              'placeholder': '101.686900',
              'aria-label': 'Longitude, decimal degrees',
            },
            events: events<String>(onInput: (value) => setState(() {
              _nearbyLongitudeText = value;
              _nearbyError = null;
            })),
          ),
        ]),
        label(classes: 'rec2-location__field', [
          span(classes: 'rec2-location__label', [Component.text('Search radius')]),
          select(
            attributes: const {'aria-label': 'Radius around selected point'},
            events: events<List<String>>(onInput: (values) {
              final n = double.tryParse(values.isEmpty ? '' : values.first);
              if (n == null) return;
              setState(() => _nearbyRadiusKm = n);
              if (_nearbyLatitude != null) _onDraftChange();
            }),
            [
              for (final radius in const [2, 5, 10, 20])
                option(
                  value: '$radius',
                  attributes: _nearbyRadiusKm == radius
                      ? {'selected': ''} : null,
                  [Component.text('$radius km')],
                ),
            ],
          ),
        ]),
      ]),
      div(classes: 'rec2-location__actions', [
        button(
          classes: 'rec2-location__btn rec2-location__btn--primary',
          attributes: const {'type': 'button'},
          events: events(onClick: _applyNearbyLocation),
          [Component.text('Apply location')],
        ),
        if (_nearbyLatitude != null)
          button(
            classes: 'rec2-location__btn',
            attributes: const {'type': 'button'},
            events: events(onClick: _clearNearbyLocation),
            [Component.text('Search all areas')],
          ),
      ]),
      if (_nearbyError != null)
        p(classes: 'rec2-location__status rec2-location__status--error',
          [Component.text(_nearbyError!)]),
      if (_nearbyNotice != null)
        p(classes: 'rec2-location__status', [Component.text(_nearbyNotice!)]),
      if (_nearbyLatitude != null)
        p(classes: 'rec2-location__status', [
          Component.text('Active search center: '
              '${_nearbyLatitude!.toStringAsFixed(6)}, '
              '${_nearbyLongitude!.toStringAsFixed(6)} '
              '· ${_nearbyRadiusKm.toStringAsFixed(0)} km radius'),
        ]),
      p(classes: 'rec2-location__hint', [
        Component.text('Only the chosen point is sent with the search. '
            'The 2–20 km circle is straight-line distance, not travel time. '
            'Address lookup sends your typed text to OpenStreetMap; '
            'confirm the approximate position. © OpenStreetMap contributors.'),
      ]),
          ],
        ),
    ],
  );

  void _applyNearbyLocation() {
    final lat = double.tryParse(_nearbyLatitudeText.trim());
    final lon = double.tryParse(_nearbyLongitudeText.trim());
    if (lat == null || lon == null || !lat.isFinite || !lon.isFinite ||
        lat.abs() > 90 || lon.abs() > 180 || (lat == 0 && lon == 0)) {
      setState(() => _nearbyError =
          'Enter valid latitude (-90 to 90) and longitude (-180 to 180).');
      return;
    }
    setState(() {
      _nearbyLatitude = lat;
      _nearbyLongitude = lon;
      _nearbyError = null;
      _nearbyNotice = 'Location applied. Results use the selected radius.';
      _nearbyExpanded = false;
    });
    _onDraftChange(debounce: Duration.zero);
  }

  void _clearNearbyLocation() {
    setState(() {
      _nearbyLatitude = null;
      _nearbyLongitude = null;
      _nearbyLatitudeText = '';
      _nearbyLongitudeText = '';
      _nearbyAddress = '';
      _nearbyError = null;
      _nearbyNotice = null;
    });
    _onDraftChange(debounce: Duration.zero);
  }

  Future<void> _lookupNearbyAddress() async {
    if (_nearbyGeocoding) return;
    final address = _nearbyAddress.trim();
    if (address.length < 5 || address.length > 200) {
      setState(() => _nearbyError = 'Enter an address between 5 and 200 characters.');
      return;
    }
    setState(() {
      _nearbyGeocoding = true;
      _nearbyError = null;
      _nearbyNotice = null;
    });
    try {
      final result = await WebAuth.request(
        '/api/v1/recommendations/geocode',
        method: 'POST',
        body: {'address': address},
      );
      if (!mounted) return;
      final lat = (result['latitude'] as num?)?.toDouble();
      final lon = (result['longitude'] as num?)?.toDouble();
      if (lat == null || lon == null || !lat.isFinite || !lon.isFinite) {
        throw StateError('The address did not return usable coordinates.');
      }
      setState(() {
        _nearbyLatitudeText = lat.toStringAsFixed(6);
        _nearbyLongitudeText = lon.toStringAsFixed(6);
        _nearbyNotice = 'Approximate match: ${result['display_name'] ?? address}. '
            'Confirm the point on the map if necessary, then press Apply location.';
      });
    } on Object {
      if (!mounted) return;
      setState(() => _nearbyError =
          'Address could not be resolved. Try a fuller Malaysian address, '
          'use the map, or enter coordinates.');
    } finally {
      if (mounted) setState(() => _nearbyGeocoding = false);
    }
  }

  Component _advancedGroup(
    String title,
    List<String> keys,
    RecommendationFacets? facets,
  ) {
    final fields = [
      for (final key in keys)
        if (facets?.advanced[key] != null) _advancedControl(key, facets!.advanced[key]!),
    ];
    if (fields.isEmpty) return Component.fragment([]);
    return div(classes: 'rec2__group', [
      span(classes: 'rec2__group-title', [Component.text(title)]),
      for (final field in fields) field,
    ]);
  }

  // SITEWISE_MOBILE_ALIGNED_ADVANCED_PRESETS_V1
  // The same descriptive options used by entrepreneur mobile Preferences.
  // Keys are still numeric bounds, so FastAPI ranking and filtering stay intact.
  List<(String, String)>? _mobileAdvancedPresets(String key) => switch (key) {
    'transit_walk_m' => [
        (_rangeKey(null, 500.0), 'Easy — within 500 m walk'),
        (_rangeKey(null, 1000.0), 'Nearby — within 1 km walk'),
      ],
    'nearby_parking_500m' => [
        (_rangeKey(1.0, null), 'Preferred — 1+ nearby facility'),
        (_rangeKey(3.0, null), 'More options — 3+ nearby facilities'),
        (_rangeKey(5.0, null), 'Plenty — 5+ nearby facilities'),
      ],
    'fnb_competition_500m' => [
        (_rangeKey(null, 5.0), 'Low — up to 5 F&B outlets'),
        (_rangeKey(null, 10.0), 'Moderate — up to 10 F&B outlets'),
        (_rangeKey(null, 20.0), 'Higher — up to 20 F&B outlets'),
      ],
    _ => null,
  };

  // SITEWISE_RELATIVE_POPULATION_LABELS_V1
  // Labels describe relative resident counts in the current facet, not fixed
  // population thresholds. Preserve each backend range key unchanged.
  List<(String, String)> _friendlyPopulationRanges(
    List<FacetRangeOption> ranges,
  ) {
    if (ranges.isEmpty) return [];
    final ordered = [...ranges]
      ..sort((left, right) => left.min.compareTo(right.min));
    final levels = switch (ordered.length) {
      1 => const ['Only available range'],
      2 => const ['Low', 'High'],
      3 => const ['Low', 'Moderate', 'High'],
      4 => const ['Low', 'Moderate', 'High', 'Very high'],
      5 => const ['Very low', 'Low', 'Moderate', 'High', 'Very high'],
      _ => List<String>.generate(
        ordered.length,
        (i) => 'Population level ${i + 1} of ${ordered.length}',
      ),
    };
    return [
      for (var i = 0; i < ordered.length; i++)
        (ordered[i].key, levels[i]),
    ];
  }

  // Previously saved custom numeric limits must not disappear from the form.
  // Keep their original values instead of silently rounding to a preset.
  String _advancedSavedLabel(String key, String selected) {
    final bounds = FacetRangeOption.boundsFromKey(selected);
    String amount(double value) => value == value.roundToDouble()
        ? value.toStringAsFixed(0)
        : value.toString();
    if (key == 'transit_walk_m' && bounds.max != null) {
      return 'Saved choice — within ${amount(bounds.max!)} m walk';
    }
    if (key == 'nearby_parking_500m' && bounds.min != null) {
      return 'Saved choice — ${amount(bounds.min!)}+ parking facilities';
    }
    if (key == 'fnb_competition_500m' && bounds.max != null) {
      return 'Saved choice — up to ${amount(bounds.max!)} F&B outlets';
    }
    if (key == 'surrounding_population_1000m') {
      if (bounds.min != null && bounds.max != null) {
        return 'Saved choice — ${amount(bounds.min!)}–${amount(bounds.max!)} residents';
      }
      if (bounds.min != null) {
        return 'Saved choice — at least ${amount(bounds.min!)} residents';
      }
    }
    return 'Saved choice — $selected';
  }

  Component _advancedControl(String key, RecommendationAdvancedFacet facet) {
    final selected = _advancedKeys[key] ?? '';
    final presets = _mobileAdvancedPresets(key);
    final options = <(String, String)>[
      if (presets != null)
        ...presets
      else if (key == 'surrounding_population_1000m' && facet.isRange)
        ..._friendlyPopulationRanges(facet.rangeOptions)
      else if (facet.isRange)
        ..._rangePairs(facet.rangeOptions)
      else
        for (final option in facet.valueOptions)
          (option.value, _facetOptionLabel(option)),
    ];

    // A stored preference may use a custom numeric bound not in the mobile
    // preset choices. Render it with its real meaning and preserve its value.
    if (selected.isNotEmpty && !options.any((item) => item.$1 == selected)) {
      options.insert(0, (selected, _advancedSavedLabel(key, selected)));
    }

    final caption = switch (key) {
      'nearby_parking_500m' => 'Nearby public parking (500 m)',
      'fnb_competition_500m' => 'Competition tolerance (500 m)',
      'demand_generator' => 'Nearby places that attract visitors',
      'surrounding_population_1000m' => 'Residents nearby (1 km)',
      _ => facet.label,
    };
    return _dropdownField(
      caption: caption,
      fieldId: 'rec2-adv-$key',
      value: selected,
      emptyLabel: 'No preference',
      options: options,
      includeSelected: false,
      onChanged: (value) {
        setState(() => _advancedKeys[key] = value);
        _onDraftChange();
      },
    );
  }

  /// The human-readable option name from the facet, never its count.
  ///
  /// `value` is a separate concern: it is what the select submits and what
  /// the backend uses to filter. States, cities and property types carry no
  /// separate label from the API, so their value is already the display name.
  static String _facetOptionLabel(FacetOption option) =>
      option.label.isEmpty ? option.value : option.label;

  List<(String, String)> _optionPairs(List<FacetOption> options) => [
    for (final option in options) (option.value, _facetOptionLabel(option)),
  ];

  List<(String, String)> _rangePairs(List<FacetRangeOption> options) => [
    for (final option in options) (option.key, option.label),
  ];

  /// Accessible dropdown whose options come from the backend facets. A saved
  /// selection that is no longer generated stays visible until changed.
  Component _dropdownField({
    required String caption,
    required String fieldId,
    required String value,
    required String emptyLabel,
    required List<(String, String)> options,
    required void Function(String) onChanged,
    bool includeSelected = false,
  }) =>
      label(classes: 'field', [
        span(classes: 'field__label', [Component.text(caption)]),
        select(
          id: fieldId,
          attributes: {'aria-label': caption, 'name': fieldId},
          events: events<List<String>>(
            onInput: (values) => onChanged(values.isEmpty ? '' : values.first),
          ),
          [
            option(
              key: ValueKey('$fieldId-any'),
              value: '',
              selected: value.isEmpty,
              [Component.text(emptyLabel)],
            ),
            if (includeSelected)
              option(
                key: ValueKey('$fieldId-selected'),
                value: value,
                selected: true,
                [Component.text(value)],
              ),
            for (final pair in options)
              option(
                key: ValueKey('$fieldId-${pair.$1}'),
                value: pair.$1,
                selected: pair.$1 == value,
                [Component.text(pair.$2)],
              ),
          ],
        ),
      ]);

  /// One dropdown built from `rental_ranges.options`, never from a hand typed
  /// list. The label is the full interval; the matching count stays in the
  /// facet summary. The value is the exact pair of boundaries sent to FastAPI.
  Component _rentalField(RecommendationFacets? facets) {
    final options = facets?.rentalRanges ?? const <FacetRangeOption>[];
    final hasSelection = _rentKey.isNotEmpty;
    final generated = hasSelection
        ? options.where((item) => item.key == _rentKey).toList()
        : const <FacetRangeOption>[];
    final custom = hasSelection && generated.isEmpty;
    final bounds = _rentBounds;
    final selectedLabel = facets?.selectedRental?.label ??
        (custom ? _rentText(bounds.min, bounds.max) : '');

    return div(classes: 'field rec2__field--wide', [
      label(classes: 'field__label', [
        Component.text('Monthly rental (RM)'),
      ]),
      select(
        id: 'rec2-monthly-rental',
        attributes: const {
          'aria-label': 'Monthly rental (RM)',
          'name': 'rec2-monthly-rental',
        },
        events: events<List<String>>(
          onInput: (values) {
            final value = values.isEmpty ? '' : values.first;
            if (value == _rentKey) return;
            setState(() => _rentKey = value);
            _onDraftChange();
          },
        ),
        [
          option(
            key: const ValueKey('rent-any'),
            value: '',
            selected: !hasSelection,
            [Component.text('Any monthly rental')],
          ),
          // A saved range (or a range that has just become unavailable) stays
          // visible and selected until it is changed or explicitly cleared.
          if (custom)
            option(
              key: ValueKey('rent-custom-$_rentKey'),
              value: _rentKey,
              selected: true,
              [Component.text(selectedLabel)],
            ),
          for (final item in options)
            option(
              key: ValueKey('rent-${item.key}'),
              value: item.key,
              selected: item.key == _rentKey,
              [Component.text(item.label)],
            ),
        ],
      ),
      if (custom && _rentKey.isNotEmpty)
        div(classes: 'rec2__rent-note', [
          Component.text(
            _unavailableRent(facets)
                ? 'This rental range currently matches no eligible properties.'
                : 'Your saved rental range is not one of the current intervals. '
                    'It stays applied until you choose another.',
          ),
          if (_unavailableRent(facets))
            button(
              classes: 'rec2__link-button',
              attributes: const {
                'type': 'button',
                'aria-label': 'Clear rental filter',
              },
              events: events(onClick: _rentChangedToAny),
              [Component.text('Clear rental filter')],
            ),
        ]),
    ]);
  }

  bool _unavailableRent(RecommendationFacets? facets) =>
      _rentKey.isNotEmpty &&
      facets != null &&
      facets.rentalRanges.isNotEmpty &&
      !facets.rentalRanges.any((item) => item.key == _rentKey) &&
      facets.matchingTotal == 0;

  void _rentChangedToAny() {
    setState(() => _rentKey = '');
    _onDraftChange();
  }

  /// Small status line above the filter chips: loading, failure with retry,
  /// a real contextual count, or the empty state with recovery actions.
  Component _facetStatus(EntrepreneurState state) {
    if (_facetError != null) {
      return div(classes: 'rec2__facet-status is-error', attributes: const {
        'role': 'status',
      }, [
        Component.text('$_facetError Previous choices are still shown.'),
        button(
          classes: 'rec2__link-button',
          attributes: const {'type': 'button'},
          events: events(onClick: () => _refreshFacets()),
          [Component.text('Retry')],
        ),
      ]);
    }
    if (_facetLoading) {
      return div(classes: 'rec2__facet-status', attributes: const {
        'role': 'status',
      }, [Component.text('Updating filter choices…')]);
    }
    final facets = _draftFacets;
    if (facets == null) return Component.fragment([]);
    if (!_hasSearched && !_hasSearchCriteria(_draftRequest)) {
      return Component.fragment([]);
    }
    final total = facets.matchingTotal;
    if (total == 0) {
      final applied = _draftRequest;
      return div(classes: 'rec2__facet-status is-empty', [
        strong([Component.text('No properties match all your current filters.')]),
        if (_rentKey.isNotEmpty)
          button(
            classes: 'rec2__link-button',
            attributes: const {'type': 'button'},
            events: events(onClick: _rentChangedToAny),
            [Component.text('Clear rental filter')],
          ),
        for (final relaxation in facets.relaxations.take(3))
          button(
            classes: 'rec2__link-button',
            attributes: {'type': 'button'},
            events: events(
              onClick: () => _applyRequest(
                _clearFacetField(applied, relaxation.field),
              ),
            ),
            [Component.text('Remove ${relaxation.label}')],
          ),
        button(
          classes: 'rec2__link-button',
          attributes: const {'type': 'button'},
          events: events(onClick: _reset),
          [Component.text('Clear all filters')],
        ),
      ]);
    }
    return div(classes: 'rec2__facet-status is-count', attributes: const {
      'role': 'status',
    }, [
      Component.text(
        '$total ${total == 1 ? 'property matches' : 'properties match'} '
        'all your current filters.',
      ),
    ]);
  }

  /// Maps a backend relaxation key to the matching request clear flag. Only
  /// hard filters appear in `relaxations`; ranking-only inputs never do.
  RecommendationSearchRequest _clearFacetField(
    RecommendationSearchRequest request,
    String field,
  ) => switch (field) {
    'preferred_state' => request.copyWith(clearState: true),
    'city' => request.copyWith(clearCity: true),
    'floor_level' => request.copyWith(clearFloorLevel: true),
    'transit_walk_m' => request.copyWith(clearTransit: true),
    'nearby_parking_500m' => request.copyWith(clearParking: true),
    'fnb_competition_500m' => request.copyWith(clearCompetition: true),
    'demand_generator' => request.copyWith(clearDemand: true),
    'surrounding_population_1000m' => request.copyWith(clearPopulation: true),
    'property_type' => request.copyWith(clearPropertyType: true),
    'rental_budget' => request.copyWith(clearRentRange: true),
    'property_size' => request.copyWith(clearSizeRange: true),
    'preferred_area' => request.copyWith(clearArea: true),
    'query' => request.copyWith(clearQuery: true),
    _ => request,
  };

  /// Ringgit grouping for chip and custom-range labels.
  static String _money(double value) {
    final digits = value.toStringAsFixed(0);
    final grouped = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) grouped.write(',');
      grouped.write(digits[i]);
    }
    return 'RM $grouped';
  }

  static String _rentText(double? min, double? max) {
    if (min != null && max != null) {
      return min == max ? _money(min) : '${_money(min)} – ${_money(max)}';
    }
    if (min != null) return 'From ${_money(min)}';
    if (max != null) return 'Up to ${_money(max)}';
    return 'Any monthly rental';
  }

  /// Ordering control. Applied on change rather than on "Find properties":
  /// re-sequencing the same eligible set is not a filter change, and a sort
  /// that appears to do nothing until another button is pressed reads as
  /// broken.
  ///
  /// The labels are sentences ("Best requirement match"), so the control is
  /// given two grid tracks — one 160px track truncates every option.
  Component _sortField(Map<String, String> options) =>
      label(classes: 'field rec2__field--wide', [
        span(classes: 'field__label', [Component.text('Sort by')]),
        select(
          attributes: {'aria-label': 'Sort by', 'id': 'rec2-sort'},
          events: events<List<String>>(
            onInput: (values) {
              final value = values.isEmpty ? '' : values.first;
              if (value.isEmpty || value == _sort) return;
              setState(() => _sort = value);
              _applySort(value);
            },
          ),
          [
            for (final entry in options.entries)
              option(
                value: entry.key,
                attributes: _sort == entry.key ? {'selected': ''} : null,
                [Component.text(entry.value)],
              ),
          ],
        ),
      ]);

  /// Editable combobox: a text input backed by a `<datalist>` of suggestions.
  ///
  /// A strict `<select>` cannot express a value outside its option list, but
  /// both of these fields legitimately can: target market is a comma-separated
  /// list of requirements, and older saved searches may hold custom business
  /// types. Choosing a suggestion or typing a custom value both fire `input`,
  /// so one handler covers both paths.
  // -- results ---------------------------------------------------------------

  Component _resultHead(EntrepreneurState state) {
    final total = state.recommendationTotal;
    final refreshing = state.recommendationRefreshing;
    return div(classes: 'stack', [
      div(classes: 'rec2__head', [
        h2(classes: 'rec2__count', [
          Component.text(
            total == null
                ? 'Ranked properties'
                : '$total ${total == 1 ? 'property' : 'properties'}',
          ),
        ]),
        if (refreshing)
          span(classes: 'rec2__refreshing', [Component.text('Updating…')]),
      ]),
    ]);
  }

  Component _errorBanner(String message) => div(classes: 'rec2__error', [
    Icon('error_outline', size: 'sm'),
    div(classes: 'rec2__error-body', [
      strong([Component.text('Could not load recommendations')]),
      span([Component.text(message)]),
    ]),
    ActionButton(
      'Retry',
      variant: 'secondary',
      onClick: () => _notifier.searchRecommendations(),
    ),
  ]);

  Component _empty(EntrepreneurState state) {
    final request = state.recommendationRequest;
    final browseOnly = request.isBrowseOnly;
    final facets = _facetsFor(state);
    final hasRent = request.minRentalRm != null || request.maxRentalRm != null;
    return EmptyState(
      title: browseOnly
          ? 'No scored properties available'
          : 'No properties match all your current filters.',
      body: browseOnly
          ? 'No catalogue property currently has a usable location score. '
                'That is a data condition, not a filter problem.'
          : 'Nothing in the catalogue satisfies every constraint. Remove a '
                'restrictive filter or clear them all and search again.',
      action: div(classes: 'rec2__empty-actions', [
        if (hasRent)
          ActionButton(
            'Clear rental filter',
            variant: 'secondary',
            onClick: () =>
                _applyRequest(request.copyWith(clearRentRange: true)),
          ),
        // The backend suggests only hard filters whose removal actually
        // recovers rows; ranking-only inputs are never offered here.
        for (final relaxation in (facets?.relaxations ?? const []).take(3))
          if (relaxation.field != 'rental_budget' || !hasRent)
            ActionButton(
              'Remove ${relaxation.label}',
              variant: 'secondary',
              onClick: () =>
                  _applyRequest(_clearFacetField(request, relaxation.field)),
            ),
        ActionButton(
          'Clear all filters',
          variant: 'primary',
          onClick: _reset,
        ),
      ]),
    );
  }

  Component _card(
    RankedProperty item,
    Set<String> saved,
    Set<String> compared,
    bool selected,
  ) {
    final prop = item.property;
    final match = item.match;
    final isSaved = saved.contains(prop.id);
    final isCompared = compared.contains(prop.id);
    return article(classes: selected ? 'rec2-card is-selected' : 'rec2-card', [
      div(classes: 'rec2-card__media', [
        if ((prop.imageUrl ?? '').isNotEmpty)
          img(src: prop.imageUrl ?? '', alt: 'Photograph of ${prop.title}')
        else
          div(classes: 'rec2-card__media-empty', [
            Icon('image_not_supported', size: 'sm'),
            span([Component.text('No photo')]),
          ]),
        span(classes: 'rec2-card__rank', [Component.text('#${match.rank}')]),
      ]),
      div(classes: 'rec2-card__body', [
        h3(classes: 'rec2-card__title', [
          AppLink(
            to: '/entrepreneur/property-detail?id=${Uri.encodeComponent(prop.id)}$_filterQuery',
            children: [Component.text(prop.title)],
          ),
        ]),
        p(classes: 'rec2-card__meta', [
          Component.text(
            [
              if (prop.city.isNotEmpty) prop.city,
              if (prop.state.isNotEmpty) prop.state,
              if (prop.propertyType.isNotEmpty) prop.propertyType,
            ].join(' · '),
          ),
        ]),
        p(classes: 'rec2-card__meta', [
          Component.text('Management: ${item.management.display}'),
        ]),
        div(classes: 'rec2-card__facts', [
          _fact('Rent', 'RM ${prop.rentalRm.toStringAsFixed(0)}/mo'),
          _fact('Floor area', '${prop.sizeSqft.toStringAsFixed(0)} sq ft'),
          if (item.puAvailable == true && item.puScore != null)
            _fact('Location score', item.puScore!.toStringAsFixed(0))
          else if (item.suitabilityAvailable)
            _fact(
              'Location score',
              item.catalogSuitabilityScore!.toStringAsFixed(0),
            ),
        ]),
        if (match.matched.isNotEmpty || match.unmatched.isNotEmpty)
          div(classes: 'rec2-card__reasons', [
            for (final reason in match.matched.take(3))
              span(classes: 'rec2-chip is-met', [
                Icon('check', size: 'sm'),
                Component.text(reason.label),
              ]),
            for (final reason in match.unmatched.take(2))
              span(classes: 'rec2-chip is-unmet', [
                Icon('close', size: 'sm'),
                Component.text(reason.label),
              ]),
          ]),
        div(classes: 'rec2-card__actions', [
          ActionButton(
            'View insight',
            variant: selected ? 'primary' : 'secondary',
            icon: 'insights',
            onClick: () => _notifier.selectRanked(prop.id),
          ),
          ActionLink(
            'Details',
            href: '/entrepreneur/property-detail?id=${Uri.encodeComponent(prop.id)}$_filterQuery',
            variant: 'secondary',
          ),
          ActionLink(
            'Assess',
            href: '/entrepreneur/assessment?id=${Uri.encodeComponent(prop.id)}',
            variant: 'secondary',
          ),
          ActionButton(
            isSaved ? 'Saved' : 'Save',
            variant: 'secondary',
            icon: isSaved ? 'bookmark' : 'bookmark_border',
            onClick: () => _toggleSaved(prop.id),
          ),
          ActionButton(
            isCompared
                ? 'In compare ✓'
                : (compared.length >= AppState.maxCompare
                    ? 'Compare full'
                    : 'Compare'),
            variant: 'secondary',
            icon: 'compare_arrows',
            // Selected → tap removes THIS property only (the compare bar's
            // 'View comparison' link opens Compare). Full and not selected →
            // disabled; the compare bar explains the limit.
            onClick: isCompared
                ? () => context
                    .read(appNotifierProvider.notifier)
                    .toggleCompared(prop.id)
                : (compared.length < AppState.maxCompare
                    ? () => context
                        .read(appNotifierProvider.notifier)
                        .addCompared(prop.id)
                    : null),
          ),
        ]),
      ]),
      _requirementStatus(match),
    ]);
  }

  /// Compact requirement status for the right-hand column of a ranked card.
  ///
  /// Every count comes from the backend match payload. This component only
  /// formats it — it never recomputes the match or influences ranking.
  Component _requirementStatus(RecommendationMatch match) {
    final total = match.verifiableCount;
    final matched = match.matchedCount;
    final hasCriteria = total > 0;
    final fullyMatched = hasCriteria && matched >= total;
    final remaining = hasCriteria ? total - matched : 0;

    final value = hasCriteria ? '$matched/$total matched' : '—';
    final support = !hasCriteria
        ? 'No criteria selected'
        : fullyMatched
            ? 'Fully matches your selected criteria'
            : match.unverified.isNotEmpty && match.unmatched.isEmpty
                ? '$remaining not verified yet'
                : '$remaining of $total not met';
    final chipLabel = !hasCriteria
        ? 'Not set'
        : fullyMatched
            ? 'Match'
            : matched == 0
                ? 'No match'
                : 'Partial';
    final chipState = !hasCriteria
        ? 'is-neutral'
        : fullyMatched
            ? 'is-match'
            : matched == 0
                ? 'is-none'
                : 'is-partial';

    return div(classes: 'rec2-card__score', [
      span(classes: 'req-card__title', [Component.text('Requirements')]),
      strong(classes: 'req-card__value', [Component.text(value)]),
      span(classes: 'req-card__support', [Component.text(support)]),
      span(classes: 'req-card__chip $chipState', [
        if (fullyMatched) Icon('check', size: 'sm'),
        Component.text(chipLabel),
      ]),
      if (total > 1 && match.matched.isNotEmpty)
        div(classes: 'req-card__mini-list', [
          for (final requirement in match.matched.take(2))
            span(classes: 'req-card__mini', [
              Component.text(requirement.label),
            ]),
        ]),
    ]);
  }

  Component _fact(String label, String value) => div(classes: 'rec2-fact', [
    span(classes: 'rec2-fact__label', [Component.text(label)]),
    strong([Component.text(value)]),
  ]);

  // -- intelligence panel ----------------------------------------------------

  Component _insightPanel(
    RankedProperty item,
    Set<String> saved,
    Set<String> compared,
  ) {
    final prop = item.property;
    final match = item.match;
    return div(classes: 'rec2-panel', [
      span(classes: 'overline', [Component.text('Selected property')]),
      h2(classes: 'rec2-panel__title', [Component.text(prop.title)]),
      p(classes: 'rec2-panel__meta', [
        Component.text(
          [prop.address, prop.city, prop.state]
              .where((v) => v.isNotEmpty)
              .join(', '),
        ),
      ]),
      if ((prop.imageUrl ?? '').isNotEmpty)
        div(classes: 'rec2-panel__media', [
          img(src: prop.imageUrl ?? '', alt: 'Photograph of ${prop.title}'),
        ]),

      // Recommendation verdict — requirement-level, because there is no model
      // score to quote in this build.
      div(classes: 'rec2-panel__block', [
        span(classes: 'rec2-panel__label', [
          Component.text(
            match.available ? 'Recommendation match' : 'Requirement fit',
          ),
        ]),
        if (match.fitSummary != null)
          p(classes: 'rec2-panel__fit', [Component.text(match.fitSummary!)]),
        if (match.matched.isNotEmpty)
          _requirementList('Met', match.matched, 'is-met'),
        if (match.unmatched.isNotEmpty)
          _requirementList('Not met', match.unmatched, 'is-unmet'),
        if (match.unverified.isNotEmpty)
          _requirementList(
            'Not enough information yet',
            match.unverified,
            'is-unverified',
          ),
        if (match.matched.isEmpty &&
            match.unmatched.isEmpty &&
            match.unverified.isEmpty)
          p(classes: 'small', [
            Component.text(
              'Choose a location, budget or floor space above to find properties that suit your needs.',
            ),
          ]),
      ]),

      div(classes: 'rec2-panel__block', [
        span(classes: 'rec2-panel__label', [Component.text('Listing facts')]),
        _panelRow('Management', item.management.display),
        _panelRow('Monthly rental', 'RM ${prop.rentalRm.toStringAsFixed(0)}'),
        _panelRow('Floor area', '${prop.sizeSqft.toStringAsFixed(0)} sq ft'),
        _panelRow('Property type', prop.propertyType),
        _panelRow('City / District', item.district.isEmpty ? 'Not recorded' : item.district),
        if (item.characteristics['floor_level'] != null)
          _panelRow('Floor level', '${item.characteristics['floor_level']}'),
        if (item.characteristics['transit_walk_m'] != null)
          _panelRow(
            'Nearest public transport',
            '${(item.characteristics['transit_walk_m'] as num).round()} m',
          ),
        if (item.characteristics['nearby_parking_500m'] != null)
          _panelRow(
            'Public parking within 500 m',
            '${item.characteristics['nearby_parking_500m']}',
          ),
        if (item.characteristics['fnb_competition_500m'] != null)
          _panelRow(
            'F&B outlets within 500 m',
            '${item.characteristics['fnb_competition_500m']}',
          ),
        if (item.characteristics['population_1000m'] != null)
          _panelRow(
            'Population within 1 km',
            '${(item.characteristics['population_1000m'] as num).round()}',
          ),
        _panelRow(
          'Location score',
          item.suitabilityAvailable
              ? '${item.catalogSuitabilityScore!.toStringAsFixed(1)} / 100'
              : 'Not available',
        ),
      ]),

      div(classes: 'rec2-panel__block', [
        span(classes: 'rec2-panel__label', [
          Component.text('About the location score'),
        ]),
        p(classes: 'small', [
          Component.text(
            item.puAvailable == true
                ? 'This property has a location score of '
                      '${item.puScore?.toStringAsFixed(1) ?? '—'} out of 100. '
                      'It describes recorded area characteristics, not the '
                      'number of customers or sales the business will get.'
                : 'A location score is not available for this property.',
          ),
        ]),
        ActionLink(
          'See how this score was calculated',
          href:
              '/entrepreneur/explanation?property=${Uri.encodeComponent(prop.id)}',
          variant: 'secondary',
        ),
      ]),

      div(classes: 'rec2-panel__actions', [
        ActionLink(
          'View details',
          href: '/entrepreneur/property-detail?id=${Uri.encodeComponent(prop.id)}$_filterQuery',
          variant: 'primary',
        ),
        ActionLink(
          'Assess this property',
          href: '/entrepreneur/assessment?id=${Uri.encodeComponent(prop.id)}',
          variant: 'secondary',
        ),
        ActionLink(
          'Map & nearby',
          href: '/entrepreneur/map?id=${Uri.encodeComponent(prop.id)}',
          variant: 'secondary',
        ),
        ActionButton(
          saved.contains(prop.id) ? 'Saved' : 'Save',
          variant: 'secondary',
          icon: saved.contains(prop.id) ? 'bookmark' : 'bookmark_border',
          onClick: () => _toggleSaved(prop.id),
        ),
        ActionButton(
          compared.contains(prop.id)
              ? 'In compare ✓'
              : (compared.length >= AppState.maxCompare
                  ? 'Compare full'
                  : 'Compare'),
          variant: 'secondary',
          icon: 'compare_arrows',
          onClick: compared.contains(prop.id)
              ? () => context
                  .read(appNotifierProvider.notifier)
                  .toggleCompared(prop.id)
              : (compared.length < AppState.maxCompare
                  ? () => context
                      .read(appNotifierProvider.notifier)
                      .addCompared(prop.id)
                  : null),
        ),
      ]),
    ]);
  }

  Component _requirementList(
    String title,
    List<RequirementMatch> items,
    String toneClass,
  ) => div(classes: 'rec2-reqs', [
    span(classes: 'rec2-reqs__title', [Component.text(title)]),
    for (final item in items)
      div(classes: 'rec2-reqs__item $toneClass', [
        Icon(
          item.isMet
              ? 'check'
              : item.isUnmet
              ? 'close'
              : 'help',
          size: 'sm',
        ),
        span([Component.text(item.label)]),
      ]),
  ]);

  Component _panelRow(String label, String value) =>
      div(classes: 'rec2-panel__row', [
        span([Component.text(label)]),
        strong([Component.text(value.isEmpty ? 'Not recorded' : value)]),
      ]);
}

class _PanelPlaceholder extends StatelessComponent {
  const _PanelPlaceholder();

  @override
  Component build(BuildContext context) => div(classes: 'rec2-panel', [
    span(classes: 'overline', [Component.text('Location intelligence')]),
    p(classes: 'small', [
      Component.text(
        'Select a property to see its requirement matches, listing facts and '
        'research evidence.',
      ),
    ]),
  ]);
}

class _Loading extends StatelessComponent {
  const _Loading();

  @override
  Component build(BuildContext context) => div(classes: 'loading', [
    span(classes: 'spinner', []),
    Component.text('Ranking properties…'),
  ]);
}
