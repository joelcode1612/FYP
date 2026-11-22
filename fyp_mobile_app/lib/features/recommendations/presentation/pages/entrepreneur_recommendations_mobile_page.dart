import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';
import 'package:fyp/features/recommendations/application/nearby_location_provider.dart';

import 'package:fyp/core/theme/sitewise_theme.dart';
import 'package:fyp/shared/presentation/layouts/mobile_app_shell.dart';
import 'package:fyp/shared/presentation/components/m3_kit.dart';
import 'package:fyp/shared/presentation/components/mobile_property_gallery.dart';
import 'package:fyp/shared/presentation/components/mobile_property_image.dart';

/// Entrepreneur discovery — **Recommendations** (mobile).
///
/// Replaces the old "Listing" tab. The five-destination navigation is
/// unchanged: Home · Recommendations · Assess · Favourites · Profile.
///
/// All ranking comes from `POST /api/v1/recommendations/search` through the
/// shared [EntrepreneurNotifier]; this screen never sorts or filters locally
/// and never holds the whole catalogue. Pages are appended from the server's
/// cursor, and only the built rows exist in the widget tree
/// (`ListView.builder`).
///
/// Two honest states are load-bearing here:
///
///  * a requirement the catalogue cannot answer is shown as **not verified**,
///    not as failed;
///  * the PU research score is presented as its own model. It is never folded
///    into the requirement-fit figure, and "unavailable" is stated rather than
///    shown as zero.
class EntrepreneurRecommendationsMobilePage extends ConsumerStatefulWidget {
  const EntrepreneurRecommendationsMobilePage({super.key});

  @override
  ConsumerState<EntrepreneurRecommendationsMobilePage> createState() =>
      _EntrepreneurRecommendationsMobilePageState();
}

// SITEWISE_EXPLICIT_SEARCH_GATE_V2
// Sorting, pagination and model defaults are not search criteria. Only
// explicitly selected requirements, a submitted query, or a nearby point
// can open the results list. Business type is not a general PU filter.
bool _hasSearchCriteria(RecommendationSearchRequest request) =>
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
    request.layoutPreferences.any((value) => value.trim().isNotEmpty) ||
    request.managedOnly ||
    (request.locationLatitude != null && request.locationLongitude != null);

