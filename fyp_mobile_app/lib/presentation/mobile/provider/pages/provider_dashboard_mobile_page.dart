import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../application/services/service_locator.dart';
import '../../../../core/theme/sitewise_m3.dart';
import '../../../../core/theme/sitewise_theme.dart';
import '../../widgets/m3_kit.dart';
import '../../widgets/sitewise_network_image.dart';
import '../shell/provider_tab_scope.dart';
import 'provider_dashboard_controller.dart';
import 'provider_models.dart';
import 'provider_ui.dart';

/// Owner / Agent dashboard, rebuilt to the Agent / Property Owner reference
/// layouts.
///
/// Every figure on this screen is real: listings come from the role's
/// authorized endpoint (`GET /api/v1/properties/listings/mine` for an owner,
/// `GET /api/v1/staff/me/listings` for an agent), and the status counts are
/// arithmetic over those server rows. Metrics SiteWise does not record
/// (viewings, closed deals) render as an explicit "—" with a not-tracked
/// caption — never a fabricated zero or percentage.
///
/// The dashboard no longer depends on the Enquiries or Schedule features:
/// those screens are removed from the mobile Provider workspace, and their
/// fetch used to fail the WHOLE bundle. An empty portfolio renders the honest
/// empty state, and a backend failure renders the Retry card.
///
/// Structure per role (top to bottom):
/// * **Agent** — greeting → Agent overview → quick actions → Assigned
///   properties.
/// * **Owner** — greeting → Portfolio overview → quick actions → Your
///   properties → Tasks to do (derived from real drafts / rejections).
class ProviderDashboardMobilePage extends ConsumerStatefulWidget {
  const ProviderDashboardMobilePage({super.key});

  @override
  ConsumerState<ProviderDashboardMobilePage> createState() =>
      _ProviderDashboardMobilePageState();
}

