import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/material.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../../../application/services/service_locator.dart';
import '../../../../core/config/mobile_config.dart';
import '../../../../core/theme/sitewise_m3.dart';
import '../../../../core/theme/sitewise_theme.dart';
import '../../shell/entrepreneur_tab_scope.dart';
import '../../shell/mobile_app_shell.dart';
import '../../widgets/m3_kit.dart';
import '../../../shared/widgets/sitewise_bottom_sheet.dart';

/// **Spaces** — the fourth tab of the consolidated five-tab navigation.
///
/// The reference prototype shows "managed property records" owned by the demo
/// account. This app has no entrepreneur-owned property entity: ownership is a
/// property-owner concern and `PropertyService.ownerListings` is scoped to an
/// owner id. Rather than invent records, this screen presents the two real
/// collections an entrepreneur actually has —
/// [AppState.saved] (shortlisted spaces) and [AppState.compared] (the
/// comparison set) — cross-referenced against the real property repository.
///
/// Labels say "shortlisted" rather than "owned" so the UI never implies an
/// authorization the data layer cannot back.

class EntrepreneurSpacesMobilePage extends ConsumerWidget {
  const EntrepreneurSpacesMobilePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appState = ref.watch(appNotifierProvider);
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
            label: 'Add property',
            onTap: () => Navigator.of(context)
                .pushNamed('/entrepreneur/add-property'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () => EntrepreneurTabScope.open(
              context,
              '/entrepreneur/explore',
            ),
            icon: const Icon(Icons.search_rounded),
            label: const Text('Explore properties'),
          ),
          const _OwnerListingsSection(),
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
                  EntrepreneurTabScope.open(context, '/entrepreneur/explore'),
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
                        compared: appState.compared.contains(p.id),
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

/// **My property listings** — the signed-in owner's REAL PostgreSQL records
/// (`fyp.rental_properties` via `/properties/listings/mine`), with the
/// verification lifecycle each one is in. Drafts and rejected/corrections
/// records resume in the Add Property flow; pending/approved records open a
/// read-only status sheet (the backend blocks edits awaiting review anyway).
class _OwnerListingsSection extends StatelessWidget {
  const _OwnerListingsSection();

  static String _statusLabel(String wire) => switch (wire) {
        'draft' => 'Draft',
        'pending' => 'Pending verification',
        'approved' => 'Approved',
        'rejected' => 'Rejected',
        _ => wire,
      };

  static Color _statusColor(String wire) => switch (wire) {
        'draft' => const Color(0xFF58677D),
        'pending' => const Color(0xFF965410),
        'approved' => const Color(0xFF087443),
        'rejected' => const Color(0xFFB91C1C),
        _ => const Color(0xFF58677D),
      };

  void _openListing(BuildContext context, OwnerListing listing) {
    if (listing.locallyEditable) {
      Navigator.of(context)
          .pushNamed('/entrepreneur/add-property', arguments: listing.id);
      return;
    }
    showSitewiseBottomSheet<void>(
      context,
      title: listing.name,
      builder: (_) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Status: ${_statusLabel(listing.verificationStatus)}'),
          const SizedBox(height: 4),
          Text(
            '${listing.propertyType ?? 'Property'} · '
            '${listing.rentalPrice == null ? 'Rent on request' : 'RM ${listing.rentalPrice!.toStringAsFixed(0)}'}',
          ),
          if (listing.rejectionReason != null) ...[
            const SizedBox(height: 8),
            Text(
              'Administrator note: ${listing.rejectionReason}',
              style: const TextStyle(color: Color(0xFFB91C1C)),
            ),
          ],
          const SizedBox(height: 12),
          const Text(
            'This record is awaiting or has passed review; its details can '
            'no longer be edited.',
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!MobileConfig.usesLiveApi) {
      // Demo builds hold no owner records; the section stays honest by
      // not pretending otherwise.
      return const SizedBox.shrink();
    }
    return FutureBuilder<List<OwnerListing>>(
      future: ServiceLocator.ownerListings.myListings(),
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Padding(
            padding: EdgeInsets.only(top: 20),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final listings = snap.data ?? const <OwnerListing>[];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            M3SectionRow(
              title: 'My property listings',
              overline: '${listings.length} RECORD(S)',
            ),
            if (snap.hasError)
              const M3Banner(
                icon: Icons.cloud_off_rounded,
                text:
                    'Saved listings could not load. Check the connection '
                    'and try again later.',
              )
            else if (listings.isEmpty)
              const M3EmptyState(
                icon: Icons.house_outlined,
                title: 'No property records yet',
                message:
                    'Saved drafts and submitted properties appear here '
                    'with their verification status.',
              )
            else
              for (final listing in listings) ...[
                const SizedBox(height: 10),
                M3Card(
                  onTap: () => _openListing(context, listing),
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              listing.name,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontFamily: kFontFamily,
                                fontSize: 13,
                                fontWeight: FontWeight.w800,
                                color: SitewiseM3.rowTitle,
                              ),
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: _statusColor(listing.verificationStatus)
                                  .withValues(alpha: .1),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              _statusLabel(listing.verificationStatus),
                              style: TextStyle(
                                fontFamily: kFontFamily,
                                fontSize: 10,
                                fontWeight: FontWeight.w800,
                                color:
                                    _statusColor(listing.verificationStatus),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        listing.rejectionReason != null
                            ? 'Corrections requested: ${listing.rejectionReason}'
                            : (listing.address ?? 'No address recorded yet'),
                        maxLines: 2,
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
              ],
          ],
        );
      },
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
