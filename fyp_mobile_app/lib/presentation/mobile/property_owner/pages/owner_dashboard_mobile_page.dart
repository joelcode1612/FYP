import 'dart:async';
import '../../../../application/services/service_locator.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:shared_logic/shared_logic.dart';
import 'package:flutter/material.dart';

import '../../../../core/theme/sitewise_theme.dart';
import '../../../shared/widgets/sitewise_role_menu.dart';
import '../../shell/mobile_app_shell.dart';
import '../../widgets/mobile_card_rail.dart';
import '../../widgets/mobile_featured_banner.dart';
import '../../widgets/mobile_home_header.dart';
import '../../widgets/mobile_owner_property_card.dart';
import '../../widgets/mobile_quick_actions.dart';
import '../../widgets/mobile_review_row.dart';
import '../../widgets/mobile_search_field.dart';
import '../../widgets/mobile_section_header.dart';
import '../../widgets/mobile_skeleton.dart';
import '../../widgets/mobile_status_count_row.dart';

/// Mobile Property Owner Home.
///
/// Same structural pattern as the other roles' Home, but the content answers
/// the *owner's* question: which properties do I manage, and what should I do
/// next? Search is owner-scoped, the banner promotes listing a property, and
/// the rails are portfolio + status — never entrepreneur suitability.

class OwnerDashboardMobilePage extends StatefulWidget {
  final AppCubit appState;
  const OwnerDashboardMobilePage({super.key, required this.appState});

  @override
  State<OwnerDashboardMobilePage> createState() =>
      _OwnerDashboardMobilePageState();
}

class _OwnerDashboardMobilePageState extends State<OwnerDashboardMobilePage> {
  final vm = ServiceLocator.newOwnerCubit();

  /// The demo owner account this prototype signs in as.

  @override
  void initState() {
    super.initState();
    vm.load();
  }

  @override
  void dispose() {
    unawaited(vm.close());
    super.dispose();
  }