class _ProviderDashboardMobilePageState
    extends ConsumerState<ProviderDashboardMobilePage> {
  @override
  void initState() {
    super.initState();
    // The Add Property form and detail pages mutate listings through the
    // shared repository. Refresh only when that revision actually changes;
    // simply switching back to Home must not refetch the dashboard.
    ServiceLocator.listingsRevision.addListener(_reload);
  }

  @override
  void dispose() {
    ServiceLocator.listingsRevision.removeListener(_reload);
    super.dispose();
  }

  void _reload() => ref.invalidate(providerDashboardProvider);

  void _open(String route, {Object? arguments}) {
    final scope = ProviderTabScope.maybeOf(context);
    if (scope != null && scope.handlesRoute(route)) {
      scope.go(route, arguments: arguments);
      return;
    }
    // A drill-in does not refetch on return by default. Mutations bump
    // `listingsRevision`, which is the only signal that can change these
    // figures; a plain view-and-back therefore stays instant.
    Navigator.of(context).pushNamed(route, arguments: arguments);
  }

  @override
  Widget build(BuildContext context) {
    final dashboard = ref.watch(providerDashboardProvider);
    return RefreshIndicator(
      color: SitewiseColors.action,
      onRefresh: () async {
        // Keep the spinner until the bundle settles; a failure is rendered
        // by the builder below, never rethrown into the gesture.
        await settleRefresh(ref.refresh(providerDashboardProvider.future));
      },
      child: dashboard.when(
        // A pull-to-refresh keeps the loaded sections on screen instead of
        // flashing back to the spinner.
        skipLoadingOnRefresh: true,
        loading: providerLoadingView,
        error: (error, _) => providerContent(
          children: [
            if (isMfaRequired(error))
              ProviderMfaGate(onReload: _reload)
            else
              ProviderMessage(
                title: 'Your dashboard could not be loaded',
                body: '$error',
                onRetry: _reload,
              ),
          ],
        ),
        data: (data) => providerContent(
          children: [
            _Greeting(data: data),
            const SizedBox(height: 4),
            _OverviewCard(data: data),
            const SizedBox(height: 16),
            _QuickActionRow(data: data, onOpen: _open),
            M3SectionRow(
              title: data.isAgent ? 'Assigned properties' : 'Your properties',
              actionLabel: 'View all',
              onAction: () => _open('/provider/listings'),
            ),
            if (data.listings.isEmpty)
              ProviderMessage(
                icon: Icons.storefront_outlined,
                title: data.isAgent
                    ? 'No assigned properties yet'
                    : 'No properties yet',
                body: data.isAgent
                    ? 'No property is assigned to this agent account. An '
                          'administrator assigns listings; once one is '
                          'assigned it appears here.'
                    : 'Create a draft to start the verification workflow. '
                          'Nothing is published until an administrator '
                          'approves the submission.',
              )
            else
              for (final listing in data.recentListings)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _PropertyCard(
                    listing: listing,
                    manageLabel: data.isAgent ? 'Open' : 'Manage',
                    onOpen: () => _open(
                      '/provider/property-detail',
                      arguments: listing.id,
                    ),
                  ),
                ),
            if (!data.isAgent) ...[
              const M3SectionRow(title: 'Tasks to do'),
              if (data.tasks.isEmpty)
                const ProviderMessage(
                  icon: Icons.task_alt_outlined,
                  title: 'Nothing to do',
                  body:
                      'No draft is waiting to be finished and no submission '
                      'was rejected. New tasks appear here as your portfolio '
                      'changes.',
                )
              else
                for (final task in data.tasks)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _TaskRow(task: task, onOpen: _open),
                  ),
            ],
            if (data.isAgent) ...[
              // The same classified records the Tasks tab renders — one
              // classifier, one payload, so Home and Tasks cannot disagree. The
              // count is the real outstanding count, the preview is at most
              // three actionable properties, and nothing here comes from
              // enquiries or appointments.
              M3SectionRow(
                title: 'Tasks requiring attention (${data.needsAttentionCount})',
                actionLabel: 'View all tasks',
                onAction: () => _open('/provider/tasks'),
              ),
              if (data.attentionPreview.isEmpty)
                const ProviderMessage(
                  icon: Icons.task_alt_outlined,
                  title: "You're all caught up",
                  body: 'No assigned properties need action right now.',
                )
              else
                for (final task in data.attentionPreview)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _TaskRow(task: task.asDashboardTask, onOpen: _open),
                  ),
            ],
            M3Banner(
              text:
                  'Viewed as ${data.isAgent ? 'Agent' : 'Property Owner'}. '
                  'Ownership and assignment are decided by the server, never '
                  'inferred from the sign-in screen.',
            ),
          ],
        ),
      ),
    );
  }
}

// ── Greeting ─────────────────────────────────────────────────────────────────

class _Greeting extends StatelessWidget {
  const _Greeting({required this.data});

  final ProviderDashboardData data;

  @override
  Widget build(BuildContext context) {
    final name = data.firstName;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          header: true,
          child: Text(
            name.isEmpty ? 'Welcome back' : 'Welcome back, $name',
            style: SitewiseM3Type.h1,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          data.isAgent
              ? 'Manage your assigned properties and their verification '
                    'statuses.'
              : 'Manage your F&B properties, listings, and verification in '
                    'one place.',
          style: SitewiseM3Type.lead,
        ),
      ],
    );
  }
}

// ── Overview card ────────────────────────────────────────────────────────────

/// One metric slot of the overview card.
class _Metric {
  const _Metric(this.icon, this.value, this.label, [this.caption]);

  final IconData icon;

  /// A real server figure, or the honest '—' for an untracked metric.
  final String value;
  final String label;

  /// Present only on untracked metrics, saying WHY there is no number.
  final String? caption;

  bool get unavailable => value == '—';
}

class _OverviewCard extends StatelessWidget {
  const _OverviewCard({required this.data});

  final ProviderDashboardData data;

