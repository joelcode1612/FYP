import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:shared_logic/shared_logic.dart';
import 'package:flutter/material.dart';

import '../../../../application/services/service_locator.dart';
import '../../../../core/theme/sitewise_theme.dart';
import '../../../shared/widgets/sitewise_bottom_sheet.dart';
import '../../../shared/widgets/sitewise_button.dart';
import '../../../shared/widgets/sitewise_empty_state.dart';
import '../../../shared/widgets/sitewise_error_state.dart';
import '../../../shared/widgets/sitewise_filter_chip.dart';
import '../../../shared/widgets/sitewise_map_panel.dart';
import '../../shell/mobile_app_shell.dart';
import '../../widgets/mobile_filter_sheet.dart';
import '../../widgets/mobile_property_card.dart';
import '../../widgets/mobile_search_field.dart';
import '../../widgets/mobile_skeleton.dart';

/// Mobile explore: search-first browsing of commercial properties.
///
/// Search runs through the existing [EntrepreneurCubit] (repository-backed);
/// the filter bottom sheet only narrows the already-loaded list using fields
/// that exist on [CommercialProperty]. Map pins open a bottom sheet instead of
/// the web split-screen layout.

class EntrepreneurExploreMobilePage extends StatefulWidget {
  final AppCubit appState;

  /// Open directly in map mode (Home → "Explore on map").
  final bool startInMap;

  const EntrepreneurExploreMobilePage({
    super.key,
    required this.appState,
    this.startInMap = false,
  });

  @override
  State<EntrepreneurExploreMobilePage> createState() =>
      _EntrepreneurExploreMobilePageState();
}

class _EntrepreneurExploreMobilePageState
    extends State<EntrepreneurExploreMobilePage> {
  final vm = ServiceLocator.newEntrepreneurCubit();

  late bool showMap = widget.startInMap;
  MobilePropertyFilter filter = MobilePropertyFilter.empty;

  /// Unfiltered listings, used only to derive the category/area options so the
  /// chips always reflect the real data set.
  List<CommercialProperty> _all = const [];

  @override
  void initState() {
    super.initState();
    vm.loadExplore();
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

  List<CommercialProperty> get _results =>
      vm.explore.where(filter.matches).toList();

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
    setState(() => filter = MobilePropertyFilter.empty);
    vm.setFilter('All');
    vm.setQuery('');
  }

  void _openDetail(String id) => Navigator.of(
    context,
  ).pushNamed('/entrepreneur/property-detail', arguments: id);

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<AppCubit, AppState>(
      bloc: widget.appState,
      builder: (ctx, _) => BlocBuilder<EntrepreneurCubit, EntrepreneurState>(
        bloc: vm,
        builder: (ctx, _) => MobileAppShell(
        appState: widget.appState,
        title: 'Explore',
        currentRoute: '/entrepreneur/explore',
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Find commercial locations for your F&B business.',
                    style: TextStyle(
                      fontSize: 12.5,
                      color: SitewiseColors.muted,
                    ),
                  ),
                  const SizedBox(height: 12),
                  MobileSearchField(
                    hint: 'Search property, area or location',
                    onChanged: vm.setQuery,
                    trailing: MobileIconAction(
                      icon: showMap ? Icons.list_rounded : Icons.map_outlined,
                      tooltip: showMap ? 'Show list' : 'Show map',
                      active: showMap,
                      onPressed: () => setState(() => showMap = !showMap),
                    ),
                  ),
                  const SizedBox(height: 12),
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
      ),
      ),
    );
  }

  Widget _body() {
    if (vm.loading) return const MobilePropertyListSkeleton();
    if (vm.error != null) {
      return SitewiseErrorState(
        title: 'Unable to load properties',
        message: 'Please check your connection and try again.',
        onRetry: vm.loadExplore,
      );
    }
    if (showMap) return _mapView();

    final results = _results;
    if (results.isEmpty) {
      return SitewiseEmptyState(
        icon: Icons.search_off_rounded,
        title: 'No suitable properties found',
        message: 'Try adjusting your location, budget or property type.',
        actionLabel: 'Clear filters',
        onAction: _clearFilters,
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
      itemCount: results.length + 1,
      separatorBuilder: (context, index) => const SizedBox(height: 12),
      itemBuilder: (context, i) {
        if (i == 0) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Text(
              '${results.length} ${results.length == 1 ? 'property' : 'properties'}'
              '${filter.isActive ? ' · filtered' : ''}',
              style: const TextStyle(fontSize: 12, color: SitewiseColors.muted),
            ),
          );
        }
        final p = results[i - 1];
        return MobilePropertyCard(
          property: p,
          saved: widget.appState.isSaved(p.id),
          onToggleSaved: () => widget.appState.toggleSaved(p.id),
          compared: widget.appState.isCompared(p.id),
          onToggleCompare: () => widget.appState.toggleCompared(p.id),
          onTap: () => _openDetail(p.id),
        );
      },
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
