import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../../../application/services/service_locator.dart';
import '../../../../core/config/mobile_config.dart';
import '../../../../core/theme/sitewise_m3.dart';
import '../../../../core/theme/sitewise_theme.dart';
import '../../../shared/widgets/sitewise_bottom_sheet.dart';
import '../../../shared/widgets/sitewise_button.dart';
import '../../../shared/widgets/sitewise_empty_state.dart';
import '../../../shared/widgets/sitewise_error_state.dart';
import '../../../shared/widgets/sitewise_map_panel.dart';
import '../../shell/mobile_app_shell.dart';
import '../../widgets/m3_kit.dart';
import '../../widgets/mobile_filter_sheet.dart';
import '../../widgets/mobile_filter_tile.dart';
import '../../widgets/mobile_property_card.dart';
import '../../widgets/mobile_search_field.dart';
import '../../widgets/mobile_skeleton.dart';

/// Mobile Listing / Explore — "Listing discovery".
///
/// Layout follows the supplied reference: brand header, page heading, a
/// search field with a map toggle, a 2×2 grid of meaningful filter tiles, three
/// secondary criteria chips, then the matching-listings section and the cards.
///
/// Data flow is unchanged from the rest of the app:
/// `PostgreSQL → FastAPI /api/v1/explore → shared_logic repository →
/// EntrepreneurNotifier (Riverpod) → this page`.
///
/// Two data paths, one screen:
///
///  * **Live** ([MobileConfig.usesLiveApi]) — every structured criterion, the
///    search term and the sort travel to `GET /api/v1/explore/properties` as
///    [ExploreQuery] criteria, so the count describes the whole published
///    dataset rather than the loaded page. Filter facets come from
///    `GET /explore/options`. The one exception is the 360° tour criterion,
///    which the endpoint does not accept: it narrows the loaded rows and the
///    header says so instead of quoting the server total.
///  * **Demo** — the bundled fixture, narrowed locally by the same
///    [PropertyFilter] rules the web tree uses.
///
/// Honesty rules enforced here:
///  * A criterion the current dataset cannot satisfy is rendered as
///    unavailable with a stated reason instead of a toggle that silently does
///    nothing.
///  * A failed request never becomes an empty result, and never becomes fake
///    properties.
///  * The filters are never cleared by a network failure.
class EntrepreneurExploreMobilePage extends ConsumerStatefulWidget {
  /// Open directly in map mode (Home → "Explore on map").
  final bool startInMap;

  const EntrepreneurExploreMobilePage({super.key, this.startInMap = false});

  @override
  ConsumerState<EntrepreneurExploreMobilePage> createState() =>
      _EntrepreneurExploreMobilePageState();
}

