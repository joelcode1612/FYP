import 'dart:async';
import '../../../../application/services/service_locator.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:shared_logic/shared_logic.dart';
import 'package:flutter/material.dart';

import '../../../../core/theme/sitewise_theme.dart';
import '../../../shared/widgets/sitewise_role_menu.dart';
import '../../shell/mobile_app_shell.dart';
import '../../widgets/mobile_area_card.dart';
import '../../widgets/mobile_card_rail.dart';
import '../../widgets/mobile_category_tile.dart';
import '../../widgets/mobile_home_header.dart';
import '../../widgets/mobile_property_card.dart';
import '../../widgets/mobile_featured_banner.dart';
import '../../widgets/mobile_quick_actions.dart';
import '../../widgets/mobile_search_field.dart';
import '../../widgets/mobile_section_header.dart';
import '../../widgets/mobile_skeleton.dart';

/// Mobile entrepreneur Home.
///
/// Follows the shared mobile Home pattern —
/// header → search → featured action → quick actions → horizontal content →
/// secondary discovery → bottom navigation — and answers the entrepreneur's
/// question: *what can I explore, and which locations may fit my business?*
///
/// Everything is read from [EntrepreneurCubit] → services → repositories.
/// No listing array is invented here.

class EntrepreneurDashboardMobilePage extends StatefulWidget {
  final AppCubit appState;
  const EntrepreneurDashboardMobilePage({super.key, required this.appState});

  @override
  State<EntrepreneurDashboardMobilePage> createState() =>
      _EntrepreneurDashboardMobilePageState();
}

