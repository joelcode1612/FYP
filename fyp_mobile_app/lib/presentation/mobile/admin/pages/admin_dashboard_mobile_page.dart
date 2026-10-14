import 'dart:async';
import '../../../../application/services/service_locator.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:shared_logic/shared_logic.dart';
import 'package:flutter/material.dart';

import '../../../../core/theme/sitewise_theme.dart';
import '../../../shared/widgets/sitewise_error_state.dart';
import '../../../shared/widgets/sitewise_role_menu.dart';
import '../../shell/mobile_app_shell.dart';
import '../../widgets/mobile_area_card.dart';
import '../../widgets/mobile_card_rail.dart';
import '../../widgets/mobile_featured_banner.dart';
import '../../widgets/mobile_home_header.dart';
import '../../widgets/mobile_quick_actions.dart';
import '../../widgets/mobile_review_row.dart';
import '../../widgets/mobile_search_field.dart';
import '../../widgets/mobile_section_header.dart';
import '../../widgets/mobile_skeleton.dart';
import '../../widgets/mobile_status_count_row.dart';

/// Mobile Administrator Home.
///
/// Uses the same structural pattern as the other roles' Home, but it is a
/// *moderation* surface, not a property-browsing one. It answers the admin's
/// question: what needs my attention, and what should I review?
///
/// Consequently it shows no suitability scores (a buyer-facing signal), no map
/// and no discovery rails — it shows the verification queue, listing status
/// counts and platform activity instead.

class AdminDashboardMobilePage extends StatefulWidget {
  final AppCubit appState;
  const AdminDashboardMobilePage({super.key, required this.appState});

  @override
  State<AdminDashboardMobilePage> createState() =>
      _AdminDashboardMobilePageState();
}

class _AdminDashboardMobilePageState extends State<AdminDashboardMobilePage> {
  final vm = ServiceLocator.newAdminCubit();