  List<_Metric> get _metrics {
    if (data.isAgent) {
      return [
        _Metric(
          Icons.apartment_outlined,
          '${data.listingCount}',
          'Assigned Properties',
        ),
        _Metric(Icons.layers_outlined, '${data.publishedCount}', 'Published'),
        _Metric(
          Icons.schedule_outlined,
          '${data.pendingCount}',
          'Pending Review',
        ),
        // SiteWise emits no viewing events; the report states this too.
        const _Metric(
          Icons.calendar_today_outlined,
          '—',
          'Viewings Today',
          'Not tracked',
        ),
      ];
    }
    return [
      _Metric(
        Icons.apartment_outlined,
        '${data.listingCount}',
        'Total Properties',
      ),
      _Metric(
        Icons.layers_outlined,
        '${data.publishedCount}',
        'Published Listings',
      ),
      _Metric(
        Icons.schedule_outlined,
        '${data.pendingCount}',
        'Pending Review',
      ),
      _Metric(Icons.edit_note_outlined, '${data.draftCount}', 'Drafts'),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final metrics = _metrics;
    return Container(
      margin: const EdgeInsets.only(top: 16),
      decoration: BoxDecoration(
        color: SitewiseM3.surface,
        borderRadius: BorderRadius.circular(SitewiseM3.radiusFeature),
        border: Border.all(color: SitewiseM3.featureBorder),
        boxShadow: const [
          BoxShadow(
            color: Color(0x13305DAE),
            blurRadius: 24,
            offset: Offset(0, 7),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          // Subtle building watermark, the card's only decoration.
          Positioned(
            right: -10,
            top: -14,
            child: Opacity(
              opacity: 0.08,
              child: Transform.rotate(
                angle: -0.21,
                child: Icon(
                  Icons.domain_outlined,
                  size: 108,
                  color: SitewiseM3.primary,
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  data.isAgent ? 'Agent overview' : 'Portfolio overview',
                  style: const TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    color: SitewiseM3.ink,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  data.isAgent
                      ? 'Your agency activity at a glance.'
                      : 'Your property portfolio at a glance.',
                  style: const TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: 12,
                    color: SitewiseM3.muted,
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    for (var i = 0; i < metrics.length; i++) ...[
                      if (i > 0) ...[
                        const SizedBox(width: 6),
                        Container(width: 1, height: 42, color: SitewiseM3.line),
                        const SizedBox(width: 6),
                      ],
                      Expanded(child: _MetricSlot(metric: metrics[i])),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MetricSlot extends StatelessWidget {
  const _MetricSlot({required this.metric});

  final _Metric metric;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Container(
              width: 26,
              height: 26,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: providerWash,
                borderRadius: BorderRadius.circular(9),
              ),
              child: Icon(metric.icon, size: 16, color: SitewiseColors.action),
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                metric.value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.5,
                  color: metric.unavailable ? SitewiseM3.muted : SitewiseM3.ink,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 5),
        Text(
          metric.label,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontFamily: kFontFamily,
            fontSize: 9.5,
            height: 1.25,
            fontWeight: FontWeight.w600,
            color: SitewiseM3.muted,
          ),
        ),
        if (metric.caption != null) ...[
          const SizedBox(height: 2),
          Text(
            metric.caption!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontFamily: kFontFamily,
              fontSize: 9,
              color: Color(0xFF8B98AB),
            ),
          ),
        ],
      ],
    );
  }
}

// ── Quick actions ────────────────────────────────────────────────────────────

class _QuickAction {
  const _QuickAction(this.icon, this.label, this.route);

  final IconData icon;
  final String label;
  final String route;
}

class _QuickActionRow extends StatelessWidget {
  const _QuickActionRow({required this.data, required this.onOpen});

  final ProviderDashboardData data;
  final void Function(String route) onOpen;

  List<_QuickAction> get _actions => data.isAgent
      ? [
          const _QuickAction(
            Icons.apartment_outlined,
            'Assigned Listings',
            '/provider/listings',
          ),
          const _QuickAction(
            Icons.add_circle_outline,
            'Add Property',
            '/provider/add-property',
          ),
          const _QuickAction(
            Icons.bar_chart_rounded,
            'Performance',
            '/provider/performance',
          ),
        ]
      : [
          const _QuickAction(
            Icons.add_circle_outline,
            'Add Property',
            '/provider/add-property',
          ),
          const _QuickAction(
            Icons.apartment_outlined,
            'My Properties',
            '/provider/listings',
          ),
          const _QuickAction(
            Icons.bar_chart_rounded,
            'Performance',
            '/provider/performance',
          ),
        ];

  @override
  Widget build(BuildContext context) {
    final actions = _actions;
    return Row(
      children: [
        for (var i = 0; i < actions.length; i++) ...[
          if (i > 0) const SizedBox(width: 10),
          Expanded(
            child: _QuickActionTile(
              action: actions[i],
              onTap: () => onOpen(actions[i].route),
            ),
          ),
        ],
      ],
    );
  }
}

class _QuickActionTile extends StatelessWidget {
  const _QuickActionTile({required this.action, required this.onTap});

  final _QuickAction action;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: action.label,
      child: Material(
        color: SitewiseM3.surface,
        borderRadius: BorderRadius.circular(SitewiseM3.radiusRow),
        child: InkWell(
          borderRadius: BorderRadius.circular(SitewiseM3.radiusRow),
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minHeight: 86),
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 12),
            decoration: BoxDecoration(
              color: SitewiseM3.surface,
              borderRadius: BorderRadius.circular(SitewiseM3.radiusRow),
              border: Border.all(color: SitewiseM3.rowBorder),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x08264D82),
                  blurRadius: 13,
                  offset: Offset(0, 3),
                ),
              ],
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(action.icon, size: 26, color: SitewiseColors.action),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: Text(
                    action.label,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: kFontFamily,
                      fontSize: 10,
                      height: 1.25,
                      fontWeight: FontWeight.w700,
                      color: SitewiseM3.ink,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Property card ────────────────────────────────────────────────────────────

class _PropertyCard extends StatelessWidget {
  const _PropertyCard({
    required this.listing,
    required this.manageLabel,
    required this.onOpen,
  });

  final ProviderListing listing;
  final String manageLabel;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '$manageLabel ${listing.displayTitle}',
      child: M3Card(
        onTap: onOpen,
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: SitewiseNetworkImage(
                url: listing.imageUrl,
                width: 84,
                height: 66,
                fit: BoxFit.cover,
                semanticLabel: 'Photo of ${listing.displayTitle}',
                fallback: Container(
                  width: 84,
                  height: 66,
                  color: providerWash,
                  alignment: Alignment.center,
                  child: const Icon(
                    Icons.image_outlined,
                    size: 24,
                    color: SitewiseColors.muted,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    listing.displayTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: kFontFamily,
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                      color: SitewiseM3.ink,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      const Icon(
                        Icons.location_on_outlined,
                        size: 13,
                        color: SitewiseM3.muted,
                      ),
                      const SizedBox(width: 3),
                      Expanded(
                        child: Text(
                          listing.address.isEmpty
                              ? 'Address not set'
                              : listing.address,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontFamily: kFontFamily,
                            fontSize: 11,
                            color: SitewiseM3.muted,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 5),
                  Text(
                    listing.rentDisplay,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: kFontFamily,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w800,
                      color: SitewiseColors.action,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                ProviderStatusPill(stage: listing.stage, compact: true),
                const SizedBox(height: 8),
                OutlinedButton(
                  onPressed: onOpen,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: SitewiseColors.action,
                    side: const BorderSide(color: SitewiseColors.action),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(
                        SitewiseM3.radiusPill,
                      ),
                    ),
                    minimumSize: const Size(64, 34),
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                  ),
                  child: Text(manageLabel),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ── Task row (owner) ─────────────────────────────────────────────────────────

class _TaskRow extends StatelessWidget {
  const _TaskRow({required this.task, required this.onOpen});

  final ProviderDashboardTask task;
  final void Function(String route, {Object? arguments}) onOpen;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: task.title,
      child: M3Card(
        onTap: () => onOpen(task.route, arguments: task.arguments),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: providerWash,
                borderRadius: BorderRadius.circular(13),
              ),
              child: Icon(task.icon, size: 21, color: SitewiseColors.action),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    task.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: kFontFamily,
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                      color: SitewiseM3.ink,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    task.detail,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: kFontFamily,
                      fontSize: 11,
                      color: SitewiseM3.muted,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            const Icon(
              Icons.arrow_forward_ios_rounded,
              size: 14,
              color: Color(0xFF4E6E9E),
            ),
          ],
        ),
      ),
    );
  }
}