class _EntrepreneurDashboardMobilePageState
    extends State<EntrepreneurDashboardMobilePage> {
  final vm = ServiceLocator.newEntrepreneurCubit();

  @override
  void initState() {
    super.initState();
    vm.loadRecommendations();
  }

  @override
  void dispose() {
    unawaited(vm.close());
    super.dispose();
  }

  void _open(String route, {Object? arguments}) =>
      Navigator.of(context).pushNamed(route, arguments: arguments);

  void _openMenu() => SitewiseRoleMenu.show(context, widget.appState);

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<AppCubit, AppState>(
      bloc: widget.appState,
      builder: (ctx, _) => BlocBuilder<EntrepreneurCubit, EntrepreneurState>(
        bloc: vm,
        builder: (ctx, _) {
          final picks = vm.recommendations;
          final rail = picks.take(6).toList();

          return MobileAppShell(
            appState: widget.appState,
            title: 'Home',
            currentRoute: '/entrepreneur',
            embeddedHeader: true,
            body: ListView(
              padding: const EdgeInsets.only(bottom: 28),
              children: [
                // ── HEADER: menu · Sitewise · profile ──────────────────────
                MobileHomeHeader(
                  onMenu: _openMenu,
                  actionIcon: Icons.person_outline_rounded,
                  actionTooltip: 'Profile',
                  onAction: () => _open('/entrepreneur/profile'),
                ),

                // ── SEARCH: real Explore search entry point ────────────────
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
                  child: MobileSearchField(
                    readOnly: true,
                    onTap: () => _open('/entrepreneur/explore'),
                    trailing: MobileIconAction(
                      icon: Icons.map_outlined,
                      tooltip: 'Open map',
                      onPressed: () =>
                          _open('/entrepreneur/explore', arguments: 'map'),
                    ),
                  ),
                ),
                const SizedBox(height: SitewiseSpacing.md),

                // ── GREETING + HEADLINE ────────────────────────────────────
                // The reference mockup opens with a personal greeting. The name
                // is deliberately omitted: AppState carries no user, and printing
                // one would imply data the layer cannot back. Wire the auth user
                // in here once it is exposed to the page.
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: SitewiseSpacing.md),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Welcome back',
                        style: TextStyle(
                          fontSize: 12.5,
                          color: SitewiseColors.muted,
                        ),
                      ),
                      SizedBox(height: SitewiseSpacing.xs),
                      Text(
                        'What kind of location\nare you looking for?',
                        style: TextStyle(
                          fontFamily: 'Sora',
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                          height: 1.12,
                          letterSpacing: -0.44,
                          color: SitewiseColors.ink,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: SitewiseSpacing.md),

                // ── CATEGORY TILES ─────────────────────────────────────────
                // Property-type entry points, replacing the mockup's photographic
                // category cards. Counts come from the loaded recommendation set.
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: SitewiseSpacing.md,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: MobileCategoryTile(
                          label: 'Shoplots',
                          caption: 'Street-front units',
                          icon: Icons.storefront_outlined,
                          badge: '${_countMatching('shoplot')}',
                          onTap: () => _open('/entrepreneur/explore'),
                        ),
                      ),
                      const SizedBox(width: SitewiseSpacing.md),
                      Expanded(
                        child: MobileCategoryTile(
                          label: 'Corner units',
                          caption: 'Higher visibility',
                          icon: Icons.crop_square_rounded,
                          badge: '${_countMatching('corner')}',
                          onTap: () => _open('/entrepreneur/explore'),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: SitewiseSpacing.lg),

                // ── FEATURED ACTION: location discovery ───────────────────
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: MobileFeaturedBanner(
                    headline: 'Find the right F&B location',
                    supporting:
                        'Discover commercial properties matched to your business '
                        'preferences and budget.',
                    ctaLabel: 'Explore now',
                    icon: Icons.storefront_rounded,
                    onCta: () => _open('/entrepreneur/explore'),
                  ),
                ),
                const SizedBox(height: 20),

                // ── QUICK ACTIONS ──────────────────────────────────────────
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: MobileQuickActions(
                    actions: [
                      MobileQuickActionItem(
                        icon: Icons.explore_outlined,
                        label: 'Explore',
                        onTap: () => _open('/entrepreneur/explore'),
                      ),
                      MobileQuickActionItem(
                        icon: Icons.auto_awesome_outlined,
                        label: 'Recommended',
                        onTap: () => _open('/entrepreneur/recommendations'),
                      ),
                      MobileQuickActionItem(
                        icon: Icons.map_outlined,
                        label: 'Map',
                        onTap: () =>
                            _open('/entrepreneur/explore', arguments: 'map'),
                      ),
                      MobileQuickActionItem(
                        icon: Icons.threesixty_rounded,
                        label: '360° Tours',
                        onTap: _openTours,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 22),

                // ── RECOMMENDED PROPERTIES (horizontal) ───────────────────
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: MobileSectionHeader(
                    title: 'Recommended properties',
                    subtitle:
                        '${vm.prefs.businessType} · up to RM${vm.prefs.maxBudgetRm.toStringAsFixed(0)}',
                    actionLabel: 'View all',
                    onAction: () => _open('/entrepreneur/recommendations'),
                  ),
                ),
                const SizedBox(height: 12),
                if (vm.loading)
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16),
                    child: MobilePropertyCardSkeleton(),
                  )
                else if (rail.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16),
                    child: _InlineHint(
                      text:
                          'No recommendations yet — set your business '
                          'preferences to see matched locations.',
                    ),
                  )
                else
                  MobileCardRail(
                    itemCount: rail.length,
                    itemHeight: 200,
                    itemBuilder: (context, i) {
                      final p = rail[i].property;
                      return _recommendedCard(p, i);
                    },
                  ),
                const SizedBox(height: 24),

                // ── SECONDARY: explore areas (real listing counts) ─────────
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: MobileSectionHeader(
                    title: 'Explore locations',
                    subtitle:
                        'Popular commercial areas in the current listings.',
                    actionLabel: 'Map view',
                    onAction: () =>
                        _open('/entrepreneur/explore', arguments: 'map'),
                  ),
                ),
                const SizedBox(height: 12),
                MobileCardRail(
                  itemCount: _areas.length,
                  itemHeight: 132,
                  itemBuilder: (context, i) {
                    final a = _areas[i];
                    return MobileAreaCard(
                      area: a.city,
                      state: a.state,
                      listingCount: a.count,
                      onTap: () => _open('/entrepreneur/explore'),
                    );
                  },
                ),
                const SizedBox(height: 24),

                // ── Saved / compare entry points ───────────────────────────
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      Expanded(
                        child: _MiniTile(
                          icon: Icons.bookmark_border_rounded,
                          label: 'Saved',
                          value: '${widget.appState.saved.length}',
                          onTap: () => _open('/entrepreneur/saved'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _MiniTile(
                          icon: Icons.compare_arrows_rounded,
                          label: 'Compare',
                          value: '${widget.appState.compared.length}',
                          onTap: () => _open('/entrepreneur/compare'),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// A recommended property as a compact discovery card, with save + compare
  /// wired to the real [AppState] shortlist.
  Widget _recommendedCard(CommercialProperty p, int index) {
    final saved = widget.appState.isSaved(p.id);
    return SizedBox(
      width: MobileCompactPropertyCard.width,
      child: Stack(
        children: [
          MobileCompactPropertyCard(
            property: p,
            onTap: () =>
                _open('/entrepreneur/property-detail', arguments: p.id),
          ),
          Positioned(
            top: 6,
            right: 6,
            child: _SaveBubble(
              saved: saved,
              onTap: () => widget.appState.toggleSaved(p.id),
            ),
          ),
        ],
      ),
    );
  }

  /// Opens 360° tours for the top recommendation (the existing tour route).
  void _openTours() {
    final picks = vm.recommendations;
    final withTour = picks
        .map((r) => r.property)
        .where((p) => p.hasTour)
        .toList();
    if (withTour.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No 360° tours available yet.')),
      );
      return;
    }
    _open('/entrepreneur/tour', arguments: withTour.first.id);
  }

  /// How many loaded recommendations match [keyword] in their property type.
  ///
  /// `propertyType` is free text, not an enum — the demo data alone contains
  /// "Corner shoplot", "Shoplot unit", "Corner lot", "Heritage shoplot",
  /// "Retail unit" and "Shoplot / corner unit". An equality check would
  /// therefore silently return 0 for any label invented here, so this matches
  /// case-insensitively on a substring. Categories may overlap ("Corner
  /// shoplot" counts as both), which is normal for property categories.
  int _countMatching(String keyword) {
    final k = keyword.toLowerCase();
    return vm.recommendations
        .where((r) => r.property.propertyType.toLowerCase().contains(k))
        .length;
  }

  /// Distinct cities in the current listing set, with real counts — derived
  /// from the repository, never hardcoded geography.
  List<_AreaTally> get _areas {
    final seen = <String, _AreaTally>{};
    for (final r in vm.recommendations) {
      final p = r.property;
      final key = '${p.city}|${p.state}';
      seen.update(
        key,
        (v) => _AreaTally(p.city, p.state, v.count + 1),
        ifAbsent: () => _AreaTally(p.city, p.state, 1),
      );
    }
    final list = seen.values.toList()
      ..sort((a, b) => b.count.compareTo(a.count));
    return list;
  }
}

class _AreaTally {
  final String city;
  final String state;
  final int count;
  const _AreaTally(this.city, this.state, this.count);
}

/// Save toggle floating over a compact rail card.
class _SaveBubble extends StatelessWidget {
  final bool saved;
  final VoidCallback onTap;

  const _SaveBubble({required this.saved, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: SitewiseColors.surface.withValues(alpha: 0.94),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 32,
          height: 32,
          child: Icon(
            saved ? Icons.bookmark_rounded : Icons.bookmark_border_rounded,
            size: 17,
            color: saved ? SitewiseColors.action : SitewiseColors.ink,
          ),
        ),
      ),
    );
  }
}

/// Compact two-line tile for the saved / compare counts.
class _MiniTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final VoidCallback onTap;

  const _MiniTile({
    required this.icon,
    required this.label,
    required this.value,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: SitewiseColors.surface,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: SitewiseColors.border),
          ),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: SitewiseColors.geoWash,
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Icon(icon, size: 19, color: SitewiseColors.action),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      value,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        height: 1.1,
                        color: SitewiseColors.ink,
                      ),
                    ),
                    Text(
                      label,
                      style: const TextStyle(
                        fontSize: 11.5,
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
  }
}

/// Quiet inline hint used when a rail has no data yet.
class _InlineHint extends StatelessWidget {
  final String text;

  const _InlineHint({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: SitewiseColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: SitewiseColors.border),
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 12.5,
          height: 1.45,
          color: SitewiseColors.muted,
        ),
      ),
    );
  }
}