class _EntrepreneurRecommendationsMobilePageState
    extends ConsumerState<EntrepreneurRecommendationsMobilePage> {
  final ScrollController _scroll = ScrollController();
  final TextEditingController _search = TextEditingController();
  bool _seeded = false;
  bool _nearbyBusy = false;
  String? _sessionUserId;

  /// Uncommitted draft selections survive closing the sheet by swipe/back.
  /// Applying via Show properties clears it. An externally changed applied
  /// request invalidates the old draft when the sheet is reopened.
  RecommendationSearchRequest? _filterDraft;
  String? _filterDraftBase;

  static String _requestKey(RecommendationSearchRequest request) =>
      request.copyWith(clearCursor: true).toJson().toString();

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    // The notifier publishes synchronously; kicking it from initState would
    // modify the provider while the tree is building.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _seeded) return;
      _seeded = true;
      _sessionUserId = ref.read(authNotifierProvider).user?.id;
      // Mobile filter fix: restore applied session criteria, not demo defaults.
      final notifier = ref.read(entrepreneurNotifierProvider.notifier);
      final initial = notifier.recommendationRequest;
      _search.text = initial.query ?? '';
      if (!_hasSearchCriteria(initial)) {
        // Cancel any stale browse; a fresh session must stay empty.
        notifier.clearRecommendationSearch();
        return;
      }
      final current = ref.read(entrepreneurNotifierProvider);
      if (!current.recommendationLoading &&
          !current.recommendationRefreshing &&
          current.recommendationTotal == null) {
        notifier.searchRecommendations(request: initial);
      }
    });
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _search.dispose();
    super.dispose();
  }

  void _applySearch(RecommendationSearchRequest request) {
    final notifier = ref.read(entrepreneurNotifierProvider.notifier);
    _filterDraft = null;
    _filterDraftBase = null;
    if (!_hasSearchCriteria(request)) {
      _search.clear();
      notifier.clearRecommendationSearch();
      return;
    }
    final query = request.query ?? '';
    if (_search.text != query) _search.text = query;
    notifier.applyRecommendationRequest(request.copyWith(clearCursor: true));
  }

  Future<void> _refreshSearch() async {
    final notifier = ref.read(entrepreneurNotifierProvider.notifier);
    if (!_hasSearchCriteria(notifier.recommendationRequest)) {
      notifier.clearRecommendationSearch();
      return;
    }
    await notifier.searchRecommendations();
  }

  /// Fetches the next page shortly before the list bottom is reached, so the
  /// user does not have to tap "Load more" on every page — but a tap still
  /// works, and the notifier deduplicates concurrent requests.
  void _onScroll() {
    if (!_scroll.hasClients) return;
    final remaining =
        _scroll.position.maxScrollExtent - _scroll.position.pixels;
    if (remaining > 480) return;
    final notifier = ref.read(entrepreneurNotifierProvider.notifier);
    if (!_hasSearchCriteria(notifier.recommendationRequest) ||
        !notifier.recommendationHasMore || notifier.recommendationRefreshing) {
      return;
    }
    notifier.loadMoreRecommendations();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(entrepreneurNotifierProvider);
    final visibleRows = _hasSearchCriteria(state.recommendationRequest)
        ? state.ranked
        : const <RankedProperty>[];
    final notifier = ref.read(entrepreneurNotifierProvider.notifier);
    final saved = ref.watch(appNotifierProvider.select((app) => app.saved));
    final compared = ref.watch(
      appNotifierProvider.select((app) => app.compared),
    );

    ref.listen<EntrepreneurState>(entrepreneurNotifierProvider, (previous, next) {
      if (previous == null ||
          !_seeded ||
          ref.read(authNotifierProvider).user?.id != _sessionUserId) {
        return;
      }
      final before = previous.recommendationRequest;
      final after = next.recommendationRequest;
      if (before.query != after.query) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || ref.read(authNotifierProvider).user?.id != _sessionUserId) return;
          final latest = ref.read(entrepreneurNotifierProvider).recommendationRequest;
          if (latest.query == after.query && _search.text != (after.query ?? '')) {
            _search.text = after.query ?? '';
          }
        });
      }
      // Restore the current session only when a preference change rebuilds
      // the controller and actually clears its search state.
      if (_hasSearchCriteria(before) &&
          !identical(previous.preferences, next.preferences) &&
          next.ranked.isEmpty && next.recommendationTotal == null &&
          !next.recommendationLoading && !next.recommendationRefreshing &&
          _requestKey(after) == _requestKey(const RecommendationSearchRequest())) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || ref.read(authNotifierProvider).user?.id != _sessionUserId) return;
          final current = ref.read(entrepreneurNotifierProvider);
          // A newer user action must always win over a scheduled restore.
          if (!identical(current.recommendationRequest, after) ||
              !identical(current.preferences, next.preferences)) {
            return;
          }
          ref.read(entrepreneurNotifierProvider.notifier)
              .searchRecommendations(request: before);
        });
      }
    });

    return MobileAppShell(
      title: 'Recommendations',
      currentRoute: '/entrepreneur/recommendations',
      body: RefreshIndicator(
        color: SitewiseColors.action,
        onRefresh: _refreshSearch,
        child: ListView.builder(
          controller: _scroll,
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
          // header + rows + (footer | empty | loading | error)
          itemCount: 1 + visibleRows.length + 1,
          itemBuilder: (context, index) {
            if (index == 0) return _header(state);
            final rowIndex = index - 1;
            if (rowIndex < visibleRows.length) {
              final item = visibleRows[rowIndex];
              return RecommendationCard(
                item: item,
                isSaved: saved.contains(item.id),
                isCompared: compared.contains(item.id),
                isSelected: item.id == state.selectedRankedId,
                onOpen: () => _openInsight(item),
                onSave: () => _toggleSaved(item.id),
                onCompare: () => _toggleCompared(item.id),
              );
            }
            return _footer(state, notifier);
          },
        ),
      ),
    );
  }

  // -- header ---------------------------------------------------------------

  // SiteWise mobile recommendations UI refinement (2026-11-21).
  // Search gets its own line; filters and sort share a predictable toolbar.
  Widget _header(EntrepreneurState state) {
    final total = state.recommendationTotal;
    final request = state.recommendationRequest;
    final hasCriteria = _hasSearchCriteria(request);
    final facets = state.recommendationFacets;
    final chips = _filterChips(request);
    final sortOptions = (facets?.sortOptions.isNotEmpty ?? false)
        ? facets!.sortOptions
        : _sortFallback;
    final currentSort = request.sort ?? 'best_match';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const M3ScreenHeading(
          eyebrow: 'Find a space that fits your vision',
          title: 'Recommendations',
          lead: 'Explore commercial spaces and assess their location fit.',
        ),
        const SizedBox(height: 14),
        // SiteWise nearby discovery: opt-in foreground location only.
        _nearbyToggle(request),
        const SizedBox(height: 12),
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: _search,
          builder: (context, value, _) => TextField(
            controller: _search,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: 'Search area, title or property ID',
              hintMaxLines: 1,
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: value.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Clear search',
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () {
                        _search.clear();
                        _applySearch(
                          request.copyWith(clearQuery: true),
                        );
                      },
                    ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(13),
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 15,
              ),
            ),
            onSubmitted: (value) {
              final text = value.trim();
              _applySearch(
                text.isEmpty
                    ? request.copyWith(clearQuery: true)
                    : request.copyWith(query: text),
              );
              FocusScope.of(context).unfocus();
            },
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            SizedBox(
              height: 52,
              child: OutlinedButton.icon(
                onPressed: _openFilters,
                icon: const Icon(Icons.tune_rounded, size: 19),
                label: Text(chips.isEmpty ? 'Filters' : 'Filters (${chips.length})'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: SitewiseColors.action,
                  side: const BorderSide(color: SitewiseColors.action),
                  padding: const EdgeInsets.symmetric(horizontal: 13),
                  minimumSize: const Size(0, 52),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(13),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton(
                onPressed: hasCriteria
                    ? () => _openSortOptions(request, sortOptions)
                    : null,
                style: OutlinedButton.styleFrom(
                  backgroundColor: SitewiseColors.surface,
                  foregroundColor: SitewiseColors.ink,
                  side: const BorderSide(color: SitewiseColors.borderStrong),
                  minimumSize: const Size.fromHeight(52),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(13),
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.sort_rounded, color: SitewiseColors.action, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Sort by',
                            style: TextStyle(fontSize: 11, color: SitewiseColors.muted),
                          ),
                          Text(
                            _compactSortLabel(currentSort, sortOptions),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: SitewiseColors.ink,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 4),
                    const Icon(
                      Icons.keyboard_arrow_down_rounded,
                      color: SitewiseColors.muted,
                      size: 19,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 15),
        if (hasCriteria)
          Text(
          total == null
              ? 'Finding matching properties…'
              : '$total ${total == 1 ? 'property matches' : 'properties match'}',
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w800,
            color: SitewiseColors.ink,
          ),
        ),
        const SizedBox(height: 4),
        if (hasCriteria || ref.read(appNotifierProvider).compared.isNotEmpty)
          Builder(
          builder: (context) {
            final compareCount = ref.read(appNotifierProvider).compared.length;
            return Row(
              children: [
                Expanded(
                  child: Text(
                    '$compareCount of ${AppState.maxCompare} in comparison',
                    style: const TextStyle(
                      fontSize: 13,
                      color: SitewiseColors.muted,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: compareCount >= 2
                      ? () => Navigator.of(context)
                          .pushNamed('/entrepreneur/compare')
                      : null,
                  child: const Text(
                    'View comparison',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                    ),
                  ),
                ),
              ],
            );
          },
        ),
        if (chips.isNotEmpty) ...[
          const SizedBox(height: 5),
          SizedBox(
            height: 38,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final chip in chips)
                  Padding(
                    padding: const EdgeInsets.only(right: 7),
                    child: InputChip(
                      label: Text(
                        chip.label,
                        style: const TextStyle(fontSize: 12),
                      ),
                      onDeleted: () => _applySearch(
                        chip.next,
                      ),
                      deleteIcon: const Icon(Icons.close_rounded, size: 16),
                      deleteButtonTooltipMessage: 'Remove ${chip.label} filter',
                    ),
                  ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 14),
      ],
    );
  }

  /// One switch on the Recommendations page, never a permanent GPS tracker.
  Widget _nearbyToggle(RecommendationSearchRequest request) {
    final active = request.locationLatitude != null &&
        request.locationLongitude != null;
    return Container(
      decoration: BoxDecoration(
        color: active ? SitewiseColors.infoWash : SitewiseColors.surface,
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: active
            ? SitewiseColors.action.withValues(alpha: 0.35)
            : SitewiseColors.border),
      ),
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: SitewiseColors.action.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(13),
            ),
            child: const Icon(Icons.near_me_outlined,
                color: SitewiseColors.action),
          ),
          const SizedBox(width: 12),
          Expanded(child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Nearby recommendations',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700,
                      color: SitewiseColors.ink)),
              const SizedBox(height: 4),
              Text(
                active
                    ? 'Showing eligible properties within 5 km of your location.'
                    : 'Use my current location to find properties within 5 km.',
                style: const TextStyle(fontSize: 12.5, height: 1.35,
                    color: SitewiseColors.muted),
              ),
            ],
          )),
          const SizedBox(width: 6),
          if (_nearbyBusy)
            const SizedBox(width: 48, height: 48,
                child: Center(child: SizedBox(width: 20, height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))))
          else
            Switch.adaptive(
              value: active,
              onChanged: _changeNearby,
            ),
        ],
      ),
    );
  }

  Future<void> _changeNearby(bool enabled) async {
    if (_nearbyBusy) return;
    if (!enabled) {
      final current = ref.read(entrepreneurNotifierProvider).recommendationRequest;
      _applySearch(current.copyWith(
        clearNearby: true,
        clearCursor: true,
      ));
      return;
    }
    setState(() => _nearbyBusy = true);
    try {
      final point = await ref.read(nearbyLocationProvider).currentPosition();
      if (!mounted || ref.read(authNotifierProvider).user?.id != _sessionUserId) return;
      _filterDraft = null;
      // Keep filters changed while the location request was in flight.
      final current = ref.read(entrepreneurNotifierProvider).recommendationRequest;
      _applySearch(current.copyWith(
        locationLatitude: point.latitude,
        locationLongitude: point.longitude,
        nearbyRadiusKm: 5,
        clearCursor: true,
      ));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(error is StateError
            ? error.message.toString()
            : 'Could not access your location. You can keep browsing manually.'),
      ));
    } finally {
      if (mounted) setState(() => _nearbyBusy = false);
    }
  }

  // SiteWise sort picker: compact control + accessible bottom sheet.
  // Labels shown here are only shortened in the toolbar; backend keys and
  // server-provided sort options remain unchanged.
  static String _compactSortLabel(String key, Map<String, String> options) =>
      switch (key) {
        'best_match' => 'Best match',
        'rent_asc' => 'Lowest rent',
        'rent_desc' => 'Highest rent',
        'size_desc' => 'Largest area',
        'size_asc' => 'Smallest area',
        'pu_desc' => 'Highest PU index',
        _ => options[key] ?? key,
      };

  Future<void> _openSortOptions(
    RecommendationSearchRequest request,
    Map<String, String> options,
  ) async {
    FocusManager.instance.primaryFocus?.unfocus();
    final selected = request.sort ?? 'best_match';
    // Do not replace the facet vocabulary: it is supplied by the backend.
    final available = Map<String, String>.from(options);
    available.putIfAbsent(
      selected,
      () => _sortFallback[selected] ?? selected,
    );

    final next = await showModalBottomSheet<String>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      backgroundColor: SitewiseColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (sheetContext) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 12),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(sheetContext).height * .72,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: SitewiseColors.borderStrong,
                      borderRadius: BorderRadius.circular(50),
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                const Text(
                  'Sort properties',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    color: SitewiseColors.ink,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Choose how the matching properties are ordered.',
                  style: TextStyle(fontSize: 13, color: SitewiseColors.muted),
                ),
                const SizedBox(height: 14),
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: available.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 6),
                    itemBuilder: (context, index) {
                      final option = available.entries.elementAt(index);
                      final active = option.key == selected;
                      return Semantics(
                        button: true,
                        selected: active,
                        child: Material(
                          color: active
                              ? SitewiseColors.action.withValues(alpha: .08)
                              : SitewiseColors.surface,
                          borderRadius: BorderRadius.circular(12),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(12),
                            onTap: () => Navigator.of(sheetContext).pop(option.key),
                            child: Container(
                              constraints: const BoxConstraints(minHeight: 54),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 13,
                              ),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: active
                                      ? SitewiseColors.action
                                      : SitewiseColors.border,
                                ),
                              ),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      option.value,
                                      style: TextStyle(
                                        fontSize: 15,
                                        fontWeight: active
                                            ? FontWeight.w700
                                            : FontWeight.w500,
                                        color: SitewiseColors.ink,
                                      ),
                                    ),
                                  ),
                                  if (active)
                                    const Icon(
                                      Icons.check_circle_rounded,
                                      color: SitewiseColors.action,
                                      size: 22,
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (!mounted ||
        next == null ||
        next == selected ||
        ref.read(authNotifierProvider).user?.id != _sessionUserId) {
      return;
    }
    final current = ref.read(entrepreneurNotifierProvider).recommendationRequest;
    if (!_hasSearchCriteria(current)) return;
    _applySearch(current.copyWith(sort: next));
  }

  /// Applied filters as individually removable chips, built from the SAME
  /// request the server ranked. Business type is deliberately absent.
  List<({String label, RecommendationSearchRequest next})> _filterChips(
    RecommendationSearchRequest request,
  ) => [
    if (request.preferredState != null)
      (
        label: request.preferredState!,
        next: request.copyWith(clearState: true, clearCity: true, clearArea: true),
      ),
    if (request.city != null)
      (label: request.city!, next: request.copyWith(clearCity: true)),
    if (request.propertyType != null)
      (
        label: request.propertyType!,
        next: request.copyWith(clearPropertyType: true),
      ),
    if (request.minRentalRm != null || request.maxRentalRm != null)
      (
        label: _rentLabel(request.minRentalRm, request.maxRentalRm),
        next: request.copyWith(clearRentRange: true),
      ),
    if (request.minSizeSqft != null || request.maxSizeSqft != null)
      (
        label: _sizeLabel(request.minSizeSqft, request.maxSizeSqft),
        next: request.copyWith(clearSizeRange: true),
      ),
    if (request.layoutPreferences.isNotEmpty)
      (
        label: request.layoutPreferences.join(', '),
        next: request.copyWith(layoutPreferences: const []),
      ),
    if (request.floorLevel != null)
      (
        label: 'Floor: ${request.floorLevel}',
        next: request.copyWith(clearFloorLevel: true),
      ),
    if (request.transitMaxM != null)
      (
        label: 'Transit ≤ ${request.transitMaxM!.round()} m',
        next: request.copyWith(clearTransit: true),
      ),
    if (request.nearbyParkingMin != null)
      (
        label: 'Parking ≥ ${request.nearbyParkingMin!.round()}',
        next: request.copyWith(clearParking: true),
      ),
    if (request.fnbCompetitionMax != null)
      (
        label: 'F&B ≤ ${request.fnbCompetitionMax!.round()}',
        next: request.copyWith(clearCompetition: true),
      ),
    if (request.demandGenerator != null)
      (
        label: 'Near ${_demandLabel(request.demandGenerator!)}',
        next: request.copyWith(clearDemand: true),
      ),
    if (request.populationMin1000m != null ||
        request.populationMax1000m != null)
      (
        label: 'Population ${request.populationMin1000m?.round() ?? 0}+',
        next: request.copyWith(clearPopulation: true),
      ),
    if (request.query != null)
      (label: '“${request.query}”', next: request.copyWith(clearQuery: true)),
  ];

  static const _sortFallback = <String, String>{
    'best_match': 'Best requirement match',
    'rent_asc': 'Lowest monthly rent',
    'rent_desc': 'Highest monthly rent',
    'size_desc': 'Largest floor area',
    'size_asc': 'Smallest floor area',
    'pu_desc': 'Highest PU research index',
  };

  static String _demandLabel(String key) => switch (key) {
    'malls_1000m' => 'malls',
    'offices_500m' => 'offices',
    'universities_500m' => 'universities',
    _ => key,
  };

  static String _rentLabel(double? min, double? max) {
    if (min != null && max != null) {
      return '${_ringgitPerMonth(min)} – ${_ringgitPerMonth(max)}';
    }
    if (min != null) return 'From ${_ringgitPerMonth(min)}';
    return 'Up to ${_ringgitPerMonth(max!)}';
  }

  static String _sizeLabel(double? min, double? max) {
    if (min != null && max != null) {
      return '${min.round()}–${max.round()} sq ft';
    }
    if (min != null) return 'From ${min.round()} sq ft';
    return 'Up to ${max!.round()} sq ft';
  }

  // -- footer states --------------------------------------------------------

  Widget _footer(EntrepreneurState state, EntrepreneurNotifier notifier) {
    if (!_hasSearchCriteria(state.recommendationRequest)) {
      return M3EmptyState(
        icon: Icons.tune_rounded,
        title: 'Find your next business location',
        message: 'Choose a filter, search for a property, or enable Nearby recommendations to see matching results.',
        actionLabel: 'Set filters',
        onAction: _openFilters,
      );
    }
    if (state.recommendationLoading) {
      return const Padding(
        padding: EdgeInsets.only(top: 40),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2.4)),
      );
    }
    if (state.recommendationError != null) {
      return _ErrorBlock(
        message: state.recommendationError!,
        onRetry: _refreshSearch,
      );
    }
    if (state.ranked.isEmpty) {
      return M3EmptyState(
        icon: Icons.search_off_rounded,
        title: state.recommendationRequest.locationLatitude != null
            ? 'No eligible properties nearby'
            : state.recommendationRequest.isBrowseOnly
                ? 'No properties available'
                : 'Nothing matches these requirements',
        message: state.recommendationRequest.locationLatitude != null
            ? 'No eligible properties within 5 km match your current filters. '
                  'Turn off Nearby recommendations and use other filters to search more widely.'
            : state.recommendationRequest.isBrowseOnly
                ? 'The catalogue returned no listings. This is a data condition, '
                    'not a filter problem.'
                : 'Widen the budget or reduce the minimum floor area, then search '
                    'again.',
        actionLabel: state.recommendationRequest.locationLatitude != null
            ? 'Turn off nearby' : 'Clear filters',
        onAction: () => _applySearch(
          state.recommendationRequest.locationLatitude != null
              ? state.recommendationRequest.copyWith(clearNearby: true, clearCursor: true)
              : const RecommendationSearchRequest(),
        ),
      );
    }
    return Column(
      children: [
        const SizedBox(height: 8),
        if (state.recommendationHasMore)
          TextButton(
            onPressed: state.recommendationRefreshing
                ? null
                : () => notifier.loadMoreRecommendations(),
            child: Text(
              state.recommendationRefreshing ? 'Loading…' : 'Load more',
              style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w800,
                color: SitewiseColors.action,
              ),
            ),
          )
        else
          const Text(
            'End of results',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: SitewiseColors.muted,
            ),
          ),
        const SizedBox(height: 6),
        const Text(
          'Requirement fit is not a probability of business success. The PU '
          'research score is a separate model and is shown separately.',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 12.5,
            height: 1.5,
            color: SitewiseColors.muted,
          ),
        ),
      ],
    );
  }

  // -- actions --------------------------------------------------------------

  /// Compare is capped at three; a fourth tap is explained instead of being
  /// silently ignored, and Favourites remain a separate store.
  void _toggleCompared(String id) {
    final notifier = ref.read(appNotifierProvider.notifier);
    final already = ref.read(appNotifierProvider).compared.contains(id);
    final bool accepted;
    if (already) {
      notifier.toggleCompared(id);
      accepted = true;
    } else {
      accepted = notifier.addCompared(id);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          accepted
              ? (already ? 'Removed from comparison.' : 'Added to comparison.')
              : 'You can compare up to three properties. Remove one first.',
        ),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _toggleSaved(String id) async {
    final messenger = ScaffoldMessenger.of(context);
    final wantSaved = !ref.read(appNotifierProvider).saved.contains(id);
    // Server first: the Favourites tab reads the account's saved list, so a
    // purely local toggle would look saved here and be missing there.
    final failure = await ref
        .read(appNotifierProvider.notifier)
        .persistSaved(id, wantSaved: wantSaved);
    if (!mounted) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          failure ??
              (wantSaved ? 'Added to favourites.' : 'Removed from favourites.'),
        ),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _openInsight(RankedProperty item) {
    ref.read(entrepreneurNotifierProvider.notifier).selectRanked(item.id);
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: SitewiseColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (_) => _InsightSheet(item: item),
    );
  }

  Future<void> _openFilters() async {
    final applied = ref.read(entrepreneurNotifierProvider).recommendationRequest;
    final base = _requestKey(applied);
    if (_filterDraftBase != base) _filterDraft = null;
    _filterDraftBase = base;
    final request = await showModalBottomSheet<RecommendationSearchRequest>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: SitewiseColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (_) => _FilterSheet(
        initial: _filterDraft ?? applied,
        onDraftChanged: (draft) => _filterDraft = draft,
      ),
    );
    if (!mounted || ref.read(authNotifierProvider).user?.id != _sessionUserId) return;
    if (request == null) return;
    _filterDraft = null;
    _filterDraftBase = null;
    if (_requestKey(ref.read(entrepreneurNotifierProvider).recommendationRequest) != base) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Search criteria changed. Open Filters again to apply your choices.'),
      ));
      return;
    }
    _applySearch(request);
  }
}

