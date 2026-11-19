import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../../../core/theme/sitewise_theme.dart';
import '../../shell/entrepreneur_tab_scope.dart';
import '../../shell/mobile_app_shell.dart';
import '../../widgets/mobile_property_image.dart';
import '../../widgets/mobile_section_header.dart';
import '../../widgets/mobile_skeleton.dart';
import '../../../shared/widgets/sitewise_empty_state.dart';

/// Mobile Compare: direct differences between up to three selected properties.
///
/// The data comes from the SAME batch comparison endpoint as the web page.
/// This screen owns no filtering, ranking or scoring logic; missing values are
/// rendered as "Data not available" exactly as the backend reports them.
class EntrepreneurCompareMobilePage extends ConsumerStatefulWidget {
  const EntrepreneurCompareMobilePage({super.key});

  @override
  ConsumerState<EntrepreneurCompareMobilePage> createState() =>
      _EntrepreneurCompareMobilePageState();
}

class _EntrepreneurCompareMobilePageState
    extends ConsumerState<EntrepreneurCompareMobilePage> {
  String _requestedIds = '';

  List<String> _ids() =>
      ref.read(appNotifierProvider).compared.toList();

  void _sync() {
    final ids = _ids();
    final signature = ids.join('|');
    if (signature == _requestedIds) return;
    _requestedIds = signature;
    ref.read(propertyCompareProvider.notifier).load(ids);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _sync();
    });
  }

  @override
  Widget build(BuildContext context) {
    final compared = ref.watch(
      appNotifierProvider.select((app) => app.compared),
    );
    final result = ref.watch(propertyCompareProvider);
    // Re-entry with a changed selection is a real reload; an ordinary rebuild
    // does not re-request anything.
    _sync();

    return MobileAppShell(
      title: 'Compare',
      currentRoute: '/entrepreneur/compare',
      body: RefreshIndicator(
        color: SitewiseColors.action,
        onRefresh: () async {
          await ref
              .read(propertyCompareProvider.notifier)
              .load(compared.toList(), refresh: true);
        },
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
          children: [
            const MobileSectionHeader(
              title: 'Compare your shortlisted properties',
              subtitle: 'Observable differences, not another ranking.',
            ),
            const SizedBox(height: 8),
            Text(
              '${compared.length} of 3 selected',
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: SitewiseColors.muted,
              ),
            ),
            const SizedBox(height: 12),
            if (compared.isEmpty)
              SitewiseEmptyState(
                icon: Icons.compare_arrows,
                title: 'Nothing to compare',
                message: 'Add two or three properties from Recommendations.',
                actionLabel: 'Browse recommendations',
                onAction: () => EntrepreneurTabScope.open(
                  context,
                  '/entrepreneur/recommendations',
                ),
              )
            else if (compared.length < 2)
              const _Notice(
                text: 'Add one more property for a side-by-side comparison.',
              )
            else if (result.error != null)
              _Notice(
                text: result.error!,
                retry: () => ref
                    .read(propertyCompareProvider.notifier)
                    .load(compared.toList(), refresh: true),
              )
            else if (result.loading && result.data == null)
              const MobilePropertyListSkeleton()
            else if (result.data case final data?)
                  _body(context, data),
          ],
        ),
      ),
    );
  }

  Widget _body(BuildContext context, PropertyCompareResult data) {
    final properties = data.properties;
    if (properties.isEmpty) {
      return const _Notice(text: 'No selected property could be resolved.');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (data.unresolvedIds.isNotEmpty)
          _Notice(
            text: '${data.unresolvedIds.length} selected '
                '${data.unresolvedIds.length == 1 ? 'property was' : 'properties were'} '
                'not found and were left out.',
          ),
        const SizedBox(height: 14),
        _selector(context, properties),
        const SizedBox(height: 18),
        _KeyDifferences(data: data),
        const SizedBox(height: 18),
        _Category(
          title: 'Cost & space',
          properties: properties,
          keys: const [
            'monthly_rent_rm',
            'size_sqft',
            'rent_per_sqft',
            'floor_level_text',
            'has_parking',
          ],
        ),
        const SizedBox(height: 18),
        _Category(
          title: 'Location & accessibility',
          properties: properties,
          keys: const [
            'population_500m',
            'population_1000m',
            'nearest_transit_walk_m',
            'bus_stops_500m_walk',
            'walk_isochrone_area_10min_km2',
            'parking_facilities_500m',
            'office_pois_500m',
            'universities_count_500m',
            'malls_count_500m',
          ],
        ),
        const SizedBox(height: 18),
        _Category(
          title: 'Nearby F&B competition',
          properties: properties,
          keys: const [
            'fnb_competitors_500m',
            'fnb_competitors_1000m',
            'cafe_count_500m',
            'restaurant_count_500m',
            'nearest_competitor_distance_m',
          ],
          hint:
              'Counts use the same source and radius for every property. '
              'Fewer recorded competitors does not prove stronger demand.',
        ),
        const SizedBox(height: 18),
        _Tradeoffs(tradeoffs: data.tradeoffs),
        const SizedBox(height: 18),
        _ResearchContext(properties: properties),
        const SizedBox(height: 12),
        for (final note in data.notes)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              note,
              style: const TextStyle(
                fontSize: 12,
                height: 1.5,
                color: SitewiseColors.muted,
              ),
            ),
          ),
        const SizedBox(height: 10),
        Center(
          child: TextButton.icon(
            onPressed: () {
              ref.read(appNotifierProvider.notifier).clearCompared();
              ref.read(propertyCompareProvider.notifier).reset();
            },
            icon: const Icon(Icons.close_rounded, size: 17),
            label: const Text('Clear comparison'),
            style: TextButton.styleFrom(
              foregroundColor: SitewiseColors.action,
            ),
          ),
        ),
      ],
    );
  }

  /// Horizontal selector keeps all selected properties visible on small
  /// screens while remaining one simple scroll gesture.
  Widget _selector(BuildContext context, List<CompareProperty> properties) =>
      SizedBox(
        height: 128,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: properties.length,
          separatorBuilder: (_, _) => const SizedBox(width: 10),
          itemBuilder: (context, index) {
            final property = properties[index];
            return SizedBox(
              width: 176,
              child: InkWell(
                onTap: () => Navigator.of(context).pushNamed(
                  '/entrepreneur/property-detail',
                  arguments: property.id,
                ),
                borderRadius: BorderRadius.circular(14),
                child: Container(
                  decoration: BoxDecoration(
                    color: SitewiseColors.surface,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: SitewiseColors.border),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      MobilePropertyImage(
                        property: CommercialProperty(
                          id: property.id,
                          title: property.title,
                          address: property.address,
                          city: property.city,
                          state: property.state,
                          postcode: property.postcode,
                          rentalRm: property.metric('monthly_rent_rm').value?.toDouble() ?? 0,
                          sizeSqft: property.metric('size_sqft').value?.toDouble() ?? 0,
                          latitude: 0,
                          longitude: 0,
                          propertyType: property.propertyType,
                          verification: VerificationStatus.pending,
                          suitabilityScore: 0,
                          hasSuitabilityScore: false,
                          hasTour: property.panoramaAvailable,
                          ownerId: '',
                          imageUrl: property.imageUrl,
                        ),
                        height: 58,
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              property.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w800,
                                color: SitewiseColors.ink,
                              ),
                            ),
                            Text(
                              '${property.metric('monthly_rent_rm').display} · '
                              '${property.metric('size_sqft').display}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 11,
                                color: SitewiseColors.muted,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      );
}

class _Notice extends StatelessWidget {
  final String text;
  final VoidCallback? retry;

  const _Notice({required this.text, this.retry});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: SitewiseColors.surface,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: SitewiseColors.border),
    ),
    child: Row(
      children: [
        Expanded(
          child: Text(
            text,
            style: const TextStyle(
              fontSize: 13,
              height: 1.45,
              color: SitewiseColors.text,
            ),
          ),
        ),
        if (retry != null)
          TextButton(
            onPressed: retry,
            child: const Text('Retry'),
          ),
      ],
    ),
  );
}

