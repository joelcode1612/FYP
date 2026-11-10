import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';
import 'package:flutter/material.dart';

import '../../../../application/services/service_locator.dart';
import '../../../../core/config/mobile_config.dart';
import '../../../../core/theme/sitewise_m3.dart';
import '../../../../core/theme/sitewise_theme.dart';
import '../../../shared/widgets/sitewise_bottom_sheet.dart';
import '../../../shared/widgets/sitewise_button.dart';
import '../../../shared/widgets/sitewise_empty_state.dart';
import '../../../shared/widgets/sitewise_error_state.dart';
import '../../../shared/widgets/sitewise_filter_chip.dart';
import '../../../shared/widgets/sitewise_map_panel.dart';
import '../../shell/mobile_app_shell.dart';
import '../../widgets/m3_kit.dart';
import '../../widgets/mobile_filter_sheet.dart';
import '../../widgets/mobile_property_card.dart';
import '../../widgets/mobile_search_field.dart';
import '../../widgets/mobile_skeleton.dart';

/// Mobile explore — Option A **"Find a location"**.
///
/// Two data paths, one screen:
///
///  * **Live** ([MobileConfig.usesLiveApi]) — every filter, the search term
///    and the sort travel to `GET /api/v1/explore/properties` inside the
///    state's [ExploreQuery] criteria, so counts and pagination describe the
///    whole published dataset, not the loaded page. Filter facets come from
///    `GET /explore/options`. Quick filters that the backend cannot apply
///    (ground floor) are hidden, because a client-only chip over one page
///    would misrepresent the database.
///  * **Demo** — the previous behaviour: filters narrow the already-loaded
///    demo list locally.
///
/// Errors are classified (connection / session / server / contract) instead
/// of one generic "check your connection" message, and a genuine empty
/// result is never shown for a failed request.
class EntrepreneurExploreMobilePage extends ConsumerStatefulWidget {
  /// Open directly in map mode (Home → "Explore on map").
  final bool startInMap;

  const EntrepreneurExploreMobilePage({super.key, this.startInMap = false});

  @override
  ConsumerState<EntrepreneurExploreMobilePage> createState() =>
      _EntrepreneurExploreMobilePageState();
}

/// Option A quick filters. `budget` maps to the server's `max_price`;
/// `ground` has no server parameter (it filters `requirements`, which the
/// live explore projection does not carry) so it is offered in demo mode
/// only — a chip whose rule cannot apply to the dataset is worse than none.
enum _QuickFilter { all, budget, ground, fnb }