/// Server failure with a real retry action, never an empty success state.
class _ErrorBlock extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ErrorBlock({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 28),
    child: Column(
      children: [
        Icon(Icons.cloud_off_rounded, size: 30, color: SitewiseColors.muted),
        const SizedBox(height: 8),
        const Text(
          'Could not load recommendations',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w800,
            color: SitewiseColors.ink,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          message,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 11.5,
            height: 1.45,
            color: SitewiseColors.muted,
          ),
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: onRetry,
          icon: const Icon(Icons.refresh_rounded, size: 17),
          label: const Text('Retry'),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(140, 44),
            foregroundColor: SitewiseColors.action,
            side: const BorderSide(color: SitewiseColors.borderStrong),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            textStyle: const TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      ],
    ),
  );
}

/// One ranked result: full-width 16:9 media (swipeable photo gallery with
/// rank, bookmark, counter and a 360° action only when the backend verified
/// a ready panorama), clearly separated rent/area metrics, the requirement
/// verdict in plain wording, and the three aligned actions. Tapping the
/// card body opens the insight sheet.
class RecommendationCard extends StatelessWidget {
  final RankedProperty item;
  final bool isSaved;
  final bool isCompared;
  final bool isSelected;
  final VoidCallback onOpen;
  final VoidCallback onSave;
  final VoidCallback onCompare;