  @override
  void initState() {
    super.initState();
    vm.loadDashboard();
    // Tour approvals are part of the same review workload; load them so the
    // activity feed reflects tours as well as listings.
    vm.loadPendingTours();
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
      builder: (ctx, _) => BlocBuilder<AdminCubit, AdminState>(
        bloc: vm,
        builder: (ctx, _) {
        // The review rail honours the admin search box so typing visibly
        // narrows the queue instead of silently doing nothing.
        final q = vm.query.toLowerCase();
        final queueRail = vm.queue
            .where(
              (p) =>
                  q.isEmpty ||
                  '${p.title} ${p.city} ${p.state} ${p.address} '
                          '${p.propertyType}'
                      .toLowerCase()
                      .contains(q),
            )
            .take(6)
            .toList();

        return MobileAppShell(
          appState: widget.appState,
          title: 'Home',
          currentRoute: '/admin',
          embeddedHeader: true,
          body: vm.loading
              ? ListView(
                  padding: const EdgeInsets.only(bottom: 28),
                  children: [
                    MobileHomeHeader(
                      onMenu: () =>
                          SitewiseRoleMenu.show(context, widget.appState),
                    ),
                    const SizedBox(height: 12),
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 16),
                      child: MobilePropertyCardSkeleton(),
                    ),
                    const SizedBox(height: 12),
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 16),
                      child: MobilePropertyCardSkeleton(),
                    ),
                  ],
                )
              : vm.error != null
              ? SitewiseErrorState(
                  title: 'Unable to load overview',
                  message: vm.error!,
                  onRetry: vm.loadDashboard,
                )
              : ListView(
                  padding: const EdgeInsets.only(bottom: 28),
                  children: [
                    // ── HEADER: menu · Sitewise · notifications ──────────
                    MobileHomeHeader(
                      onMenu: () =>
                          SitewiseRoleMenu.show(context, widget.appState),
                      actionIcon: Icons.notifications_none_rounded,
                      actionTooltip: 'Notifications',
                      badgeCount: vm.queue.length + vm.pendingUsers,
                      onAction: () => _open('/admin/verification'),
                    ),

                    // ── SEARCH: users, properties, listings ──────────────
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
                      child: MobileSearchField(
                        hint: 'Search users, properties or listings',
                        onChanged: vm.setQuery,
                        trailing: MobileIconAction(
                          icon: Icons.people_outline,
                          tooltip: 'Browse users',
                          onPressed: () => _open('/admin/users'),
                        ),
                      ),
                    ),
                    if (vm.query.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: _SearchSummary(
                          query: vm.query,
                          listings: vm.filteredListings.length,
                          users: vm.filteredUsers.length,
                          onOpenListings: () => _open('/admin/listings'),
                          onOpenUsers: () => _open('/admin/users'),
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),

                    // ── FEATURED ADMIN ACTION: keep listings accurate ────
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: MobileFeaturedBanner(
                        headline: 'Keep Sitewise listings accurate',
                        supporting:
                            'Review submitted properties and maintain trusted '
                            'commercial property information for entrepreneurs.',
                        ctaLabel: 'Review Verification',
                        icon: Icons.fact_check_rounded,
                        onCta: () => _open('/admin/verification'),
                        trailingChip: MobileBannerChip(
                          icon: Icons.pending_actions_rounded,
                          label: vm.queue.isEmpty
                              ? 'Queue clear'
                              : '${vm.queue.length} awaiting review',
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),

                    // ── QUICK ACTIONS ────────────────────────────────────
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: MobileQuickActions(
                        actions: [
                          MobileQuickActionItem(
                            icon: Icons.people_outline,
                            label: 'Users',
                            count: vm.pendingUsers,
                            onTap: () => _open('/admin/users'),
                          ),
                          MobileQuickActionItem(
                            icon: Icons.verified_outlined,
                            label: 'Verification',
                            count: vm.queue.length,
                            onTap: () => _open('/admin/verification'),
                          ),
                          MobileQuickActionItem(
                            icon: Icons.business_outlined,
                            label: 'Listings',
                            onTap: () => _open('/admin/listings'),
                          ),
                          MobileQuickActionItem(
                            icon: Icons.insights_outlined,
                            label: 'Activity',
                            onTap: () => _open('/admin/listings'),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 22),

                    // ── NEEDS YOUR REVIEW (primary content) ──────────────
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: MobileSectionHeader(
                        title: 'Needs your review',
                        subtitle: vm.queue.isEmpty
                            ? 'Nothing waiting right now'
                            : '${vm.queue.length} '
                                  '${vm.queue.length == 1 ? 'property' : 'properties'} '
                                  'submitted for verification',
                        actionLabel: 'View all',
                        onAction: () => _open('/admin/verification'),
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (queueRail.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 16),
                        child: _QueueClearHint(),
                      )
                    else
                      MobileCardRail(
                        itemCount: queueRail.length,
                        itemHeight: 150,
                        itemBuilder: (context, i) {
                          final p = queueRail[i];
                          return SizedBox(
                            width: 250,
                            child: MobileReviewRow(
                              property: p,
                              meta: _queueMeta(p),
                              onTap: () => _open(
                                '/admin/verification-detail',
                                arguments: p.id,
                              ),
                            ),
                          );
                        },
                      ),
                    const SizedBox(height: 24),

                    // ── LISTING OVERVIEW (real counts) ───────────────────
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 16),
                      child: MobileSectionHeader(title: 'Listing overview'),
                    ),
                    const SizedBox(height: 12),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: MobileStatusCountRow(
                        counts: [
                          MobileStatusCount(
                            label: 'Verified',
                            count: vm.countByStatus(
                              VerificationStatus.verified,
                            ),
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
                            count: vm.countByStatus(
                              VerificationStatus.rejected,
                            ),
                            color: SitewiseColors.danger,
                          ),
                        ],
                        onTap: (c) => _open('/admin/listings'),
                      ),
                    ),
                    const SizedBox(height: 24),

                    // ── RECENT ACTIVITY ──────────────────────────────────
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 16),
                      child: MobileSectionHeader(title: 'Recent activity'),
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

  /// Platform activity derived from real repository/state values.
  List<MobileActivityItem> _activity() {
    final items = <MobileActivityItem>[];

    for (final p in vm.queue.take(3)) {
      items.add(
        MobileActivityItem(
          icon: Icons.upload_file_rounded,
          title: '${p.title} submitted for verification',
          when: '${p.city}, ${p.state} · ${p.propertyType}',
          color: SitewiseColors.action,
        ),
      );
    }

    for (final t in vm.pendingTours.take(2)) {
      items.add(
        MobileActivityItem(
          icon: Icons.threesixty_rounded,
          title: '${t.title} awaiting tour approval',
          when: '${t.frameCount} frames captured',
          color: SitewiseColors.warning,
        ),
      );
    }

    for (final u in vm.users.where((u) => u.status == 'Pending').take(2)) {
      items.add(
        MobileActivityItem(
          icon: Icons.person_add_alt_1_rounded,
          title: '${u.name} registered as ${u.role.label}',
          when: '${u.location} · pending approval',
          color: SitewiseColors.muted,
        ),
      );
    }

    final verified = vm.listings
        .where((p) => p.verification == VerificationStatus.verified)
        .take(2);
    for (final p in verified) {
      items.add(
        MobileActivityItem(
          icon: Icons.verified_rounded,
          title: '${p.title} verified',
          when: '${p.city}, ${p.state}',
          color: SitewiseColors.success,
        ),
      );
    }

    return items.take(6).toList();
  }

  String _queueMeta(CommercialProperty p) => switch (p.verification) {
    VerificationStatus.pending => 'Awaiting decision',
    VerificationStatus.draft => 'Not submitted',
    VerificationStatus.rejected => 'Needs changes',
    VerificationStatus.verified => 'Verified',
  };
}

/// Search result summary across the two admin result kinds.
class _SearchSummary extends StatelessWidget {
  final String query;
  final int listings;
  final int users;
  final VoidCallback onOpenListings;
  final VoidCallback onOpenUsers;

  const _SearchSummary({
    required this.query,
    required this.listings,
    required this.users,
    required this.onOpenListings,
    required this.onOpenUsers,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      decoration: BoxDecoration(
        color: SitewiseColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: SitewiseColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Results for “$query”',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
              color: SitewiseColors.muted,
            ),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: _ResultCount(
                  icon: Icons.business_outlined,
                  count: listings,
                  label: listings == 1 ? 'listing' : 'listings',
                  onTap: onOpenListings,
                ),
              ),
              Expanded(
                child: _ResultCount(
                  icon: Icons.people_outline,
                  count: users,
                  label: users == 1 ? 'user' : 'users',
                  onTap: onOpenUsers,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ResultCount extends StatelessWidget {
  final IconData icon;
  final int count;
  final String label;
  final VoidCallback onTap;

  const _ResultCount({
    required this.icon,
    required this.count,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        child: Row(
          children: [
            Icon(icon, size: 16, color: SitewiseColors.action),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                '$count $label',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: SitewiseColors.ink,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shown when the verification queue is empty.
class _QueueClearHint extends StatelessWidget {
  const _QueueClearHint();

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
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: const BoxDecoration(
              color: Color(0xFFD3F8DF),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.check_rounded,
              size: 19,
              color: SitewiseColors.success,
            ),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Queue is clear',
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    color: SitewiseColors.ink,
                  ),
                ),
                SizedBox(height: 2),
                Text(
                  'No properties are waiting for verification right now.',
                  style: TextStyle(fontSize: 12, color: SitewiseColors.muted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
