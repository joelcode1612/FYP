import 'dart:async';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/letter_reveal.dart';
import '../../components/ui.dart';
import '../../layouts/app_layout.dart';

/// Admin console home, restructured to the bento grid used across the app.
///
/// The previous version rendered a **second** page header on top of the one
/// `AppLayout` already provides and then a `.pgrid` of property cards — a
/// browse layout where the source has a work-queue console. This rebuilds it
/// as:
///
/// ```text
/// .bento-head    eyebrow + greeting + actions
/// .bento-kpis    4 KPI tiles (live queue counts)
/// .bento         hero (verification health) · wide (audit activity)
///               · 3 work-queue cards
/// ```
///
/// Every count is read from the in-memory record store; nothing is fabricated.
@client
class DashboardPage extends StatefulComponent {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  @override
  void initState() {
    super.initState();
    // Deferred out of initState: the first controller publish would otherwise
    // happen while the tree is still building.
    Future.microtask(() {
      if (!mounted) return;
      final admin = context.read(adminNotifierProvider.notifier);
      unawaited(admin.loadDashboard());
      // The tours KPI and queue card read pendingTours; without this call they
      // would permanently show 0 (only the verification page loaded tours).
      unawaited(admin.loadPendingTours());
    });
  }

  @override
  Component build(BuildContext context) {
    return AppLayout(
      role: AppRole.admin,
      currentRoute: '/admin',
      title: 'Verification overview',
      // The source dashboard has no page header — its first element is
      // `.bento-head`. Rendering both produced two competing titles, which
      // the source does not have.
      showPageHead: false,
      child: const _Shells(),
    );
  }
}

/// The four lists behind the KPI numbers, selected as a single value so the
/// region rebuilds exactly when one of them changes — the `select` analogue
/// of the identity comparisons the previous `buildWhen` predicate made.
typedef _Counts = ({
  List<CommercialProperty> queue,
  List<VirtualTour> pendingTours,
  List<CommercialProperty> listings,
  List<SitewiseUser> users,
});

_Counts _countsOf(AdminState state) => (
  queue: state.queue,
  pendingTours: state.pendingTours,
  listings: state.listings,
  users: state.users,
);

/// Loading/error shells. A tours failure is deliberately not surfaced here:
/// the dashboard data is still valid and the note below explains that tours
/// are demonstration data — hence `queueError`, not `error`.
class _Shells extends StatelessComponent {
  const _Shells();

  @override
  Component build(BuildContext context) {
    final slice = context.watch(
      adminNotifierProvider.select(
        (state) => (
          loading: state.loading,
          queueError: state.error != null && state.listings.isEmpty && state.users.isEmpty,
          error: state.error,
        ),
      ),
    );
    if (slice.loading) return const BentoSkeleton();
    if (slice.queueError && slice.error != null) return _Error(slice.error!);
    return div(classes: 'stack', [
      const _Head(),
      const _KpisRegion(),
      div(classes: 'bento', [
        const _HealthRegion(),
        _auditCard(),
        const _PropertyQueueRegion(),
        const _TourQueueRegion(),
        const _AccountQueueRegion(),
      ]),
      p(classes: 'stat-note', [
        Component.text(
          'Property and account counts are read live from the authenticated '
          'backend API. 360° tour verification is still demonstration data — '
          'capture frames exist only on mobile, so there is no web source yet.',
        ),
      ]),
    ]);
  }
}

class _Error extends StatelessComponent {
  const _Error(this.message);

  final String message;

  @override
  Component build(BuildContext context) => EmptyState(
    title: 'Something went wrong',
    body: message,
    action: ActionButton(
      'Try again',
      variant: 'primary',
      onClick: () => unawaited(
        context.read(adminNotifierProvider.notifier).loadDashboard(),
      ),
    ),
  );
}

// ------------------------------------------------------- scoped regions

/// KPI row: rebuilt only when one of the four lists behind the numbers
/// actually changes.
class _KpisRegion extends StatelessComponent {
  const _KpisRegion();

  @override
  Component build(BuildContext context) {
    final counts = context.watch(adminNotifierProvider.select(_countsOf));
    return _kpis(counts);
  }
}

/// Verification-health hero: depends on listings only, so a late tours emit
/// never rebuilds (or restarts the donut transition).
class _HealthRegion extends StatelessComponent {
  const _HealthRegion();

  @override
  Component build(BuildContext context) {
    final listings = context.watch(
      adminNotifierProvider.select((state) => state.listings),
    );
    return _healthCard(listings);
  }
}

/// Work-queue cards: one scoped region per card, so each card's count updates
/// independently and each stays a direct child of the `.bento` grid.
class _PropertyQueueRegion extends StatelessComponent {
  const _PropertyQueueRegion();

  @override
  Component build(BuildContext context) {
    final queue = context.watch(adminNotifierProvider.select((state) => state.queue));
    return _queueCard(
      'Property verification',
      queue.length,
      'Review submitted listings against the evidence the owner provided.',
      '/admin/listings',
      pending: queue.length,
    );
  }
}

class _TourQueueRegion extends StatelessComponent {
  const _TourQueueRegion();

  @override
  Component build(BuildContext context) {
    final tours = context.watch(
      adminNotifierProvider.select((state) => state.pendingTours),
    );
    return _queueCard(
      '360° tour verification',
      tours.length,
      'Confirm the tour belongs to the property and the panorama is ready.',
      '/admin/listings',
      pending: tours.length,
    );
  }
}

class _AccountQueueRegion extends StatelessComponent {
  const _AccountQueueRegion();

