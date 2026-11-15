import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/material.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../../../application/services/service_locator.dart';
import '../../../../core/theme/sitewise_m3.dart';
import '../../../../core/theme/sitewise_theme.dart';
import '../../shell/entrepreneur_tab_scope.dart';
import '../../shell/mobile_app_shell.dart';
import '../../widgets/async_section.dart';
import '../../widgets/m3_kit.dart';
import '../../../shared/widgets/sitewise_inline_notice.dart';

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

class EntrepreneurSpacesMobilePage extends ConsumerStatefulWidget {
  const EntrepreneurSpacesMobilePage({super.key});

  @override
  ConsumerState<EntrepreneurSpacesMobilePage> createState() =>
      _EntrepreneurSpacesMobilePageState();
}

class _EntrepreneurSpacesMobilePageState
    extends ConsumerState<EntrepreneurSpacesMobilePage> {
  final GlobalKey<AsyncSectionState<List<CommercialProperty>>> _catalogueKey =
      GlobalKey<AsyncSectionState<List<CommercialProperty>>>();

  @override
  void initState() {
    super.initState();
    // The shortlist is server-owned; without this read the tab showed an empty
    // in-memory set on every launch even when the account had saved spaces.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(appNotifierProvider.notifier).loadSaved();
    });
  }

  Future<void> _refresh() async {
    await Future.wait([
      ref.read(appNotifierProvider.notifier).loadSaved(),
      _catalogueKey.currentState?.refresh() ?? Future<void>.value(),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final appState = ref.watch(appNotifierProvider);
    return MobileAppShell(
      title: 'Spaces',
      currentRoute: '/entrepreneur/spaces',
      body: RefreshIndicator(
        color: SitewiseColors.action,
        onRefresh: _refresh,
        child: M3Content(
        children: [
          const M3ScreenHeading(
            eyebrow: 'Property workspace',
            title: 'My spaces',
            lead:
                'The commercial spaces you have shortlisted and the ones '
                'queued for comparison.',
          ),
          const SizedBox(height: 18),
          if (appState.savedError != null)
            SitewiseInlineNotice(
              message: appState.savedError!,
              busy: appState.savedLoading,
              onRetry: () => ref.read(appNotifierProvider.notifier).loadSaved(),
            ),
          Row(
            children: [
              Expanded(
                child: M3MetricTile(
                  label: 'Shortlisted',
                  value: appState.savedError == null
                      ? '${appState.saved.length}'
                      : '—',
                  caption: appState.savedError == null
                      ? 'Saved space records'
                      : 'Could not be loaded',
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
          OutlinedButton.icon(
            onPressed: () => EntrepreneurTabScope.open(
              context,
              '/entrepreneur/recommendations',
            ),
            icon: const Icon(Icons.search_rounded),
            label: const Text('Browse recommendations'),
          ),
          M3SectionRow(
            title: 'Property records',
            overline: '${appState.saved.length} SHORTLISTED',
          ),
          if (appState.saved.isEmpty && appState.savedError == null)
            M3EmptyState(
              icon: Icons.storefront_outlined,
              title: 'No spaces saved yet',
              message:
                  'Save a property from the Recommendations tab and it will '
                  'appear here as a space record.',
              actionLabel: 'Browse recommendations',
              onAction: () => EntrepreneurTabScope.open(
                context,
                '/entrepreneur/recommendations',
              ),
            )
          else if (appState.saved.isEmpty)
            // The read failed: the notice above carries the reason and retry.
            const SizedBox.shrink()
          else
            AsyncSection<List<CommercialProperty>>(
              key: _catalogueKey,
              load: () => ServiceLocator.properties.listings(),
              errorTitle: 'Your saved spaces could not be loaded',
              builder: (context, catalogue) {
                final records =
                    catalogue.where((p) => appState.saved.contains(p.id)).toList();
                if (records.isEmpty) {
                  // The rows are gone from the catalogue, which is different
                  // from a failed read — the AsyncSection error state already
                  // covers the latter.
                  return const M3EmptyState(
                    icon: Icons.storefront_outlined,
                    title: 'Records unavailable',
                    message:
                        'The saved properties are no longer present in '
                        'the property catalogue.',
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