class _KeyDifferences extends StatelessWidget {
  final PropertyCompareResult data;

  const _KeyDifferences({required this.data});

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const MobileSectionHeader(title: 'Key differences'),
      const SizedBox(height: 8),
      if (data.insights.isEmpty)
        const Text(
          'Not enough comparable evidence for a summary.',
          style: TextStyle(fontSize: 13, color: SitewiseColors.muted),
        )
      else
        for (final insight in data.insights)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: SitewiseColors.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: SitewiseColors.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  insight.title,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    color: SitewiseColors.ink,
                  ),
                ),
                for (final point in insight.points)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(
                          Icons.check_rounded,
                          size: 15,
                          color: SitewiseColors.action,
                        ),
                        const SizedBox(width: 5),
                        Expanded(
                          child: Text(
                            point,
                            style: const TextStyle(
                              fontSize: 12.5,
                              height: 1.4,
                              color: SitewiseColors.text,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
      for (final difference in data.differences)
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text(
            '• ${difference.sentence}',
            style: const TextStyle(
              fontSize: 12.5,
              height: 1.45,
              color: SitewiseColors.text,
            ),
          ),
        ),
    ],
  );
}

class _Category extends StatelessWidget {
  final String title;
  final List<CompareProperty> properties;
  final List<String> keys;
  final String? hint;

