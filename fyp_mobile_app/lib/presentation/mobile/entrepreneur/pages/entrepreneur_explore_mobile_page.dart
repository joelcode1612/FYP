import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';
import 'package:flutter/material.dart';

import '../../../../application/services/service_locator.dart';
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
/// Search runs through the shared [EntrepreneurNotifier] (repository-backed);
/// the Option A quick chips (All spaces / Under RM 8.5k / Ground floor) and
/// the original filter bottom sheet only narrow the already-loaded list using
/// fields that exist on [CommercialProperty] — budget caps on `rentalRm`,
/// ground floor on the listing's `requirements`. Map pins open a bottom sheet
/// instead of the web split-screen layout.

class EntrepreneurExploreMobilePage extends ConsumerStatefulWidget {
  /// Open directly in map mode (Home → "Explore on map").
  final bool startInMap;

  const EntrepreneurExploreMobilePage({super.key, this.startInMap = false});

  @override
  ConsumerState<EntrepreneurExploreMobilePage> createState() =>
      _EntrepreneurExploreMobilePageState();
}

/// Option A quick filters — mapped onto real listing fields, never invented
/// backend query behaviour.
enum _QuickFilter { all, budget, ground }

class _EntrepreneurExploreMobilePageState
    extends ConsumerState<EntrepreneurExploreMobilePage> {
  late bool showMap = widget.startInMap;
  MobilePropertyFilter filter = MobilePropertyFilter.empty;
  _QuickFilter quick = _QuickFilter.all;

  /// Unfiltered listings, used only to derive the category/area options so the
  /// chips always reflect the real data set.
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
    _loadOptions();
  }

  Future<void> _loadOptions() async {
    try {
      final all = await ServiceLocator.properties.listings();
      if (!mounted) return;
      setState(() => _all = all);
    } catch (_) {
      // Options degrade to "All" only; the results list surfaces its own error.
    }
  }

  List<String> get _types {
    final set = _all.map((p) => p.propertyType).toSet().toList()..sort();
    return set;
  }

  List<String> get _cities {
    final set = _all.map((p) => p.city).toSet().toList()..sort();
    return set;
  }

  List<CommercialProperty> get _results => ref
      .read(entrepreneurNotifierProvider)
      .explore
      .where(filter.matches)
      .where(_quickMatches)
      .toList();

  bool _quickMatches(CommercialProperty p) => switch (quick) {
    _QuickFilter.all => true,
    _QuickFilter.budget => p.rentalRm <= 8500,
    _QuickFilter.ground => p.requirements.contains('Ground Floor'),
  };

  Future<void> _openFilter() async {
    final applied = await showMobilePropertyFilterSheet(
      context,
      current: filter,
      propertyTypes: _types,
      cities: _cities,
    );
    if (applied != null && mounted) setState(() => filter = applied);
  }

  void _clearFilters() {
    setState(() {
      filter = MobilePropertyFilter.empty;
      quick = _QuickFilter.all;
    });
    ref.read(entrepreneurNotifierProvider.notifier).setFilter('All');
    ref.read(entrepreneurNotifierProvider.notifier).setQuery('');
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
                        onChanged: (q) => ref
                            .read(entrepreneurNotifierProvider.notifier)
                            .setQuery(q),
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
    if (model.error != null) {
      return SitewiseErrorState(
        title: 'Unable to load properties',
        message: 'Please check your connection and try again.',
        onRetry: () => ref
            .read(entrepreneurNotifierProvider.notifier)
            .loadExplore(),
      );
    }
    if (showMap) return _mapView();

    final results = _results;
    if (results.isEmpty) {
      return SitewiseEmptyState(
        icon: Icons.search_off_rounded,
        title: 'No matching properties',
        message: 'Try another search or clear the filters.',
        actionLabel: 'Clear filters',
        onAction: _clearFilters,
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 122),
      itemCount: results.length + 1,
      separatorBuilder: (context, index) => const SizedBox(height: 12),
      itemBuilder: (context, i) {
        if (i == 0) {
          return _sectionRow(results.length);
        }
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
      },
    );
  }

  /// Option A quick chips: All spaces / Under RM 8.5k / Ground floor, with
  /// visible selected states (aria-pressed equivalent via [Semantics]).
  Widget _quickChips() {
    const entries = [
      (_QuickFilter.all, 'All spaces'),
      (_QuickFilter.budget, 'Under RM 8.5k'),
      (_QuickFilter.ground, 'Ground floor'),
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
                  onTap: () => setState(() => quick = value),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// `section-row` — "Available spaces" + live result count.
  Widget _sectionRow(int count) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const Expanded(
            child: Text(
              'Available spaces',
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
              '$count sample results',
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
                onTap: () => setState(
                  () => filter = filter.copyWith(propertyType: option),
                ),
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
          pins: [
            for (final p in results)
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
            '${p.rentalDisplay} · ${p.sizeSqft.toStringAsFixed(0)} sq ft · '
            'Suitability ${p.suitabilityScore.toStringAsFixed(0)}',
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