class _EntrepreneurExploreMobilePageState
    extends ConsumerState<EntrepreneurExploreMobilePage> {
  late bool showMap = widget.startInMap;
  MobilePropertyFilter filter = MobilePropertyFilter.empty;
  _QuickFilter quick = _QuickFilter.all;
  bool get _live => MobileConfig.usesLiveApi;

  /// Debounce for the search field: one request per settled term, not one
  /// per keystroke. The controller's sequence numbers already guarantee a
  /// slow earlier response can never overwrite a newer one; the timer only
  /// avoids spending the requests.
  Timer? _searchDebounce;

  /// Unfiltered demo listings, used only to derive the category/area options
  /// when no server facets exist (demo mode).
  List<CommercialProperty> _all = const [];

  @override
  void initState() {
    super.initState();
    // The load publishes synchronously; a kick from initState would modify
    // the provider while the widget tree is building.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(entrepreneurNotifierProvider.notifier).loadExplore();
    });
    if (!_live) _loadDemoOptions();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
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

  List<String> get _types {
    final options = ref
        .read(entrepreneurNotifierProvider)
        .filterOptions;
    if (_live && options != null) return options.propertyTypes;
    final set = _all.map((p) => p.propertyType).toSet().toList()..sort();
    return set;
  }

  List<String> get _cities {
    final options = ref
        .read(entrepreneurNotifierProvider)
        .filterOptions;
    if (_live && options != null) return options.cities;
    final set = _all.map((p) => p.city).toSet().toList()..sort();
    return set;
  }

  /// The visible list. Live mode renders exactly what the server filtered —
  /// re-filtering the page locally would lie about the database. Demo mode
  /// keeps its local narrowing, plus the local sort order.
  List<CommercialProperty> get _results {
    final model = ref.read(entrepreneurNotifierProvider);
    if (_live) return List.of(model.explore);
    final narrowed = model.explore
        .where(filter.matches)
        .where(_quickMatches)
        .toList();
    narrowed.sort(_compare(_sort));
    return narrowed;
  }

  bool _quickMatches(CommercialProperty p) => switch (quick) {
    _QuickFilter.all => true,
    _QuickFilter.budget => p.rentalRm <= 8500,
    _QuickFilter.ground => p.requirements.contains('Ground Floor'),
    _QuickFilter.fnb => p.isFnbSuitable == true,
  };

  /// Rebuilds the server criteria from the current UI filter state and
  /// re-runs the search from the first page. Sort keys are the backend's
  /// `_SORTS` whitelist — nothing is invented here.
  void _applyServerState() {
    if (!_live) return;
    final notifier = ref.read(entrepreneurNotifierProvider.notifier);
    notifier.setExploreCriteria(
      ExploreQuery.fromCriteria(
        query: notifier.query,
        city: filter.city == MobilePropertyFilter.allAreas
            ? null
            : filter.city,
        propertyType: filter.propertyType == MobilePropertyFilter.allTypes
            ? null
            : filter.propertyType,
        availability: filter.availability,
        maxPrice: quick == _QuickFilter.budget
            ? 8500
            : filter.maxBudgetRm,
        minSize: filter.minSizeSqft,
        fnbSuitable: quick == _QuickFilter.fnb,
        sort: _sort,
      ),
    );
  }

  ExploreSortOption _sort = ExploreSortOption.newest;

  void _setSort(ExploreSortOption sort) {
    setState(() => _sort = sort);
    // Live mode: the sort key travels to the server (a whitelisted key only).
    // Demo mode: the full list is already in memory, so `_results` applies
    // the same comparator locally — no server round-trip is pretended.
    _applyServerState();
  }

  Comparator<CommercialProperty> _compare(ExploreSortOption sort) =>
      (CommercialProperty a, CommercialProperty b) {
        final cmp = switch (sort) {
          ExploreSortOption.priceAsc => a.rentalRm.compareTo(b.rentalRm),
          ExploreSortOption.priceDesc => b.rentalRm.compareTo(a.rentalRm),
          ExploreSortOption.sizeAsc => a.sizeSqft.compareTo(b.sizeSqft),
          ExploreSortOption.sizeDesc => b.sizeSqft.compareTo(a.sizeSqft),
          _ => 0,
        };
        return cmp != 0 ? cmp : a.id.compareTo(b.id);
      };

  void _onSearchChanged(String q) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 450), () {
      if (!mounted) return;
      ref.read(entrepreneurNotifierProvider.notifier).setQuery(q);
    });
  }

  Future<void> _openFilter() async {
    final applied = await showMobilePropertyFilterSheet(
      context,
      current: filter,
      propertyTypes: _types,
      cities: _cities,
      showVerifiedToggle: !_live,
      availability: _live
          ? ref.read(entrepreneurNotifierProvider).filterOptions?.availability
          : null,
    );
    if (applied != null && mounted) {
      setState(() => filter = applied);
      _applyServerState();
    }
  }

  void _clearFilters() {
    setState(() {
      filter = MobilePropertyFilter.empty;
      quick = _QuickFilter.all;
      _sort = ExploreSortOption.newest;
    });
    _applyServerState();
    ref.read(entrepreneurNotifierProvider.notifier).setFilter('All');
    ref.read(entrepreneurNotifierProvider.notifier).setQuery('');
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

  @override
  Widget build(BuildContext context) {
    // The entrepreneur provider state repaints the results; the app-wide
    // saved/compare sets repaint the saved/compare card toggles.
    return MobileAppShell(
            title: 'Explore',
            currentRoute: '/entrepreneur/explore',
            body: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const M3ScreenHeading(
                        eyebrow: 'Listing discovery',
                        title: 'Find a location',
                        lead:
                            'Browse commercial spaces suitable for F&B concepts.',
                      ),
                      const SizedBox(height: 14),
                      MobileSearchField(
                        hint: 'Search area or property',
                        onChanged: _onSearchChanged,
                        trailing: MobileIconAction(
                          icon: showMap
                              ? Icons.list_rounded
                              : Icons.map_outlined,
                          tooltip: showMap ? 'Show list' : 'Show map',
                          active: showMap,
                          onPressed: () => setState(() => showMap = !showMap),
                        ),
                      ),
                      const SizedBox(height: 12),
                      _quickChips(),
                      const SizedBox(height: 10),
                      _sortRow(),
                      const SizedBox(height: 10),
                      _categoryChips(),
                      const SizedBox(height: 10),
                      _locationFilterRow(),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Expanded(child: _body()),
              ],
            ),
    );
  }

  Widget _body() {
    final model = ref.watch(entrepreneurNotifierProvider);
    final appState = ref.watch(appNotifierProvider);
    if (model.loading) return const MobilePropertyListSkeleton();
    if (model.error != null && model.explore.isEmpty) {
      return _errorState(model);
    }
    if (showMap) return _mapView();

    final results = _results;
    if (results.isEmpty && model.error == null) {
      return _emptyState(model);
    }
    if (results.isEmpty && model.error != null) return _errorState(model);

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 122),
      itemCount: results.length + 1 + _footerRows(model),
      separatorBuilder: (context, index) => const SizedBox(height: 12),
      itemBuilder: (context, i) {
        if (i == 0) {
          return _sectionRow(results.length, model);
        }
        if (i <= results.length) {
          final p = results[i - 1];
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
        }
        return _footer(context, model, i - results.length - 1);
      },
    );
  }

  int _footerRows(EntrepreneurState model) {
    if (model.error != null && model.explore.isNotEmpty) return 2;
    if (model.listRefreshing && model.explore.isNotEmpty) return 1;
    if (_live && model.exploreHasMore) return 1;
    if (_live && model.explore.isNotEmpty && !model.exploreHasMore) return 1;
    return 0;
  }

  /// Distinct error presentation per failure class. `model.error` already
  /// carries the readable, non-technical sentence from the shared failure
  /// taxonomy; the title and icon add the class.
  Widget _errorState(EntrepreneurState model) {
    final failure = model.exploreFailure;
    final (title, icon) = switch (failure) {
      UnauthorizedFailure _ => (
        'Your session has expired',
        Icons.lock_outline_rounded,
      ),
      ServiceFailure _ => (
        'The service hit a problem',
        Icons.dns_outlined,
      ),
      ResponseFormatFailure _ => (
        'Unexpected server response',
        Icons.data_object_rounded,
      ),
      NetworkFailure _ => (
        'Unable to reach Sitewise',
        Icons.wifi_off_rounded,
      ),
      _ => ('Unable to load properties', Icons.error_outline_rounded),
    };
    return SitewiseErrorState(
      title: title,
      message: model.error ?? 'Please check your connection and try again.',
      icon: icon,
      onRetry: _retry,
    );
  }

  /// Empty results: a genuine zero from the server must read differently
  /// from "your filters matched nothing".
  Widget _emptyState(EntrepreneurState model) {
    final filtered =
        filter.isActive ||
        quick != _QuickFilter.all ||
        model.query.isNotEmpty;
    final total = model.exploreTotal;
    return SitewiseEmptyState(
      icon: Icons.search_off_rounded,
      title: filtered ? 'No matching properties' : 'No published properties',
      message: filtered
          ? 'Try another search or clear the filters.'
          : (total != null && total == 0
                ? 'There are no approved, published listings in the dataset '
                    'yet. Check back soon.'
                : 'Try another search or clear the filters.'),
      actionLabel: filtered ? 'Clear filters' : null,
      onAction: filtered ? _clearFilters : null,
    );
  }

  /// Footer builder: load-more trigger, spinner, end-of-results and the
  /// inline retry after a failed page.
  Widget _footer(BuildContext context, EntrepreneurState model, int index) {
    if (model.error != null && model.explore.isNotEmpty) {
      if (index == 0) {
        return _inlineError(model);
      }
      return TextButton.icon(
        onPressed: _retry,
        icon: const Icon(Icons.refresh_rounded, size: 18),
        label: const Text('Retry'),
      );
    }
    if (model.listRefreshing && model.explore.isNotEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 18),
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
    // End of results.
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Center(
        child: Text(
          'You have reached the end of the results.',
          style: TextStyle(fontSize: 11.5, color: SitewiseColors.overline),
        ),
      ),
    );
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

  /// Option A quick chips. Ground floor exists only in demo mode: the live
  /// explore projection carries no requirements field and the backend has no
  /// floor-level filter, so the chip would silently filter one page.
  Widget _quickChips() {
    final entries = <(_QuickFilter, String)>[
      (_QuickFilter.all, 'All spaces'),
      (_QuickFilter.budget, 'Under RM 8.5k'),
      if (!_live) (_QuickFilter.ground, 'Ground floor'),
      if (_live) (_QuickFilter.fnb, 'F&B suitable'),
    ];
    return Semantics(
      container: true,
      label: 'Listing filters',
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final (value, label) in entries)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: SitewiseFilterChip(
                  label: label,
                  selected: quick == value,
                  onTap: () {
                    setState(() => quick = value);
                    _applyServerState();
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Server-recognised sorts only (`_SORTS` in `fyp_property_repository.py`).
  static const List<(ExploreSortOption, String)> _sortOptions = [
    (ExploreSortOption.newest, 'Newest'),
    (ExploreSortOption.priceAsc, 'Lowest rental'),
    (ExploreSortOption.priceDesc, 'Highest rental'),
    (ExploreSortOption.sizeAsc, 'Smallest area'),
    (ExploreSortOption.sizeDesc, 'Largest area'),
  ];

  Widget _sortRow() {
    final label = _sortOptions
        .firstWhere((o) => o.$1 == _sort, orElse: () => _sortOptions.first)
        .$2;
    return Row(
      children: [
        const Icon(Icons.swap_vert_rounded, size: 16, color: SitewiseColors.muted),
        const SizedBox(width: 6),
        Text(
          'Sort: $label',
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: SitewiseColors.ink,
          ),
        ),
        const Spacer(),
        PopupMenuButton<ExploreSortOption>(
          initialValue: _sort,
          tooltip: 'Sort listings',
          onSelected: _setSort,
          itemBuilder: (context) => [
            for (final (value, label) in _sortOptions)
              PopupMenuItem(value: value, child: Text(label)),
          ],
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Change',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: SitewiseColors.action,
                  ),
                ),
                Icon(
                  Icons.expand_more_rounded,
                  size: 16,
                  color: SitewiseColors.action,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// `section-row` — "Available properties" + the real counts. Live mode
  /// distinguishes the server's total from the loaded rows; demo mode labels
  /// itself honestly as sample data.
  Widget _sectionRow(int count, EntrepreneurState model) {
    final total = model.exploreTotal;
    final countText = _live
        ? (total != null
              ? (total > count
                    ? '$count of $total results'
                    : '$total results')
              : '$count results')
        : '$count sample results';
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const Expanded(
            child: Text(
              'Available properties',
              style: TextStyle(
                fontFamily: kFontFamily,
                fontSize: 17,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.48,
                color: SitewiseM3.ink,
              ),
            ),
          ),
          Semantics(
            liveRegion: true,
            child: Text(
              countText,
              style: const TextStyle(
                fontFamily: kFontFamily,
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.54,
                color: SitewiseM3.overline,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _categoryChips() {
    final options = [MobilePropertyFilter.allTypes, ..._types];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final option in options)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: SitewiseFilterChip(
                label: option,
                selected: filter.propertyType == option,
                onTap: () {
                  setState(
                    () => filter = filter.copyWith(propertyType: option),
                  );
                  _applyServerState();
                },
              ),
            ),
        ],
      ),
    );
  }

  Widget _locationFilterRow() {
    final cityLabel = filter.city == MobilePropertyFilter.allAreas
        ? 'All areas'
        : filter.city;
    return Row(
      children: [
        InkWell(
          onTap: _openFilter,
          borderRadius: BorderRadius.circular(999),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: SitewiseColors.surface,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: SitewiseColors.border),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.place_outlined,
                  size: 15,
                  color: SitewiseColors.action,
                ),
                const SizedBox(width: 6),
                Text(
                  cityLabel,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: SitewiseColors.ink,
                  ),
                ),
                const Icon(
                  Icons.expand_more_rounded,
                  size: 16,
                  color: SitewiseColors.muted,
                ),
              ],
            ),
          ),
        ),
        const Spacer(),
        TextButton.icon(
          onPressed: _openFilter,
          icon: const Icon(Icons.tune, size: 17),
          label: Text(
            filter.isActive ? 'Filter · ${filter.activeCount}' : 'Filter',
          ),
          style: TextButton.styleFrom(
            foregroundColor: filter.isActive
                ? SitewiseColors.action
                : SitewiseColors.ink,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            minimumSize: const Size(0, 36),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            textStyle: const TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }

  Widget _mapView() {
    final results = _results;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: LayoutBuilder(
        builder: (c, constraints) => SitewiseMapPanel(
          height: constraints.maxHeight,
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
          if (p.hasSuitabilityScore) ...[
            const SizedBox(height: 4),
            Text(
              'Suitability ${p.suitabilityScore.toStringAsFixed(0)} '
              '(research index)',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ],
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