  void _open(String route, {Object? arguments}) =>
      Navigator.of(context).pushNamed(route, arguments: arguments);

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<AppCubit, AppState>(
      bloc: widget.appState,
      builder: (ctx, _) => BlocBuilder<OwnerCubit, OwnerState>(
        bloc: vm,
        builder: (ctx, _) {
        // The rail honours the owner search box, so typing visibly filters the
        // portfolio instead of silently doing nothing.
        final preview = vm.filteredProperties.take(6).toList();
        final pendingCount = vm.countByStatus(VerificationStatus.pending);

        return MobileAppShell(
          appState: widget.appState,
          title: 'Home',
          currentRoute: '/owner',
          embeddedHeader: true,
          body: ListView(
            padding: const EdgeInsets.only(bottom: 28),
            children: [
              // ── HEADER: menu · Sitewise · notifications ────────────────
              MobileHomeHeader(
                onMenu: () => SitewiseRoleMenu.show(context, widget.appState),
                actionIcon: Icons.notifications_none_rounded,
                actionTooltip: 'Notifications',
                badgeCount: pendingCount,
                onAction: () => _open('/owner/properties'),
              ),

              // ── SEARCH: owner-scoped, searches MY properties ───────────
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
                child: MobileSearchField(
                  hint: 'Search my properties',
                  onChanged: vm.setQuery,
                  trailing: MobileIconAction(
                    icon: Icons.tune_rounded,
                    tooltip: 'Filter by status',
                    active: vm.statusFilter != null,
                    onPressed: _pickStatusFilter,
                  ),
                ),
              ),

              // Live query feedback keeps the search honest: typing filters
              // the portfolio below rather than doing nothing.
              if (vm.query.isNotEmpty) ...[
                const SizedBox(height: 10),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: _QuerySummary(
                    query: vm.query,
                    matches: vm.filteredProperties.length,
                    onClear: () {
                      vm.setQuery('');
                      // Keep the field's own text in sync with the model.
                      FocusScope.of(context).unfocus();
                    },
                  ),
                ),
              ],
              const SizedBox(height: 16),

              // ── FEATURED ACTION: list / showcase a property ────────────
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: MobileFeaturedBanner(
                  headline: 'Showcase your commercial property',
                  supporting:
                      'Add rental details, photos and a 360° tour so '
                      'entrepreneurs can evaluate your listing.',
                  ctaLabel: 'Add Property',
                  icon: Icons.add_business_rounded,
                  onCta: () => _open('/owner/add-property'),
                ),
              ),
              const SizedBox(height: 20),

              // ── QUICK ACTIONS ──────────────────────────────────────────
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: MobileQuickActions(
                  actions: [
                    MobileQuickActionItem(
                      icon: Icons.store_outlined,
                      label: 'Properties',
                      onTap: () => _open('/owner/properties'),
                    ),
                    MobileQuickActionItem(
                      icon: Icons.add_business_outlined,
                      label: 'Add',
                      onTap: () => _open('/owner/add-property'),
                    ),
                    MobileQuickActionItem(
                      icon: Icons.threesixty_rounded,
                      label: '360° Tours',
                      onTap: () => _open('/owner/tours'),
                    ),
                    MobileQuickActionItem(
                      icon: Icons.verified_outlined,
                      label: 'Verification',
                      count: pendingCount,
                      onTap: _openVerification,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 22),

              // ── MY PROPERTIES (horizontal) ─────────────────────────────
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: MobileSectionHeader(
                  title: 'My Properties',
                  subtitle: vm.properties.isEmpty
                      ? 'No listings yet'
                      : '${vm.properties.length} '
                            '${vm.properties.length == 1 ? 'listing' : 'listings'} · '
                            '${vm.withTourCount} with 360° tours',
                  actionLabel: 'View all',
                  onAction: () => _open('/owner/properties'),
                ),
              ),
              const SizedBox(height: 12),
              if (vm.loading)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: MobilePropertyCardSkeleton(),
                )
              else if (preview.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: _OwnerEmptyHint(
                    filtering: vm.query.isNotEmpty || vm.statusFilter != null,
                    onAdd: () => _open('/owner/add-property'),
                    onClear: () {
                      vm.setQuery('');
                      vm.setStatusFilter(null);
                      setState(() {});
                    },
                  ),
                )
              else
                MobileCardRail(
                  itemCount: preview.length,
                  // Image 104 + copy block ≈ 118 + borders — rail height must
                  // clear the tallest card or the bottom pill would clip.
                  itemHeight: 226,
                  itemBuilder: (context, i) {
                    final p = preview[i];
                    return MobileOwnerPropertyCard(
                      property: p,
                      onTap: () =>
                          _open('/owner/property-detail', arguments: p.id),
                    );
                  },
                ),
              const SizedBox(height: 24),

              // ── PROPERTY STATUS (real counts) ──────────────────────────
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: MobileSectionHeader(title: 'Property status'),
              ),
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: MobileStatusCountRow(
                  counts: [
                    MobileStatusCount(
                      label: 'Verified',
                      count: vm.countByStatus(VerificationStatus.verified),
                      color: SitewiseColors.success,
                    ),
                    MobileStatusCount(
                      label: 'Pending',
                      count: vm.countByStatus(VerificationStatus.pending),
                      color: SitewiseColors.warning,
                    ),
                    MobileStatusCount(
                      label: 'Draft',
                      count: vm.countByStatus(VerificationStatus.draft),
                      color: SitewiseColors.muted,
                    ),
                    MobileStatusCount(
                      label: 'Rejected',
                      count: vm.countByStatus(VerificationStatus.rejected),
                      color: SitewiseColors.danger,
                    ),
                  ],
                  onTap: (c) => _open('/owner/properties'),
                ),
              ),
              const SizedBox(height: 24),

              // ── RECENT ACTIVITY ────────────────────────────────────────
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: MobileSectionHeader(
                  title: 'Recent activity',
                  actionLabel: vm.tours.isEmpty ? null : 'Manage tours',
                  onAction: vm.tours.isEmpty
                      ? null
                      : () => _open('/owner/tours'),
                ),
              ),
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: MobileActivityList(items: _activity()),
              ),
            ],
          ),
        );
      },
      ),
    );
  }

  /// Activity entries derived from real listing/tour state — never invented
  /// events with fabricated dates.
  List<MobileActivityItem> _activity() {
    final items = <MobileActivityItem>[];

    for (final p in vm.properties.take(3)) {
      switch (p.verification) {
        case VerificationStatus.pending:
          items.add(
            MobileActivityItem(
              icon: Icons.hourglass_top_rounded,
              title: '${p.title} is awaiting verification',
              when: '${p.city} · ${p.propertyType}',
              color: SitewiseColors.warning,
            ),
          );
        case VerificationStatus.verified:
          items.add(
            MobileActivityItem(
              icon: Icons.verified_rounded,
              title: '${p.title} is verified',
              when: '${p.city} · ${p.propertyType}',
              color: SitewiseColors.success,
            ),
          );
        case VerificationStatus.draft:
          items.add(
            MobileActivityItem(
              icon: Icons.edit_note_rounded,
              title: '${p.title} is still a draft',
              when: '${p.city} · submit to start verification',
              color: SitewiseColors.muted,
            ),
          );
        case VerificationStatus.rejected:
          items.add(
            MobileActivityItem(
              icon: Icons.report_gmailerrorred_rounded,
              title: '${p.title} needs changes',
              when: '${p.city} · update and resubmit',
              color: SitewiseColors.danger,
            ),
          );
      }
    }

    for (final t in vm.tours.take(2)) {
      items.add(
        MobileActivityItem(
          icon: Icons.threesixty_rounded,
          title: '${t.title} · ${t.sceneCount} scenes',
          when: t.published ? 'Published 360° tour' : '360° tour not published',
          color: SitewiseColors.action,
        ),
      );
    }

    return items.take(5).toList();
  }

  void _openVerification() {
    final pending = vm.properties
        .where((p) => p.verification == VerificationStatus.pending)
        .toList();
    if (pending.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No listings are awaiting verification.')),
      );
      return;
    }
    _open('/owner/property-detail', arguments: pending.first.id);
  }

  Future<void> _pickStatusFilter() async {
    final choice = await showModalBottomSheet<VerificationStatus?>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 18, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Filter by status',
                  style: TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.apps_rounded),
              title: const Text('All statuses'),
              selected: vm.statusFilter == null,
              onTap: () => Navigator.of(ctx).pop(),
            ),
            for (final s in VerificationStatus.values)
              ListTile(
                leading: const Icon(Icons.circle, size: 12),
                title: Text(s.label),
                selected: vm.statusFilter == s,
                onTap: () => Navigator.of(ctx).pop(s),
              ),
          ],
        ),
      ),
    );
    // `null` from the sheet means "dismissed" or "All statuses"; both clear it.
    vm.setStatusFilter(choice);
    if (mounted) setState(() {});
  }
}