class _EntrepreneurExploreMobilePageState
    extends ConsumerState<EntrepreneurExploreMobilePage> {
  late bool showMap = widget.startInMap;

  /// The single source of truth for structured criteria. Shared with the web
  /// tree, so mobile and web cannot drift on what "RM 3k–8k" means.
  PropertyFilter filter = PropertyFilter.empty;

  /// Default-on 500 m cluster rule (live mode only): keep listings with at
  /// least 3 *other* approved, published commercial properties within 500 m.
  ///
  /// The bundled demo fixture is deliberately sparse (~7 properties across
  /// KL/Johor/Penang), so no listing there has 3 neighbours and the default is
  /// OFF in demo; otherwise Explore would always open on an empty list. The
  /// rule stays reachable from the advanced sheet in both modes and the empty
  /// state still offers the "Show all properties" escape hatch.
  bool nearbyOnly = MobileConfig.usesLiveApi;

  ExploreSortOption _sort = ExploreSortOption.newest;

  /// Held here (not in the notifier) so the query survives every rebuild, the
  /// map/list switch, and ordinary navigation within the tab.
  final TextEditingController _search = TextEditingController();

  /// Debounce: one request per settled term, not one per keystroke. The
  /// controller's sequence numbers already prevent a slow earlier response
  /// from overwriting a newer one; the timer only avoids spending requests.
  Timer? _searchDebounce;

  /// Unfiltered demo listings, used only to derive tile options when no server
  /// facets exist.
  List<CommercialProperty> _all = const [];

  bool get _live => MobileConfig.usesLiveApi;

  @override
  void initState() {
    super.initState();
    // The load publishes synchronously; a kick from initState would modify the
    // provider while the widget tree is building.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_live) {
        // The default nearby filter must ride the first request, so the
        // initial load goes through the criteria path.
        _applyServerState();
      } else {
        ref.read(entrepreneurNotifierProvider.notifier).loadExplore();
      }
    });
    if (!_live) _loadDemoOptions();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _loadDemoOptions() async {
    try {
      final all = await ServiceLocator.properties.listings();
      if (!mounted) return;
      setState(() => _all = all);
    } catch (_) {
      // Options degrade to "All" only; the results list surfaces its own error.
    }
  }

  // --- option derivation ----------------------------------------------------

  List<String> get _states {
    if (_live) {
      final options = ref.read(entrepreneurNotifierProvider).filterOptions;
      if (options != null) return options.states;
    }
    return PropertyFilter.statesIn(_all).skip(1).toList();
  }

  List<String> get _cities {
    if (_live) {
      final options = ref.read(entrepreneurNotifierProvider).filterOptions;
      if (options != null) return options.cities;
    }
    return PropertyFilter.citiesIn(_all).skip(1).toList();
  }

  List<String> get _types {
    if (_live) {
      final options = ref.read(entrepreneurNotifierProvider).filterOptions;
      if (options != null) return options.propertyTypes;
    }
    return PropertyFilter.typesIn(_all).skip(1).toList();
  }

  // --- results --------------------------------------------------------------

  /// The visible list.
  ///
  /// Live mode renders exactly what the server filtered — re-applying the
  /// structured filter locally would contradict the server's total. The one
  /// exception is [PropertyFilter.hasTourOnly], which has no server parameter
  /// in the explore projection; it is applied here and is only reachable when
  /// the loaded set actually carries tours (see [_toursAvailable]).
  List<CommercialProperty> get _results {
    final model = ref.read(entrepreneurNotifierProvider);
    var rows = _live
        ? List.of(model.explore)
        : model.explore.where(filter.matches).toList();
    if (filter.hasTourOnly) {
      rows = rows.where((p) => p.hasTour).toList();
    }
    if (!_live) rows.sort(_compare(_sort));
    return rows;
  }

  bool get _toursAvailable => _results.any((p) => p.hasTour);

  bool get _verificationCanNarrow =>
      _results.any((p) => p.verification != VerificationStatus.verified);

  /// Rebuilds the server criteria from the current UI state and re-runs the
  /// search from the first page. Sort keys are the backend's `_SORTS`
  /// whitelist — nothing is invented here.
  void _applyServerState() {
    if (!_live) return;
    final notifier = ref.read(entrepreneurNotifierProvider.notifier);
    notifier.setExploreCriteria(
      ExploreQuery.fromCriteria(
        query: notifier.query,
        state: filter.state == PropertyFilter.anyState ? null : filter.state,
        city: filter.city == PropertyFilter.anyArea ? null : filter.city,
        propertyType: filter.propertyType == PropertyFilter.anyType
            ? null
            : filter.propertyType,
        minPrice: filter.minRentalRm,
        maxPrice: filter.maxRentalRm,
        minSize: filter.minSizeSqft,
        maxSize: filter.maxSizeSqft,
        nearbyOnly: nearbyOnly,
        sort: _sort,
      ),
    );
  }

  void _setSort(ExploreSortOption sort) {
    if (sort == _sort) return;
    setState(() => _sort = sort);
    // Live: the key travels to the server (whitelisted only). Demo: the full
    // list is already in memory and `_results` applies the same comparator.
    _applyServerState();
  }

  Comparator<CommercialProperty> _compare(ExploreSortOption sort) => (a, b) {
    final cmp = switch (sort) {
      ExploreSortOption.priceAsc => a.rentalRm.compareTo(b.rentalRm),
      ExploreSortOption.priceDesc => b.rentalRm.compareTo(a.rentalRm),
      ExploreSortOption.sizeAsc => a.sizeSqft.compareTo(b.sizeSqft),
      ExploreSortOption.sizeDesc => b.sizeSqft.compareTo(a.sizeSqft),
      ExploreSortOption.psfAsc => _psf(a).compareTo(_psf(b)),
      ExploreSortOption.newest => 0,
    };
    return cmp != 0 ? cmp : a.id.compareTo(b.id);
  };

  /// Price per sq ft. Falls back to the stored `psf`, then to a derived value;
  /// a listing with no usable size sorts last instead of pretending to be the
  /// cheapest.
  static double _psf(CommercialProperty p) {
    if (p.psf != null && p.psf! > 0) return p.psf!;
    if (p.sizeSqft > 0 && p.rentalRm > 0) return p.rentalRm / p.sizeSqft;
    return double.infinity;
  }

  void _onSearchChanged(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 400), () {
      if (!mounted) return;
      ref.read(entrepreneurNotifierProvider.notifier).setQuery(value);
    });
  }

  void _clearSearch() {
    _searchDebounce?.cancel();
    _search.clear();
    ref.read(entrepreneurNotifierProvider.notifier).setQuery('');
    setState(() {});
  }

  // --- filter sheet ---------------------------------------------------------

  Future<void> _openFilter([MobileFilterSection? section]) async {
    final result = await showMobileFilterSheet(
      context,
      current: filter,
      nearbyOnly: nearbyOnly,
      states: _states,
      cities: _cities,
      propertyTypes: _types,
      initialSection: section,
      verificationCanNarrow: _verificationCanNarrow,
      toursAvailable: _toursAvailable,
      rentCeiling: _rentCeiling,
      sizeCeiling: _sizeCeiling,
    );
    if (result == null || !mounted) return;
    setState(() {
      filter = result.filter;
      nearbyOnly = result.nearbyOnly;
    });
    _applyServerState();
  }

  double? get _rentCeiling {
    final rows = ref.read(entrepreneurNotifierProvider).explore;
    if (rows.isEmpty) return null;
    return rows.map((p) => p.rentalMaxRm).reduce((a, b) => a > b ? a : b);
  }

  double? get _sizeCeiling {
    final rows = ref.read(entrepreneurNotifierProvider).explore;
    if (rows.isEmpty) return null;
    return rows.map((p) => p.sizeSqft).reduce((a, b) => a > b ? a : b);
  }

  /// True when the verification criterion can still change the current result
  /// set. Availability is judged from what is *visible*, so it goes false the
  /// moment the filter is applied and every remaining row is verified.
  bool get _canOfferVerified => filter.verifiedOnly || _verificationCanNarrow;

  /// Same rule for tours: an applied tour filter must stay switchable off even
  /// though every visible row now carries a tour.
  bool get _canOfferTour => filter.hasTourOnly || _toursAvailable;

  void _toggleVerified() {
    // Only *turning the filter on* needs the availability guard. Turning it
    // off always works, otherwise the chip would disable itself the moment it
    // was applied and the user would be stuck with a filter they cannot clear.
    if (!filter.verifiedOnly && !_verificationCanNarrow) {
      _explain(
        'Every listing currently shown is already admin-verified, so this '
        'cannot narrow the list further.',
      );
      return;
    }
    setState(
      () => filter = filter.copyWith(verifiedOnly: !filter.verifiedOnly),
    );
    _applyServerState();
  }

  void _toggleTour() {
    if (!filter.hasTourOnly && !_toursAvailable) {
      _explain(
        'No published 360° tours exist yet. The tour filter becomes available '
        'once a capture is approved.',
      );
      return;
    }
    setState(() => filter = filter.copyWith(hasTourOnly: !filter.hasTourOnly));
    _applyServerState();
  }

  void _explain(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message, style: const TextStyle(fontSize: 12.5)),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 4),
        ),
      );
  }

  void _clearFilters() {
    setState(() {
      filter = PropertyFilter.empty;
      nearbyOnly = _live;
      _sort = ExploreSortOption.newest;
    });
    _searchDebounce?.cancel();
    _search.clear();
    // Save the cleared query without searching: _applyServerState() below
    // re-runs the search with BOTH the cleared query and the cleared filters,
    // so only one request goes out.
    ref
        .read(entrepreneurNotifierProvider.notifier)
        .setQuery('', reload: false);
    _applyServerState();
  }

  void _retry() {
    final model = ref.read(entrepreneurNotifierProvider);
    if (model.explore.isNotEmpty &&
        model.exploreHasMore &&
        model.error != null) {
      // A failed Load More keeps the loaded rows; retry continues the page.
      ref.read(entrepreneurNotifierProvider.notifier).loadMore();
    } else {
      ref.read(entrepreneurNotifierProvider.notifier).loadExplore();
    }
  }

  void _openDetail(String id) => Navigator.of(
    context,
  ).pushNamed('/entrepreneur/property-detail', arguments: id);

  /// Pull-to-refresh: re-runs the *current* criteria from the first page.
  /// Filters and the search term are already stored in the notifier, so one
  /// [loadExplore] is enough — re-applying the criteria here used to fire a
  /// second, immediately stale request on every refresh.
  /// A failure leaves the rows already on screen.
  Future<void> _refresh() async {
    await ref.read(entrepreneurNotifierProvider.notifier).loadExplore();
  }

  // --- build ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return MobileAppShell(
      title: 'Explore',
      currentRoute: '/entrepreneur/explore',
      body: RefreshIndicator(
        color: SitewiseColors.action,
        onRefresh: _refresh,
        child: CustomScrollView(
          // Always scrollable so the gesture works even when the list is
          // shorter than the viewport (empty state, single result).
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(child: _header()),
            ..._bodySlivers(),
          ],
        ),
      ),
    );
  }

  Widget _header() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const M3ScreenHeading(
          eyebrow: 'Listing discovery',
          title: 'Find a location',
          lead: 'Find a commercial space that fits your business and budget.',
        ),
        const SizedBox(height: 10),
        MobileSearchField(
          controller: _search,
          hint: 'Search property, address or town',
          onChanged: _onSearchChanged,
          onSubmitted: (v) {
            _searchDebounce?.cancel();
            ref.read(entrepreneurNotifierProvider.notifier).setQuery(v);
          },
          onClear: _clearSearch,
          trailing: MobileIconAction(
            icon: showMap ? Icons.list_rounded : Icons.map_outlined,
            tooltip: showMap ? 'Show list' : 'Show map',
            active: showMap,
            onPressed: () => setState(() => showMap = !showMap),
          ),
        ),
        const SizedBox(height: 10),
        MobileFilterTileGrid(tiles: _tiles()),
        const SizedBox(height: 8),
        _criteriaChips(),
      ],
    ),
  );

  List<MobileFilterTile> _tiles() => [
    MobileFilterTile(
      icon: Icons.payments_outlined,
      title: 'Monthly rent',
      value: _rentLabel,
      helper: 'Stay within your F&B budget',
      active: filter.minRentalRm != null || filter.maxRentalRm != null,
      onTap: () => _openFilter(MobileFilterSection.rent),
    ),
    MobileFilterTile(
      icon: Icons.aspect_ratio_rounded,
      title: 'Floor area',
      value: _sizeLabel,
      helper: 'Find the right space for your concept',
      active: filter.minSizeSqft != null || filter.maxSizeSqft != null,
      onTap: () => _openFilter(MobileFilterSection.area),
    ),
    MobileFilterTile(
      icon: Icons.place_outlined,
      title: 'Location',
      value: _locationLabel,
      helper: 'Choose your preferred area',
      active:
          filter.city != PropertyFilter.anyArea ||
          filter.state != PropertyFilter.anyState,
      onTap: () => _openFilter(MobileFilterSection.location),
    ),
    MobileFilterTile(
      icon: Icons.storefront_outlined,
      title: 'Property type',
      value: filter.propertyType == PropertyFilter.anyType
          ? 'All types'
          : filter.propertyType,
      helper: 'Shoplot, retail, mall and more',
      active: filter.propertyType != PropertyFilter.anyType,
      onTap: () => _openFilter(MobileFilterSection.propertyType),
    ),
  ];

  String get _rentLabel {
    final min = filter.minRentalRm;
    final max = filter.maxRentalRm;
    if (min == null && max == null) return 'Any budget';
    if (min != null && max != null) {
      return 'RM ${_rm(min)}–${_rm(max)}';
    }
    return min != null ? 'From RM ${_rm(min)}' : 'Up to RM ${_rm(max!)}';
  }

  String get _sizeLabel {
    final min = filter.minSizeSqft;
    final max = filter.maxSizeSqft;
    if (min == null && max == null) return 'Any size';
    if (min != null && max != null) return '${_sqft(min)}–${_sqft(max)}';
    return min != null ? 'From ${_sqft(min)}' : 'Up to ${_sqft(max!)}';
  }

  String get _locationLabel {
    if (filter.city != PropertyFilter.anyArea) return filter.city;
    if (filter.state != PropertyFilter.anyState) return filter.state;
    return 'All locations';
  }

  static String _rm(double v) => v.toStringAsFixed(0);

  static String _sqft(double v) => '${v.toStringAsFixed(0)} sq ft';

  Widget _criteriaChips() => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      MobileToggleChip(
        label: 'Verified',
        icon: Icons.verified_outlined,
        // "On" when the result set is already entirely verified, so the chip
        // never claims a filter is applied when it is not.
        selected: filter.verifiedOnly || !_verificationCanNarrow,
        enabled: _canOfferVerified,
        semanticHint: _canOfferVerified
            ? 'Only admin-verified listings'
            : 'All listings shown are already verified',
        onTap: _toggleVerified,
        onDisabledTap: _toggleVerified,
      ),
      MobileToggleChip(
        label: '360° tour',
        icon: Icons.threesixty_rounded,
        selected: filter.hasTourOnly,
        enabled: _canOfferTour,
        semanticHint: _canOfferTour
            ? 'Only listings with a published virtual tour'
            : 'No published tours yet',
        onTap: _toggleTour,
        onDisabledTap: _toggleTour,
      ),
      MobileToggleChip(
        label: filter.activeCount == 0
            ? 'All filters'
            : 'All filters · ${filter.activeCount}',
        icon: Icons.tune_rounded,
        selected: filter.activeCount > 0,
        onTap: _openFilter,
      ),
    ],
  );

  List<Widget> _bodySlivers() {
    final model = ref.watch(entrepreneurNotifierProvider);

    if (model.loading) {
      return [
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: MobilePropertyListSkeleton(),
          ),
        ),
      ];
    }
    if (model.error != null && model.explore.isEmpty) {
      return [_sliverBox(_errorState(model))];
    }
    if (showMap) return [_sliverBox(_mapView())];

    final results = _results;
    if (results.isEmpty) {
      return [
        _sliverBox(
          model.error != null ? _errorState(model) : _emptyState(model),
        ),
      ];
    }

    final footerRows = _footerRows(model);
    return [
      SliverToBoxAdapter(child: _sectionHeader(results.length, model)),
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
        sliver: SliverList.separated(
          itemCount: results.length,
          separatorBuilder: (_, _) => const SizedBox(height: 10),
          itemBuilder: (context, i) {
            final p = results[i];
            final appState = ref.watch(appNotifierProvider);
            return MobilePropertyCard(
              property: p,
              saved: appState.saved.contains(p.id),
              onToggleSaved: () =>
                  ref.read(appNotifierProvider.notifier).toggleSaved(p.id),
              compared: appState.compared.contains(p.id),
              onToggleCompare: () =>
                  ref.read(appNotifierProvider.notifier).toggleCompared(p.id),
              onTap: () => _openDetail(p.id),
            );
          },
        ),
      ),
      SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.fromLTRB(16, 8, 16, 122 + footerRows * 44),
          child: _footer(context, model),
        ),
      ),
    ];
  }

  Widget _sliverBox(Widget child) => SliverToBoxAdapter(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 122),
      child: child,
    ),
  );

  int _footerRows(EntrepreneurState model) {
    if (model.error != null && model.explore.isNotEmpty) return 1;
    if (model.listRefreshing && model.explore.isNotEmpty) return 1;
    if (_live && model.exploreHasMore) return 1;
    if (_live && model.explore.isNotEmpty && !model.exploreHasMore) return 1;
    return 0;
  }

  /// "Matching listings · N properties" with the sort control on the right.
  Widget _sectionHeader(int loaded, EntrepreneurState model) {
    final total = model.exploreTotal;
    // `GET /explore/properties` has no tour criterion, so "360° tour only" can
    // only narrow the rows already loaded. The header must then describe those
    // rows instead of repeating the server total, which would promise listings
    // that are not on screen.
    final localOnlyTour = _live && filter.hasTourOnly;
    final countText = localOnlyTour
        ? '$loaded of ${model.explore.length} loaded '
              '${model.explore.length == 1 ? 'property' : 'properties'}'
        : _live
        ? (total != null
              ? (total > loaded
                    ? '$loaded of $total properties'
                    : '$total ${total == 1 ? 'property' : 'properties'}')
              : '$loaded properties')
        : '$loaded sample ${loaded == 1 ? 'property' : 'properties'}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Matching listings',
                  style: TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.4,
                    color: SitewiseM3.ink,
                  ),
                ),
                const SizedBox(height: 1),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    countText,
                    style: const TextStyle(
                      fontSize: 11.5,
                      color: SitewiseColors.muted,
                    ),
                  ),
                ),
              ],
            ),
          ),
          _sortButton(),
        ],
      ),
    );
  }

  /// Server-recognised sorts only (`_SORTS` in `fyp_property_repository.py`).
  /// Nothing is labelled "Recommended": no ranking model is connected.
  static const List<(ExploreSortOption, String)> _sortOptions = [
    (ExploreSortOption.newest, 'Default order'),
    (ExploreSortOption.priceAsc, 'Monthly rent: low to high'),
    (ExploreSortOption.priceDesc, 'Monthly rent: high to low'),
    (ExploreSortOption.sizeAsc, 'Floor area: smallest first'),
    (ExploreSortOption.sizeDesc, 'Floor area: largest first'),
    (ExploreSortOption.psfAsc, 'Rental cost per sq ft'),
  ];

  Widget _sortButton() {
    return PopupMenuButton<ExploreSortOption>(
      initialValue: _sort,
      tooltip: 'Sort listings',
      position: PopupMenuPosition.under,
      onSelected: _setSort,
      itemBuilder: (context) => [
        for (final (value, label) in _sortOptions)
          CheckedPopupMenuItem(
            value: value,
            checked: value == _sort,
            child: Text(label, style: const TextStyle(fontSize: 13)),
          ),
      ],
      child: Container(
        constraints: const BoxConstraints(minHeight: 40),
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
        decoration: BoxDecoration(
          color: SitewiseColors.surface,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: SitewiseColors.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.swap_vert_rounded,
              size: 15,
              color: SitewiseColors.ink,
            ),
            const SizedBox(width: 5),
            Text(
              'Sort',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: _sort == ExploreSortOption.newest
                    ? SitewiseColors.ink
                    : SitewiseColors.action,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // --- states ---------------------------------------------------------------

  /// Distinct error presentation per failure class. `model.error` already
  /// carries the readable sentence from the shared failure taxonomy.
  Widget _errorState(EntrepreneurState model) {
    final failure = model.exploreFailure;
    final (title, icon, fallback) = switch (failure) {
      UnauthorizedFailure _ => (
        'Your session has expired',
        Icons.lock_outline_rounded,
        'Sign in again to load your listings.',
      ),
      ServiceFailure _ => (
        'The service hit a problem',
        Icons.dns_outlined,
        'The Sitewise service could not answer. Try again.',
      ),
      ResponseFormatFailure _ => (
        'Unexpected server response',
        Icons.data_object_rounded,
        'The property data could not be read. Try again.',
      ),
      NetworkFailure _ => (
        'Unable to reach Sitewise',
        Icons.wifi_off_rounded,
        'Check that the API server is running and reachable.',
      ),
      // 422: a criterion the backend cannot accept (e.g. a radius outside
      // the whitelist) is a filter problem, not a connection problem.
      ValidationFailure _ => (
        'These filters could not be applied',
        Icons.tune_rounded,
        'The service rejected the search criteria. Adjust the filters and retry.',
      ),
      NotFoundFailure _ => (
        'This listing is no longer available',
        Icons.search_off_rounded,
        'Refresh the list to see the current properties.',
      ),
      _ => (
        'Data loading error',
        Icons.error_outline_rounded,
        'The listings could not be loaded. Try again.',
      ),
    };
    if (kDebugMode && failure != null) {
      // Safe diagnostic: the failure TYPE only. Never the row, URL, token or
      // raw backend message — those may carry data that must not reach a log.
      debugPrint('Explore load failed: ${failure.runtimeType}');
    }
    return SitewiseErrorState(
      title: title,
      message: model.error ?? fallback,
      icon: icon,
      onRetry: _retry,
    );
  }

  /// Empty results: a genuine zero must read differently from "your filters
  /// matched nothing", and the default cluster rule hides listings that DO
  /// exist — so it gets its own escape hatch.
  Widget _emptyState(EntrepreneurState model) {
    final filtered = filter.isNotEmpty || nearbyOnly || model.query.isNotEmpty;
    if (nearbyOnly) {
      return SitewiseEmptyState(
        icon: Icons.storefront_outlined,
        title: filtered
            ? 'No matching properties with 3+ nearby'
            : 'No properties with 3+ neighbours within 500 m',
        message:
            'The default “3 other commercial properties within 500 m” rule is '
            'hiding every listing that otherwise matches. Turn it off to see '
            'all properties.',
        actionLabel: 'Show all properties',
        onAction: () {
          setState(() => nearbyOnly = false);
          _applyServerState();
        },
      );
    }
    return SitewiseEmptyState(
      icon: Icons.search_off_rounded,
      title: filtered ? 'No matching properties' : 'No published properties',
      message: filtered
          ? 'Try another search or clear the filters.'
          : 'There are no approved, published listings in the dataset yet. '
                'Check back soon.',
      actionLabel: filtered ? 'Clear filters' : null,
      onAction: filtered ? _clearFilters : null,
    );
  }

  Widget _footer(BuildContext context, EntrepreneurState model) {
    if (model.error != null && model.explore.isNotEmpty) {
      return Column(
        children: [
          _inlineError(model),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: _retry,
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: const Text('Retry'),
          ),
        ],
      );
    }
    if (model.listRefreshing && model.explore.isNotEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2.2),
          ),
        ),
      );
    }
    if (_live && model.exploreHasMore) {
      return Center(
        child: TextButton.icon(
          onPressed: () =>
              ref.read(entrepreneurNotifierProvider.notifier).loadMore(),
          icon: const Icon(Icons.expand_more_rounded, size: 19),
          label: const Text('Load more'),
        ),
      );
    }
    return const SizedBox.shrink();
  }

  Widget _inlineError(EntrepreneurState model) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: SitewiseColors.dangerWash,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: SitewiseColors.danger.withValues(alpha: .4)),
    ),
    child: Text(
      model.error ?? 'We could not load more listings.',
      style: const TextStyle(
        fontSize: 12.5,
        fontWeight: FontWeight.w600,
        color: SitewiseColors.ink,
      ),
    ),
  );

  Widget _mapView() {
    final results = _results;
    return SizedBox(
      height: 520,
      child: SitewiseMapPanel(
        height: 520,
        // Rows without coordinates are skipped honestly — no (0,0) pin.
        pins: [
          for (final p in results)
            if (p.hasCoordinates)
              MapPin(
                id: p.id,
                label: p.title,
                latitude: p.latitude,
                longitude: p.longitude,
              ),
        ],
        onPinTap: (pin) => _openPropertySheet(pin.id),
      ),
    );
  }

  void _openPropertySheet(String id) {
    final matches = _results.where((p) => p.id == id).toList();
    if (matches.isEmpty) return;
    final p = matches.first;
    showSitewiseBottomSheet<void>(
      context,
      title: p.title,
      builder: (_) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('${p.address}, ${p.city}'),
          const SizedBox(height: 4),
          Text(
            '${p.rentalDisplay} · ${p.sizeSqft.toStringAsFixed(0)} sq ft',
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 12),
          SitewiseButton(
            label: 'View property',
            onPressed: () {
              Navigator.of(context).pop();
              _openDetail(p.id);
            },
          ),
        ],
      ),
    );
  }
}
