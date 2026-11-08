import 'package:provider/provider.dart';
import 'package:shared_logic/shared_logic.dart';
import 'package:flutter/material.dart';

import '../../../../application/services/service_locator.dart';
import '../../../../application/state/app_view_model.dart';
import '../../../../core/theme/sitewise_theme.dart';
import '../../../shared/widgets/sitewise_button.dart';
import '../../../shared/widgets/sitewise_empty_state.dart';
import '../../../shared/widgets/sitewise_secondary_button.dart';
import '../../shell/mobile_app_shell.dart';
import '../../widgets/mobile_property_image.dart';
import '../../widgets/mobile_section_header.dart';
import '../../widgets/mobile_skeleton.dart';
import '../../widgets/mobile_suitability_badge.dart';

/// Mobile compare: stacked comparison cards per property — no desktop table.

class EntrepreneurCompareMobilePage extends StatelessWidget {
  const EntrepreneurCompareMobilePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<AppViewModel>(
      builder: (ctx, appState, _) => MobileAppShell(
        title: 'Compare',
        currentRoute: '/entrepreneur/compare',
        body: appState.compared.isEmpty
            ? SitewiseEmptyState(
                icon: Icons.compare_arrows,
                title: 'Nothing to compare',
                message: 'Add up to 3 properties from Explore or Recommended.',
                actionLabel: 'Explore properties',
                onAction: () =>
                    Navigator.of(context).pushNamed('/entrepreneur/explore'),
              )
            : FutureBuilder<List<CommercialProperty>>(
                future: ServiceLocator.properties.listings(),
                builder: (c, snap) {
                  if (snap.connectionState != ConnectionState.done) {
                    return const MobilePropertyListSkeleton();
                  }
                  final items = (snap.data ?? const <CommercialProperty>[])
                      .where((p) => appState.compared.contains(p.id))
                      .toList();
                  if (items.isEmpty) {
                    return const SitewiseEmptyState(
                      icon: Icons.compare_arrows,
                      title: 'Nothing to compare',
                      message:
                          'The properties you selected are no longer available.',
                    );
                  }
                  return ListView(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                    children: [
                      MobileSectionHeader(
                        title: 'Side by side',
                        subtitle: '${items.length} of 3 selected',
                      ),
                      const SizedBox(height: 14),
                      for (final p in items) ...[
                        _CompareCard(
                          property: p,
                          onRemove: () => appState.toggleCompared(p.id),
                          onOpen: () => Navigator.of(context).pushNamed(
                            '/entrepreneur/property-detail',
                            arguments: p.id,
                          ),
                        ),
                        const SizedBox(height: 12),
                      ],
                      const SizedBox(height: 4),
                      SitewiseSecondaryButton(
                        label: 'Clear comparison',
                        icon: Icons.close_rounded,
                        onPressed: appState.clearCompared,
                      ),
                      const SizedBox(height: 8),
                      SitewiseButton(
                        label: 'View first property',
                        onPressed: () => Navigator.of(context).pushNamed(
                          '/entrepreneur/property-detail',
                          arguments: items.first.id,
                        ),
                      ),
                    ],
                  );
                },
              ),
      ),
    );
  }
}

class _CompareCard extends StatelessWidget {
  final CommercialProperty property;
  final VoidCallback onRemove;
  final VoidCallback onOpen;

  const _CompareCard({
    required this.property,
    required this.onRemove,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: SitewiseColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: SitewiseColors.border),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0A0F172A),
            blurRadius: 10,
            offset: Offset(0, 3),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  MobilePropertyImage(
                    property: property,
                    width: 68,
                    height: 68,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          property.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: SitewiseColors.ink,
                            height: 1.2,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          '${property.city} · ${property.propertyType}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 11.5,
                            color: SitewiseColors.muted,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '${property.rentalDisplay} / month',
                          style: const TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w800,
                            color: SitewiseColors.action,
                          ),
                        ),
                      ],
                    ),
                  ),
                  InkWell(
                    onTap: onRemove,
                    borderRadius: BorderRadius.circular(20),
                    child: const Padding(
                      padding: EdgeInsets.all(4),
                      child: Icon(
                        Icons.close_rounded,
                        size: 18,
                        color: SitewiseColors.muted,
                      ),
                    ),
                  ),
                ],
              ),
              const Divider(height: 22),
              Row(
                children: [
                  MobileSuitabilityBadge(
                    score: property.suitabilityScore,
                    compact: true,
                  ),
                  const SizedBox(width: 6),
                  const Text(
                    'Location suitability',
                    style: TextStyle(fontSize: 11, color: SitewiseColors.muted),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              _metric(
                'Floor area',
                '${property.sizeSqft.toStringAsFixed(0)} sq ft',
              ),
              _metric(
                'Rental efficiency',
                'RM${property.rentalPerSqft.toStringAsFixed(2)} / sq ft',
              ),
              _metric('360° tour', property.hasTour ? 'Available' : 'Not yet'),
              _metric('Verification', property.verification.label),
            ],
          ),
        ),
      ),
    );
  }

  Widget _metric(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: const TextStyle(fontSize: 12.5, color: SitewiseColors.muted),
          ),
        ),
        Text(
          value,
          style: const TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w700,
            color: SitewiseColors.ink,
          ),
        ),
      ],
    ),
  );
}