  const RecommendationCard({
    super.key,
    required this.item,
    required this.isSaved,
    required this.isCompared,
    required this.isSelected,
    required this.onOpen,
    required this.onSave,
    required this.onCompare,
  });

  void _openPanorama(BuildContext context) {
    final url = item.panoramaUrl;
    if (url == null) return;
    Navigator.of(context).pushNamed(
      '/entrepreneur/panorama',
      arguments: {'url': url, 'title': item.property.title},
    );
  }

  @override
  Widget build(BuildContext context) {
    final prop = item.property;
    final match = item.match;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: SitewiseColors.surface,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          onTap: onOpen,
          borderRadius: BorderRadius.circular(18),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: isSelected
                    ? SitewiseColors.action
                    : SitewiseColors.border,
                width: isSelected ? 1.6 : 1,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                MobilePropertyGallery(
                  property: prop,
                  urls: prop.imageUrls,
                  aspectRatio: 2.05, // Compact media; tap to view full image.
                  rankBadge: _RankBadge(rank: match.rank),
                  bookmarkButton: _IconToggle(
                    icon: isSaved ? Icons.bookmark : Icons.bookmark_border,
                    active: isSaved,
                    label: isSaved ? 'Remove from favourites' : 'Save property',
                    onTap: onSave,
                  ),
                  // Only a backend-verified ready panorama earns this action.
                  // An ordinary wide photo is never presented as 360°.
                  tourAction: item.hasPanorama
                      ? _PanoramaAction(
                          onTap: () => _openPanorama(context),
                          label: prop.title,
                        )
                      : null,
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 11, 14, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        prop.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                          height: 1.3,
                          color: SitewiseColors.ink,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        [
                          if (prop.city.isNotEmpty) prop.city,
                          if (prop.state.isNotEmpty) prop.state,
                          if (prop.propertyType.isNotEmpty) prop.propertyType,
                        ].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14,
                          height: 1.35,
                          fontWeight: FontWeight.w500,
                          color: SitewiseColors.text,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: _Metric(
                              label: 'Monthly rent',
                              value: _ringgitPerMonth(prop.rentalRm),
                            ),
                          ),
                          Container(
                            width: 1,
                            height: 42,
                            color: SitewiseColors.border,
                          ),
                          Expanded(
                            child: _Metric(
                              label: 'Floor area',
                              value: _squareFeet(prop.sizeSqft),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      _RequirementVerdict(match: match),
                      if (match.matched.isNotEmpty ||
                          match.unmatched.isNotEmpty) ...[
                        const SizedBox(height: 9),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            for (final reason in match.matched.take(2))
                              _ReasonChip(label: reason.label, met: true),
                            for (final reason in match.unmatched.take(1))
                              _ReasonChip(label: reason.label, met: false),
                          ],
                        ),
                      ],
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            flex: 5,
                            child: _CardActionButton(
                              label: 'Details',
                              icon: Icons.arrow_forward_rounded,
                              primary: true,
                              onTap: () => Navigator.of(context).pushNamed(
                                '/entrepreneur/property-detail',
                                arguments: prop.id,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            flex: 3,
                            child: _CardActionButton(
                              label: 'Insights',
                              icon: Icons.insights_rounded,
                              onTap: onOpen,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            flex: 3,
                            child: _CardActionButton(
                              label: isCompared ? 'In compare' : 'Compare',
                              icon: isCompared
                                  ? Icons.check_circle_outline
                                  : Icons.compare_arrows_rounded,
                              onTap: onCompare,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Emphasised value over its label — rent and floor area read as two
/// clearly separated metrics, never squeezed into one grey line.
class _Metric extends StatelessWidget {
  final String label;
  final String value;

  const _Metric({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: SitewiseColors.muted,
              height: 1.25,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            value,
            style: const TextStyle(
              fontSize: 15.5,
              fontWeight: FontWeight.w800,
              color: SitewiseColors.ink,
              height: 1.25,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

/// The recommendation result in understandable wording. Colour never carries
/// the meaning alone — every state pairs a distinct icon with a full
/// sentence, and "nothing to verify" says exactly what is missing instead
/// of showing a bare `no criteria` pill.
class _RequirementVerdict extends StatelessWidget {
  final RecommendationMatch match;

  const _RequirementVerdict({required this.match});

  @override
  Widget build(BuildContext context) {
    final verifiable = match.verifiableCount > 0;
    final (icon, color) = verifiable
        ? (Icons.verified_rounded, SitewiseColors.success)
        : (Icons.info_outline_rounded, SitewiseColors.muted);
    return Semantics(
      label: verifiable
          ? 'Meets ${match.matchedCount} of ${match.verifiableCount} '
                'of your requirements'
          : 'Requirement fit is not available yet',
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(icon, size: 18, color: color),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              verifiable
                  ? 'Meets ${match.matchedCount} of ${match.verifiableCount} '
                        'of your requirements.'
                  : 'Fit not verified — set requirements in Filters.',
              style: TextStyle(
                fontSize: 14,
                height: 1.35,
                fontWeight: verifiable ? FontWeight.w700 : FontWeight.w500,
                color: verifiable ? SitewiseColors.ink : SitewiseColors.text,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// `360° View` pill over the media. Rendered ONLY when the backend reported
/// a ready, verified panorama for this property.
class _PanoramaAction extends StatelessWidget {
  final VoidCallback onTap;
  final String label;

  const _PanoramaAction({required this.onTap, required this.label});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Open 360° panorama view of $label',
      child: Material(
        color: SitewiseColors.ink.withValues(alpha: 0.82),
        borderRadius: BorderRadius.circular(999),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(999),
          child: const SizedBox(
            height: 44,
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 14),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.threesixty_rounded, size: 19, color: Colors.white),
                  SizedBox(width: 6),
                  Text(
                    '360° View',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      height: 1.1,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One aligned card action, at least 44dp tall. Labels scale down instead
/// of clipping when the system text size grows.
class _CardActionButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool primary;
  final VoidCallback onTap;

  const _CardActionButton({
    required this.label,
    required this.icon,
    required this.onTap,
    this.primary = false,
  });

  @override
  Widget build(BuildContext context) {
    // Primary must be WHITE on blue (previously blue on blue).
    final color = primary ? Colors.white : SitewiseColors.ink;
    return SizedBox(
      height: 48,
      child: FilledButton.icon(
        style: FilledButton.styleFrom(
          backgroundColor: primary
              ? SitewiseColors.action
              : SitewiseColors.surface,
          foregroundColor: color,
          side: primary
              ? null
              : const BorderSide(color: SitewiseColors.borderStrong),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          visualDensity: VisualDensity.standard,
        ),
        onPressed: onTap,
        icon: Icon(icon, size: 17),
        label: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: color,
          ),
        ),
      ),
    );
  }
}

/// `RM 7,500/mo` — thousands grouped, no dangling decimals.
String _ringgitPerMonth(double amount) {
  final rounded = amount.round();
  final digits = rounded.abs().toString();
  final grouped = StringBuffer(rounded < 0 ? '-RM ' : 'RM ');
  for (var i = 0; i < digits.length; i++) {
    grouped.write(digits[i]);
    final remaining = digits.length - i - 1;
    if (remaining > 0 && remaining % 3 == 0) grouped.write(',');
  }
  grouped.write('/mo');
  return grouped.toString();
}

/// `1,760 sq ft` with the same grouping.
String _squareFeet(double size) {
  final rounded = size.round();
  final digits = rounded.abs().toString();
  final grouped = StringBuffer(rounded < 0 ? '-' : '');
  for (var i = 0; i < digits.length; i++) {
    grouped.write(digits[i]);
    final remaining = digits.length - i - 1;
    if (remaining > 0 && remaining % 3 == 0) grouped.write(',');
  }
  grouped.write(' sq ft');
  return grouped.toString();
}

/// Full intelligence for one listing: requirement-by-requirement verdict,
/// listing facts, then the PU model kept visibly separate.
class _InsightSheet extends StatelessWidget {
  final RankedProperty item;

  const _InsightSheet({required this.item});

  @override
  Widget build(BuildContext context) {
    final prop = item.property;
    final match = item.match;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: .82,
      maxChildSize: .95,
      minChildSize: .5,
      builder: (context, controller) => ListView(
        // Stable key: the sheet is lazily built, so tests (and any future
        // scroll-to-section affordance) need a deterministic handle on it.
        key: const ValueKey('insight-sheet-scroll'),
        controller: controller,
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 26),
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: SitewiseColors.borderStrong,
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Text(
            prop.title,
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w800,
              height: 1.3,
              color: SitewiseColors.ink,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            [
              prop.address,
              prop.city,
              prop.state,
            ].where((v) => v.isNotEmpty).join(', '),
            style: const TextStyle(
              fontSize: 12,
              height: 1.45,
              color: SitewiseColors.muted,
            ),
          ),
          const SizedBox(height: 12),
          MobilePropertyImage(
            property: prop,
            height: 170,
            borderRadius: BorderRadius.circular(14),
          ),
          const SizedBox(height: 16),
          _SectionLabel(
            match.available ? 'Recommendation match' : 'Requirement fit',
          ),
          if (match.fitSummary != null)
            Text(
              match.fitSummary!,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w800,
                color: SitewiseColors.ink,
              ),
            ),
          if (!match.available && match.reason != null) ...[
            const SizedBox(height: 4),
            Text(
              match.reason!,
              style: const TextStyle(
                fontSize: 11,
                height: 1.5,
                color: SitewiseColors.muted,
              ),
            ),
          ],
          const SizedBox(height: 8),
          if (match.matched.isNotEmpty)
            _RequirementGroup(
              title: 'Met',
              items: match.matched,
              color: SitewiseColors.success,
            ),
          if (match.unmatched.isNotEmpty)
            _RequirementGroup(
              title: 'Not met',
              items: match.unmatched,
              color: SitewiseColors.danger,
            ),
          if (match.unverified.isNotEmpty)
            _RequirementGroup(
              title: 'Cannot be verified from the catalogue',
              items: match.unverified,
              color: SitewiseColors.muted,
            ),
          if (match.matched.isEmpty &&
              match.unmatched.isEmpty &&
              match.unverified.isEmpty)
            const Text(
              'No requirements were applied — this is a plain catalogue '
              'browse. Set your requirements to rank by fit.',
              style: TextStyle(
                fontSize: 12,
                height: 1.5,
                color: SitewiseColors.muted,
              ),
            ),
          const SizedBox(height: 16),
          const _SectionLabel('Listing facts'),
          _SheetRow('Monthly rental', 'RM ${prop.rentalRm.toStringAsFixed(0)}'),
          _SheetRow('Floor area', '${prop.sizeSqft.toStringAsFixed(0)} sq ft'),
          _SheetRow('Property type', prop.propertyType),
          _SheetRow(
            'Research index',
            item.suitabilityAvailable
                ? '${item.catalogSuitabilityScore!.toStringAsFixed(1)} / 100'
                : 'Not available',
          ),
          const SizedBox(height: 16),
          // Separate model, separate block, never merged into the fit figure.
          const _SectionLabel('PU research association'),
          Text(
            item.puAvailable == true
                ? 'PU association: ${item.puScore?.toStringAsFixed(1) ?? '—'} '
                      '(research index, not a success probability).'
                : 'The PU research model returned no association score for this '
                      'property. It is a separate research model and is never '
                      'folded into the requirement-fit result above.',
            style: const TextStyle(
              fontSize: 11.5,
              height: 1.5,
              color: SitewiseColors.muted,
            ),
          ),
          const SizedBox(height: 18),
          M3PrimaryButton(
            label: 'View property',
            onTap: () {
              Navigator.of(context).pop();
              Navigator.of(
                context,
              ).pushNamed('/entrepreneur/property-detail', arguments: prop.id);
            },
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () {
              Navigator.of(context).pop();
              Navigator.of(
                context,
              ).pushNamed('/entrepreneur/assessment-setup', arguments: prop.id);
            },
            icon: const Icon(Icons.assignment_outlined, size: 18),
            label: const Text('Assess this property'),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
              foregroundColor: SitewiseColors.action,
              side: const BorderSide(color: SitewiseColors.borderStrong),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              textStyle: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Requirement search form. Returns the request to run, or null on dismiss.
class _FilterSheet extends ConsumerStatefulWidget {
  final RecommendationSearchRequest initial;

  /// Lets the page keep an uncommitted draft if the sheet is dismissed. It is
  /// a callback rather than a controller, so the sheet remains state-owned.
  final ValueChanged<RecommendationSearchRequest>? onDraftChanged;

  const _FilterSheet({required this.initial, this.onDraftChanged});

  @override
  ConsumerState<_FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends ConsumerState<_FilterSheet> {
  late RecommendationSearchRequest _draft = widget.initial;
  RecommendationFacets? _facets;
  bool _loading = false;
  String? _facetError;
  bool _more = false;
  int _seq = 0;

  /// The same vocabulary the web Recommendations form exposes. It is a UI
  /// vocabulary, not a substitute for backend options; the backend may add
  /// more advanced filters and those still render from `facets.advanced`.
  static const _targetMarketOptions = <String>[
    'Students',
    'Office Workers',
    'Residents',
    'General Public',
  ];

  @override
  void initState() {
    super.initState();
    _loading = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _refresh();
    });
  }

  /// Dependent options are read from the SAME contextual facet endpoint used
  /// by web (`GET /api/v1/recommendations/facets`). A stale response can never
  /// overwrite a newer choice, and a failure is stated instead of silently
  /// keeping an unrelated option list.
  Future<void> _refresh() async {
    final seq = ++_seq;
    setState(() {
      _loading = true;
      _facetError = null;
    });
    try {
      final facets = await ref
          .read(entrepreneurNotifierProvider.notifier)
          .fetchRecommendationFacets(_draft);
      if (!mounted || seq != _seq) return;
      if (facets == null) {
        setState(() => _facetError = 'Filter choices are unavailable in this build.');
      } else {
        setState(() => _facets = facets);
      }
    } on Object {
      if (!mounted || seq != _seq) return;
      setState(() {
        _facetError = 'Filter choices could not be updated.';
      });
    } finally {
      if (mounted && seq == _seq) setState(() => _loading = false);
    }
  }

  void _update(RecommendationSearchRequest next) {
    widget.onDraftChanged?.call(next);
    setState(() => _draft = next);
    _refresh();
  }

  static String _key(double? min, double? max) =>
      (min == null && max == null) ? '' : '${min ?? ''}|${max ?? ''}';

  static ({double? min, double? max}) _normalisedRange(
    double? min,
    double? max,
  ) {
    if (min != null && max != null && min > max) {
      return (min: max, max: min);
    }
    return (min: min, max: max);
  }

  static String _money(double value) {
    final digits = value.toStringAsFixed(0);
    final grouped = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) grouped.write(',');
      grouped.write(digits[i]);
    }
    return 'RM $grouped';
  }

  /// Fallback only when the backend has not supplied a label (for example a
  /// saved custom interval). Generated options always use the backend label,
  /// so mobile and web cannot drift.
  static String _rangeLabel(double? min, double? max, {required bool money}) {
    final bounds = _normalisedRange(min, max);
    min = bounds.min;
    max = bounds.max;
    if (min != null && max != null && min == max) {
      return money ? _money(min) : '${max.round()} sq ft';
    }
    if (money) {
      if (min != null && max != null) {
        return '${_money(min)} – ${_money(max)}';
      }
      if (min != null) return 'From ${_money(min)}';
      if (max != null) return 'Up to ${_money(max)}';
      return 'Any monthly rental';
    }
    if (min != null && max != null) {
      return '${min.round()} – ${max.round()} sq ft';
    }
    if (min != null) return 'From ${min.round()} sq ft';
    if (max != null) return 'Up to ${max.round()} sq ft';
    return 'Any size';
  }

  /// Dropdown labels are names or ranges only. Counts remain in the contextual
  /// facet summary and `Show properties`, matching the web Recommendations UI.
  List<DropdownMenuItem<String>> _items(
    String value,
    List<(String, String)> options,
    String emptyLabel, {
    String? selectedLabel,
  }) => [
    DropdownMenuItem(
      value: '',
      child: Text(emptyLabel, maxLines: 1, overflow: TextOverflow.ellipsis),
    ),
    if (value.isNotEmpty && !options.any((pair) => pair.$1 == value))
      DropdownMenuItem(
        value: value,
        child: Text(
          selectedLabel ?? value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    for (final entry in <String, String>{
      for (final pair in options)
        if (pair.$1.isNotEmpty) pair.$1: pair.$2,
    }.entries)
      DropdownMenuItem(
        value: entry.key,
        child: Text(entry.value, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
  ];

  List<(String, String)> _values(List<FacetOption> options) => [
    for (final option in options)
      (option.value, option.label.isEmpty ? option.value : option.label),
  ];

  List<(String, String)> _ranges(List<FacetRangeOption> options) => [
    for (final option in options) (option.key, option.label),
  ];

  Widget _field(
    String label,
    String value,
    List<(String, String)> options,
    void Function(String) changed, {
    String emptyLabel = 'Any',
    String? selectedLabel,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: DropdownButtonFormField<String>(
      key: ValueKey('$label|$value'),
      initialValue: value,
      isDense: true,
      isExpanded: true,
      menuMaxHeight: 320,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(14)),
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14, vertical: 16,
        ),
      ),
      items: _items(value, _facetError == null ? options : const [],
          emptyLabel, selectedLabel: selectedLabel),
      onChanged: _loading ? null : (next) => changed(next ?? ''),
    ),
  );

  /// Rental and size use the same `"min|max"` key as web, but the displayed
  /// text is the backend label. A saved interval that the current draft no
  /// longer generates stays selected; the note explains that instead of
  /// silently dropping or replacing the choice.
  Widget _rangeField({
    required String label,
    required double? min,
    required double? max,
    required List<FacetRangeOption> options,
    required FacetRangeOption? selected,
    required bool money,
    required String emptyLabel,
    required void Function(String) onChanged,
  }) {
    final bounds = _normalisedRange(min, max);
    final value = _key(bounds.min, bounds.max);
    final hasSelection = value.isNotEmpty;
    final generated =
        selected?.generated ?? options.any((option) => option.key == value);
    final isCustom = !_loading && _facetError == null &&
        _facets != null && hasSelection && !generated;
    final selectedLabel =
        selected?.label ?? _rangeLabel(bounds.min, bounds.max, money: money);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _field(
          label,
          value,
          _ranges(options),
          onChanged,
          emptyLabel: emptyLabel,
          selectedLabel: isCustom ? selectedLabel : null,
        ),
        if (isCustom)
          _rangeNote(
            unavailable: _facets != null && _facets!.matchingTotal == 0,
            text: _facets != null && _facets!.matchingTotal == 0
                ? 'This selected range currently matches no eligible '
                      'properties. It stays applied until changed.'
                : 'This saved range is not one of the current intervals. It '
                      'stays applied until changed.',
            onClear: () => onChanged(''),
          ),
      ],
    );
  }

  Widget _rangeNote({
    required bool unavailable,
    required String text,
    required VoidCallback onClear,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Container(
      padding: const EdgeInsets.fromLTRB(10, 7, 4, 7),
      decoration: BoxDecoration(
        color: unavailable ? SitewiseColors.warningWash : null,
        border: Border.all(color: SitewiseColors.border),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Text(
              text,
              style: const TextStyle(fontSize: 11.5, height: 1.3),
            ),
          ),
          TextButton(
            onPressed: onClear,
            child: const Text(
              'Clear range',
              style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800),
            ),
          ),
        ],
      ),
    ),
  );

  Widget _advancedField(String key) {
    final facet = _facets?.advanced[key];
    if (facet == null) return const SizedBox.shrink();
    final request = _draft;
    final value = switch (key) {
      'floor_level' => request.floorLevel ?? '',
      'transit_walk_m' => _key(null, request.transitMaxM),
      'nearby_parking_500m' => _key(request.nearbyParkingMin, null),
      'fnb_competition_500m' => _key(null, request.fnbCompetitionMax),
      'demand_generator' => request.demandGenerator ?? '',
      'surrounding_population_1000m' => _key(
        request.populationMin1000m,
        request.populationMax1000m,
      ),
      _ => '',
    };
    final options = switch (key) {
      'transit_walk_m' => <(String, String)>[
        for (final option in facet.rangeOptions)
          (_key(null, option.max), 'Up to ${option.max.round()} m'),
      ],
      'nearby_parking_500m' => <(String, String)>[
        for (final option in facet.rangeOptions)
          (_key(option.min, null), 'At least ${option.min.round()} facilities'),
      ],
      'fnb_competition_500m' => <(String, String)>[
        for (final option in facet.rangeOptions)
          (_key(null, option.max), 'Up to ${option.max.round()} outlets'),
      ],
      _ => facet.isRange ? _ranges(facet.rangeOptions) : _values(facet.valueOptions),
    };
    final selectedLabel = switch (key) {
      'transit_walk_m' => request.transitMaxM == null ? null : 'Up to ${request.transitMaxM!.round()} m',
      'nearby_parking_500m' => request.nearbyParkingMin == null ? null : 'At least ${request.nearbyParkingMin!.round()} facilities',
      'fnb_competition_500m' => request.fnbCompetitionMax == null ? null : 'Up to ${request.fnbCompetitionMax!.round()} outlets',
      _ => null,
    };
    return _field(facet.label, value, options, (next) {
      final bounds = FacetRangeOption.boundsFromKey(next);
      _update(switch (key) {
        'floor_level' => request.copyWith(
          floorLevel: next.isEmpty ? null : next,
          clearFloorLevel: next.isEmpty,
        ),
        'transit_walk_m' => request.copyWith(transitMaxM: bounds.max, clearTransit: next.isEmpty),
        'nearby_parking_500m' => request.copyWith(nearbyParkingMin: bounds.min, clearParking: next.isEmpty),
        'fnb_competition_500m' => request.copyWith(
          fnbCompetitionMax: bounds.max,
          clearCompetition: next.isEmpty,
        ),
        'demand_generator' => request.copyWith(
          demandGenerator: next.isEmpty ? null : next,
          clearDemand: next.isEmpty,
        ),
        'surrounding_population_1000m' => request.copyWith(
          populationMin1000m: bounds.min,
          populationMax1000m: bounds.max,
          clearPopulation: next.isEmpty,
        ),
        _ => request,
      });
    }, selectedLabel: selectedLabel);
  }

  /// Target market permits several preferences in the shared data model, so
  /// the field shows the complete selection as compact chips. The helper text
  /// is the compact summary; the chips themselves remain tappable.
  Widget _targetMarketField(RecommendationSearchRequest request) {
    final selected = request.layoutPreferences;
    final ordered = [
      for (final value in _targetMarketOptions)
        if (selected.contains(value)) value,
      for (final value in selected)
        if (!_targetMarketOptions.contains(value)) value,
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: 'Target market',
          border: const OutlineInputBorder(),
          helperText: selected.length > 1
              ? '${selected.length} target markets selected'
              : null,
          helperStyle: const TextStyle(
            fontSize: 11,
            color: SitewiseColors.muted,
          ),
          contentPadding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) => Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final value in ordered)
                FilterChip(
                  selected: true,
                  onSelected: (_) => _removeTargetMarket(value),
                  label: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: constraints.maxWidth),
                    child: Text(
                      value,
                      maxLines: 2,
                      softWrap: true,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              for (final value in _targetMarketOptions)
                if (!selected.contains(value))
                  FilterChip(
                    selected: false,
                    onSelected: (_) => _addTargetMarket(value),
                    label: Text(value),
                  ),
            ],
          ),
        ),
      ),
    );
  }

  void _addTargetMarket(String value) {
    if (_draft.layoutPreferences.contains(value)) return;
    _update(
      _draft.copyWith(layoutPreferences: [..._draft.layoutPreferences, value]),
    );
  }

  void _removeTargetMarket(String value) {
    if (!_draft.layoutPreferences.contains(value)) return;
    _update(
      _draft.copyWith(
        layoutPreferences: _draft.layoutPreferences
            .where((item) => item != value)
            .toList(),
      ),
    );
  }

  /// Maps a backend relaxation key to the same clear action web uses. Only
  /// real hard filters appear in `relaxations`; ranking-only inputs never do.
  RecommendationSearchRequest _clearFacetField(
    RecommendationSearchRequest request,
    String field,
  ) => switch (field) {
    'preferred_state' => request.copyWith(clearState: true, clearCity: true, clearArea: true),
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

  Widget _facetStatus(RecommendationFacets? facets) {
    if (_facetError != null) {
      return _statusCard(
        error: true,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Text(
                '$_facetError Retry to load current choices.',
                style: const TextStyle(fontSize: 11.5, height: 1.3),
              ),
            ),
            TextButton(
              onPressed: _refresh,
              child: const Text(
                'Retry',
                style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800),
              ),
            ),
          ],
        ),
      );
    }
    if (_loading) {
      return _statusPlaceholder('Updating filter choices…');
    }
    if (facets == null) return const SizedBox.shrink();
    if (!_hasSearchCriteria(_draft)) {
      return _statusPlaceholder('Select a filter to see matching properties.');
    }

    final total = facets.matchingTotal;
    if (total == 0) {
      return _statusCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'No properties match all your current filters.',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                height: 1.3,
              ),
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 4,
              runSpacing: 0,
              children: [
                for (final relaxation in facets.relaxations.take(3))
                  TextButton(
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      minimumSize: const Size(0, 34),
                    ),
                    onPressed: () =>
                        _update(_clearFacetField(_draft, relaxation.field)),
                    child: Text(
                      'Remove ${relaxation.label}',
                      style: const TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                TextButton(
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    minimumSize: const Size(0, 34),
                  ),
                  onPressed: () => _update(const RecommendationSearchRequest()),
                  child: const Text(
                    'Clear all filters',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    }
    return _statusPlaceholder(
      '$total ${total == 1 ? 'property matches' : 'properties match'} '
      'all your current filters.',
    );
  }

  Widget _statusCard({bool error = false, required Widget child}) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: error ? SitewiseColors.warningWash : null,
        border: Border.all(color: SitewiseColors.border),
        borderRadius: BorderRadius.circular(10),
      ),
      child: child,
    ),
  );

  Widget _statusPlaceholder(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Text(
      text,
      style: const TextStyle(fontSize: 12, color: SitewiseColors.muted),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final facets = _facets;
    final request = _draft;
    final count = _loading || _facetError != null ? null : facets?.matchingTotal;
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(18, 12, 18, bottomInset + 12),
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: .90,
        maxChildSize: .95,
        minChildSize: .55,
        builder: (context, controller) => Column(
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: SitewiseColors.borderStrong,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
            const SizedBox(height: 12),
            // Filters stay in a scrollable sheet, with a persistent Apply row.
            Row(
              children: [
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Refine results',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                          color: SitewiseColors.ink,
                        ),
                      ),
                      SizedBox(height: 3),
                      Text(
                        'Choose your location, budget and space needs.',
                        style: TextStyle(
                          fontSize: 12.5,
                          color: SitewiseColors.muted,
                        ),
                      ),
                    ],
                  ),
                ),
                TextButton(
                  onPressed: () => _update(const RecommendationSearchRequest()),
                  child: const Text('Reset'),
                ),
              ],
            ),
            if (_loading)
              const LinearProgressIndicator(minHeight: 2),
            const SizedBox(height: 10),
            Expanded(
              child: ListView(
                controller: controller,
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                children: [
                  const _SectionLabel('Location & property'),
                  _field(
                    'State',
                    request.preferredState ?? '',
                    _values(facets?.states ?? const []),
                    (v) => _update(
                      request.copyWith(
                        preferredState: v.isEmpty ? null : v,
                        clearState: v.isEmpty,
                        clearCity: v != (request.preferredState ?? ''),
                        clearArea: v != (request.preferredState ?? ''),
                      ),
                    ),
                    emptyLabel: 'Any state',
                  ),
                  _field(
                    'City / District',
                    request.city ?? '',
                    _values(facets?.cities ?? const []),
                    (v) =>
                        _update(request.copyWith(
                          city: v.isEmpty ? null : v,
                          clearCity: v.isEmpty,
                          clearArea: v != (request.city ?? ''),
                        )),
                    emptyLabel: 'Any city / district',
                  ),
                  _field(
                    'Property type',
                    request.propertyType ?? '',
                    _values(facets?.propertyTypes ?? const []),
                    (v) => _update(
                      request.copyWith(
                        propertyType: v.isEmpty ? null : v,
                        clearPropertyType: v.isEmpty,
                      ),
                    ),
                    emptyLabel: 'Any property type',
                  ),
                  const _SectionLabel('Budget & size'),
                  _rangeField(
                    label: 'Monthly rental (RM)',
                    min: request.minRentalRm,
                    max: request.maxRentalRm,
                    options: facets?.rentalRanges ?? const [],
                    selected: facets?.selectedRental,
                    money: true,
                    emptyLabel: 'Any monthly rental',
                    onChanged: (v) {
                      final bounds = FacetRangeOption.boundsFromKey(v);
                      _update(
                        request.copyWith(
                          minRentalRm: bounds.min,
                          maxRentalRm: bounds.max,
                          clearRentRange: v.isEmpty,
                        ),
                      );
                    },
                  ),
                  _rangeField(
                    label: 'Property size (sq ft)',
                    min: request.minSizeSqft,
                    max: request.maxSizeSqft,
                    options: facets?.sizeRanges ?? const [],
                    selected: facets?.selectedSize,
                    money: false,
                    emptyLabel: 'Any size',
                    onChanged: (v) {
                      final bounds = FacetRangeOption.boundsFromKey(v);
                      _update(
                        request.copyWith(
                          minSizeSqft: bounds.min,
                          maxSizeSqft: bounds.max,
                          clearSizeRange: v.isEmpty,
                        ),
                      );
                    },
                  ),
                  const _SectionLabel('Business preferences'),
                  _targetMarketField(request),
                  const SizedBox(height: 4),
                  OutlinedButton.icon(
                    onPressed: () => setState(() => _more = !_more),
                    icon: Icon(_more ? Icons.expand_less : Icons.expand_more),
                    label: const Text('More filters'),
                  ),
                  if (_more) ...[
                    const SizedBox(height: 10),
                    const _SectionLabel('Property characteristics'),
                    _advancedField('floor_level'),
                    const _SectionLabel('Geospatial characteristics'),
                    for (final key in const [
                      'transit_walk_m',
                      'nearby_parking_500m',
                      'fnb_competition_500m',
                      'demand_generator',
                      'surrounding_population_1000m',
                    ])
                      _advancedField(key),
                  ],
                  _facetStatus(facets),
                ],
              ),
            ),
            const SizedBox(height: 8),
            SafeArea(
              top: false,
              child: Row(
                children: [
                  Expanded(
                    flex: 2,
                    child: SizedBox(
                      height: 52,
                      child: OutlinedButton(
                        onPressed: () =>
                            _update(const RecommendationSearchRequest()),
                        child: const Text('Clear all'),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 3,
                    child: SizedBox(
                      height: 52,
                      child: FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: SitewiseColors.action,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(13),
                          ),
                        ),
                        onPressed: _hasSearchCriteria(_draft) &&
                                (_loading || _facetError != null || count == null)
                            ? null
                            : () => Navigator.of(context).pop(_draft),
                        child: Text(
                          !_hasSearchCriteria(_draft)
                              ? 'Apply filters'
                              : count == null ? 'Show properties' : 'Show $count results',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;

  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(
      text.toUpperCase(),
      style: const TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w800,
        letterSpacing: .7,
        color: SitewiseColors.muted,
      ),
    ),
  );
}

class _RankBadge extends StatelessWidget {
  final int rank;

  const _RankBadge({required this.rank});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: const Color(0xCC0B0F19),
      borderRadius: BorderRadius.circular(7),
    ),
    child: Text(
      '#$rank',
      semanticsLabel: 'Rank $rank',
      style: const TextStyle(
        fontSize: 11.5,
        fontWeight: FontWeight.w800,
        color: Colors.white,
      ),
    ),
  );
}

class _ReasonChip extends StatelessWidget {
  final String label;
  final bool met;

  const _ReasonChip({required this.label, required this.met});

  @override
  Widget build(BuildContext context) {
    final color = met ? SitewiseColors.success : SitewiseColors.danger;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: met ? SitewiseColors.successWash : SitewiseColors.dangerWash,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: .35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            met ? Icons.check_rounded : Icons.close_rounded,
            size: 12,
            color: color,
          ),
          const SizedBox(width: 3),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 190),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _IconToggle extends StatelessWidget {
  final IconData icon;
  final bool active;
  final String label;
  final VoidCallback onTap;

  const _IconToggle({
    required this.icon,
    required this.active,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    child: Material(
      color: const Color(0xCCFFFFFF),
      shape: const CircleBorder(),
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        // 44x44: the accessibility floor for a touch target.
        child: SizedBox(
          width: 44,
          height: 44,
          child: Icon(
            icon,
            size: 19,
            color: active ? SitewiseColors.action : SitewiseColors.ink,
          ),
        ),
      ),
    ),
  );
}

class _RequirementGroup extends StatelessWidget {
  final String title;
  final List<RequirementMatch> items;
  final Color color;

  const _RequirementGroup({
    required this.title,
    required this.items,
    required this.color,
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w800,
            letterSpacing: .4,
            color: color,
          ),
        ),
        const SizedBox(height: 3),
        for (final item in items)
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  item.isMet
                      ? Icons.check_rounded
                      : item.isUnmet
                      ? Icons.close_rounded
                      : Icons.help_outline_rounded,
                  size: 13,
                  color: color,
                ),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    item.label,
                    style: const TextStyle(
                      fontSize: 11.5,
                      height: 1.4,
                      color: SitewiseColors.ink,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    ),
  );
}

class _SheetRow extends StatelessWidget {
  final String label;
  final String value;

  const _SheetRow(this.label, this.value);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: const TextStyle(fontSize: 11.5, color: SitewiseColors.muted),
          ),
        ),
        Text(
          value.isEmpty ? 'Not recorded' : value,
          style: const TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w800,
            color: SitewiseColors.ink,
          ),
        ),
      ],
    ),
  );
}