  const _Category({
    required this.title,
    required this.properties,
    required this.keys,
    this.hint,
  });

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      MobileSectionHeader(title: title),
      const SizedBox(height: 8),
      Container(
        decoration: BoxDecoration(
          color: SitewiseColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: SitewiseColors.border),
        ),
        child: Column(
          children: [
            for (final key in keys)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      properties.first.metric(key).caption,
                      style: const TextStyle(
                        fontSize: 12,
                        color: SitewiseColors.muted,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 5),
                    for (final property in properties)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 3),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                property.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 12.5,
                                  color: SitewiseColors.text,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              property.metric(key).display,
                              style: const TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w800,
                                color: SitewiseColors.ink,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
      if (hint != null)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            hint!,
            style: const TextStyle(
              fontSize: 12,
              height: 1.45,
              color: SitewiseColors.muted,
            ),
          ),
        ),
    ],
  );
}

class _Tradeoffs extends StatelessWidget {
  final List<CompareTradeoff> tradeoffs;

  const _Tradeoffs({required this.tradeoffs});

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const MobileSectionHeader(title: 'Key trade-offs'),
      for (final tradeoff in tradeoffs)
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: Text(
            tradeoff.text,
            style: const TextStyle(
              fontSize: 13,
              height: 1.45,
              color: SitewiseColors.ink,
            ),
          ),
          children: const [
            Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text(
                'Derived only from recorded measurements. No business outcome '
                'is predicted.',
                style: TextStyle(fontSize: 12, color: SitewiseColors.muted),
              ),
            ),
          ],
        ),
    ],
  );
}

class _ResearchContext extends StatelessWidget {
  final List<CompareProperty> properties;

  const _ResearchContext({required this.properties});

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const MobileSectionHeader(title: 'Research context'),
      for (final property in properties)
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  property.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12.5,
                    color: SitewiseColors.text,
                  ),
                ),
              ),
              Text(
                property.researchIndexAvailable
                    ? '${property.researchIndex?.toStringAsFixed(0)} / 100'
                    : 'Data not available',
                style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w800,
                  color: SitewiseColors.ink,
                ),
              ),
            ],
          ),
        ),
      const Text(
        'Uncalibrated research index only — not used to order this comparison.',
        style: TextStyle(fontSize: 12, color: SitewiseColors.muted),
      ),
    ],
  );
}