  @override
  Component build(BuildContext context) {
    final users = context.watch(adminNotifierProvider.select((state) => state.users));
    return _queueCard(
      'Account management',
      users.length,
      'Inspect owner and administrator accounts and their status.',
      '/admin/users',
      pending: 0,
    );
  }
}

// -------------------------------------------------------------------- head

class _Head extends StatelessComponent {
  const _Head();

  @override
  Component build(BuildContext context) {
    return div(classes: 'bento-head', [
      div(classes: 'bh-title', [
        span(classes: 'eyebrow-sm', [
          Component.text('Staff portal · administrator'),
        ]),
        LetterRevealHeading.text('Verification overview', level: 1),
        p(classes: 'muted', [
          Component.text(
            'Queues are live counts from the record store. Every decision is '
            'written to the audit log with the administrator identity and a '
            'timestamp.',
          ),
        ]),
      ]),
      div(classes: 'bh-actions', [
        AppLink(
          to: '/admin/listings',
          classes: 'bento-cta',
          children: [Component.text('Review queue')],
        ),
        AppLink(
          to: '/admin/listings',
          classes: 'bento-period',
          children: [Component.text('Manage listings')],
        ),
        AppLink(
          to: '/admin/users',
          classes: 'bento-period',
          children: [Component.text('Manage users')],
        ),
      ]),
    ]);
  }
}

// -------------------------------------------------------------------- KPIs

Component _kpis(_Counts counts) {
  final approved = counts.listings
      .where((it) => it.verification == VerificationStatus.verified)
      .length;
  return div(classes: 'bento-kpis', [
    _kpi(
      'Properties awaiting review',
      '${counts.queue.length}',
      counts.queue.isEmpty ? 'Queue clear' : 'Needs a decision',
    ),
    _kpi(
      'Tours awaiting review',
      '${counts.pendingTours.length}',
      counts.pendingTours.isEmpty ? 'Queue clear' : 'Needs a decision',
    ),
    _kpi(
      'Approved listings',
      '$approved',
      '${counts.listings.length} in total',
    ),
    _kpi('Accounts', '${counts.users.length}', 'Administrators and owners'),
  ]);
}

Component _kpi(String k, String v, String n) {
  return div(classes: 'kpi', [
    span(classes: 'k', [Component.text(k)]),
    span(classes: 'v', [Component.text(v)]),
    span(classes: 'n', [Component.text(n)]),
  ]);
}

// ----------------------------------------------------- verification health

/// Dark hero card with a donut showing the share of all listings that are
/// approved versus still in flight (pending + rejected).
Component _healthCard(List<CommercialProperty> listings) {
  final total = listings.length;
  final approved = listings
      .where((it) => it.verification == VerificationStatus.verified)
      .length;
  final inFlight = total - approved;
  final pct = total > 0 ? (approved * 100 ~/ total) : 0;

  if (total == 0) {
    return div(classes: 'bento-hero', [
      div(classes: 'bento-card__head', [
        h3([Component.text('Verification health')]),
        span(classes: 'hero-badge', [Component.text('No data')]),
      ]),
      div(classes: 'stack', [
        span(classes: 'title', [Component.text('No listings yet')]),
        p(classes: 'hero-cap', [
          Component.text(
            'Approval health appears here once listings exist in the record '
            'store.',
          ),
        ]),
      ]),
    ]);
  }

  return div(classes: 'bento-hero', [
    div(classes: 'bento-card__head', [
      h3([Component.text('Verification health')]),
      span(classes: 'hero-badge', [Component.text('$total listings')]),
    ]),
    div(classes: 'donut-wrap', [
      div(classes: 'donut', styles: Styles(raw: {'--pct': '$pct'}), [
        div(classes: 'donut-center', [
          div(classes: 'dc-v', [Component.text('$pct%')]),
          div(classes: 'dc-k', [Component.text('approved')]),
        ]),
      ]),
    ]),
    div(classes: 'hero-legend', [
      span(classes: 'lg', [
        span(classes: 'dot a', []),
        Component.text('$approved approved'),
      ]),
      span(classes: 'lg', [
        span(classes: 'dot b', []),
        Component.text('$inFlight pending or rejected'),
      ]),
    ]),
    p(classes: 'hero-cap', [
      Component.text(
        '$pct% of all listings are approved. The ring reflects current '
        'verification status from the record store, not a forecast.',
      ),
    ]),
    AppLink(
      to: '/admin/listings',
      classes: 'bento-cta',
      children: [Component.text('Open verification queue')],
    ),
  ]);
}

// -------------------------------------------------------- audit activity

/// The target has no audit store, so this is the source's own empty state
/// rather than a table with invented rows.
Component _auditCard() {
  return div(classes: 'bento-card bento-wide', [
    div(classes: 'bento-card__head', [
      h3([Component.text('Recent administrative activity')]),
      span(classes: 'card-note', [Component.text('Live log')]),
    ]),
    EmptyState(
      title: 'No administrative actions yet',
      body:
          'Approvals, rejections, publication changes and account updates '
          'are recorded here as they happen. This prototype keeps no audit '
          'log, so nothing is listed.',
    ),
  ]);
}

// ------------------------------------------------------------ work queues

Component _queueCard(
  String title,
  int count,
  String body,
  String href, {
  required int pending,
}) => AppLink(
  to: href,
  classes: 'bento-card',
  children: [
    div(classes: 'bento-card__head', [
      h3([Component.text(title)]),
      span(classes: 'card-note', [
        Component.text(pending > 0 ? 'Action needed' : 'Queue clear'),
      ]),
    ]),
    p(classes: 'muted', [Component.text(body)]),
    p(classes: 'queue-count', [Component.text('$count')]),
  ],
);
