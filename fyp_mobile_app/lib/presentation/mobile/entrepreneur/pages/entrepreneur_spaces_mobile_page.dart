import 'package:provider/provider.dart';
import 'package:flutter/material.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../../../application/services/service_locator.dart';
import '../../../../application/state/app_view_model.dart';
import '../../../../core/theme/sitewise_m3.dart';
import '../../../../core/theme/sitewise_theme.dart';
import '../../shell/mobile_app_shell.dart';
import '../../widgets/m3_kit.dart';

/// **Spaces** — the fourth tab of the consolidated five-tab navigation.
///
/// The reference prototype shows "managed property records" owned by the demo
/// account. This app has no entrepreneur-owned property entity: ownership is a
/// property-owner concern and `PropertyService.ownerListings` is scoped to an
/// owner id. Rather than invent records, this screen presents the two real
/// collections an entrepreneur actually has —
/// [AppViewModel.saved] (shortlisted spaces) and [AppViewModel.compared] (the
/// comparison set) — cross-referenced against the real property repository.
///
/// Labels say "shortlisted" rather than "owned" so the UI never implies an
/// authorization the data layer cannot back.

class EntrepreneurSpacesMobilePage extends StatelessWidget {
  const EntrepreneurSpacesMobilePage({super.key});

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppViewModel>();
    return MobileAppShell(
      title: 'Spaces',
      currentRoute: '/entrepreneur/spaces',
      body: M3Content(
        children: [
          const M3ScreenHeading(
            eyebrow: 'Property workspace',
            title: 'My spaces',
            lead:
                'The commercial spaces you have shortlisted and the ones '
                'queued for comparison.',
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: M3MetricTile(
                  label: 'Shortlisted',
                  value: '${appState.saved.length}',
                  caption: 'Saved space records',
                  icon: Icons.storefront_outlined,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: M3MetricTile(
                  label: 'In comparison',
                  value: '${appState.compared.length}',
                  caption: 'Of ${AppState.maxCompare} slots',
                  icon: Icons.compare_arrows_rounded,
                  teal: true,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          M3PrimaryButton(
            label: 'Explore properties',
            onTap: () =>
                Navigator.of(context).pushNamed('/entrepreneur/explore'),
          ),
          M3SectionRow(
            title: 'Property records',
            overline: '${appState.saved.length} SHORTLISTED',
          ),
          if (appState.saved.isEmpty)
            M3EmptyState(
              icon: Icons.storefront_outlined,
              title: 'No spaces saved yet',
              message:
                  'Save a property from the Listing tab and it will '
                  'appear here as a space record.',
              actionLabel: 'Browse listings',
              onAction: () =>
                  Navigator.of(context).pushNamed('/entrepreneur/explore'),
            )
          else
            FutureBuilder<List<CommercialProperty>>(
              future: ServiceLocator.properties.listings(),
              builder: (context, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const Padding(
                    padding: EdgeInsets.only(top: 24),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                final records = (snap.data ?? const <CommercialProperty>[])
                    .where((p) => appState.saved.contains(p.id))
                    .toList();
                if (records.isEmpty) {
                  return const M3EmptyState(
                    icon: Icons.storefront_outlined,
                    title: 'Records unavailable',
                    message:
                        'The saved properties are no longer present in '
                        'the property repository.',
                  );
                }
                return Column(
                  children: [
                    for (final p in records) ...[
                      _SpaceCard(
                        property: p,
                        compared: appState.isCompared(p.id),
                        onTap: () => Navigator.of(context).pushNamed(
                          '/entrepreneur/property-detail',
                          arguments: p.id,
                        ),
                      ),
                      const SizedBox(height: 10),
                    ],
                  ],
                );
              },
            ),
          const M3Banner(
            icon: Icons.verified_user_outlined,
            text:
                'Ownership verification, agent review and admin approval '
                'are separate from the shortlist. Editing a managed property '
                'record is only available to its authorized owner or manager.',
          ),
        ],
      ),
    );
  }
}

class _SpaceCard extends StatelessWidget {
  final CommercialProperty property;
  final bool compared;
  final VoidCallback onTap;

  const _SpaceCard({
    required this.property,
    required this.compared,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final p = property;
    return M3Card(
      onTap: onTap,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 43,
                height: 43,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: SitewiseM3.metricTealIconBg,
                  borderRadius: BorderRadius.circular(15),
                ),
                child: const Icon(
                  Icons.storefront_outlined,
                  size: 23,
                  color: SitewiseM3.metricTealIcon,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      p.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: kFontFamily,
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        color: SitewiseM3.rowTitle,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      m3PropertyLine(p),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: kFontFamily,
                        fontSize: 11,
                        color: SitewiseM3.rowDesc,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(
                Icons.arrow_forward_ios_rounded,
                size: 16,
                color: Color(0xFF4E6E9E),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Divider(height: 1, color: SitewiseM3.divider),
          const SizedBox(height: 12),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              M3Tag(label: '${p.sizeSqft.toStringAsFixed(0)} sqft'),
              M3Tag(label: p.propertyType),
              if (p.hasTour) const M3Tag(label: '360° tour', positive: true),
              if (compared) const M3Tag(label: 'Comparing', positive: true),
            ],
          ),
        ],
      ),
    );
  }
}