/// Shows how many listings the current query matches.
class _QuerySummary extends StatelessWidget {
  final String query;
  final int matches;
  final VoidCallback onClear;

  const _QuerySummary({
    required this.query,
    required this.matches,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            '$matches ${matches == 1 ? 'listing matches' : 'listings match'} '
            '“$query”',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, color: SitewiseColors.muted),
          ),
        ),
        TextButton(
          onPressed: onClear,
          style: TextButton.styleFrom(
            foregroundColor: SitewiseColors.action,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            minimumSize: const Size(0, 32),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: const Text('Clear', style: TextStyle(fontSize: 12)),
        ),
      ],
    );
  }
}

/// Empty-state hint for an owner with no visible listings — distinguishes an
/// empty portfolio from an over-filtered view.
class _OwnerEmptyHint extends StatelessWidget {
  final bool filtering;
  final VoidCallback onAdd;
  final VoidCallback onClear;

  const _OwnerEmptyHint({
    required this.filtering,
    required this.onAdd,
    required this.onClear,
  });

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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            filtering ? 'No matching listings' : 'You have no listings yet',
            style: const TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w700,
              color: SitewiseColors.ink,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            filtering
                ? 'No listing matches your current search or status filter.'
                : 'Add a commercial property to start receiving enquiries from '
                      'entrepreneurs.',
            style: const TextStyle(
              fontSize: 12.5,
              height: 1.45,
              color: SitewiseColors.muted,
            ),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: filtering
                ? OutlinedButton(
                    onPressed: onClear,
                    child: const Text('Clear filters'),
                  )
                : FilledButton.icon(
                    onPressed: onAdd,
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('Add Property'),
                  ),
          ),
        ],
      ),
    );
  }
}
