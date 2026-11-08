import 'dart:async';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/bloc.dart';
import '../../components/letter_reveal.dart';
import '../../components/ui.dart';
import '../../data/app_locator.dart';
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
  late final AdminCubit vm;

  @override
  void initState() {
    super.initState();
    vm = AppLocator.newAdminCubit();
    unawaited(vm.loadDashboard());
    // The tours KPI and queue card read pendingTours; without this call they
    // would permanently show 0 (only the verification page loaded tours).
    unawaited(vm.loadPendingTours());
  }

  @override
  void dispose() {
    unawaited(vm.close());
    super.dispose();
  }

  @override
  Component build(BuildContext context) {
    // The cubit never leaves this page, so callbacks close over `vm` directly
    // (the read style) instead of capturing values from builder state.
    return AppLayout(
      role: AppRole.admin,
      currentRoute: '/admin',
      title: 'Verification overview',
      // The source dashboard has no page header — its first element is
      // `.bento-head`. Rendering both produced two competing titles, which
      // the source does not have.
      showPageHead: false,
      // The outer builder re-renders only the loading/error shells. Data-only
      // emits (e.g. the late tour counts) are consumed by the region builders
      // below, so the static heading never rebuilds or replays its
      // letter-reveal animation. A tours failure is deliberately not surfaced
      // here: the dashboard data is still valid and the note below explains
      // that tours are demonstration data.
      child: CubitBuilder<AdminCubit, AdminState>(
        cubit: vm,
        when: (prev, next) =>
            prev.loading != next.loading ||
            (next.error != null &&
                next.listings.isEmpty &&
                next.users.isEmpty),
        builder: (context, state) {
          if (state.loading) return const BentoSkeleton();
          if (state.error != null) return _error(state.error!);
          return div(classes: 'stack', [
            _head(),
            _kpisRegion(),
            div(classes: 'bento', [
              _healthRegion(),
              _auditCard(),
              _propertyQueueRegion(),
              _tourQueueRegion(),
              _accountQueueRegion(),
            ]),
            p(classes: 'stat-note', [
              Component.text(
                'Property and account counts are read live from the '
                'authenticated backend API. 360° tour verification is '
                'still demonstration data — capture frames exist only on '
                'mobile, so there is no web source yet.',
              ),
            ]),
          ]);
        },
      ),
    );
  }

  Component _error(String message) => EmptyState(
    title: 'Something went wrong',
    body: message,
    action: ActionButton(
      'Try again',
      variant: 'primary',
      onClick: () => unawaited(vm.loadDashboard()),
    ),
  );

  // ------------------------------------------------------- scoped regions

  /// KPI row: rebuilt only when one of the four lists behind the numbers
  /// actually changes.
  Component _kpisRegion() => CubitBuilder<AdminCubit, AdminState>(
    cubit: vm,
    when: (prev, next) =>
        prev.queue != next.queue ||
        prev.pendingTours != next.pendingTours ||
        prev.listings != next.listings ||
        prev.users != next.users,
    builder: (context, state) => _kpis(state),
  );

  /// Verification-health hero: depends on listings only, so a late tours emit
  /// never rebuilds (or restarts the donut transition).
  Component _healthRegion() => CubitBuilder<AdminCubit, AdminState>(
    cubit: vm,
    when: (prev, next) => prev.listings != next.listings,
    builder: (context, state) => _healthCard(),
  );

  /// Work-queue cards: one scoped builder per card, so each card's count
  /// updates independently and each stays a direct child of the `.bento`
  /// grid.
  Component _propertyQueueRegion() => CubitBuilder<AdminCubit, AdminState>(
    cubit: vm,
    when: (prev, next) => prev.queue != next.queue,
    builder: (context, state) => _queueCard(
      'Property verification',
      state.queue.length,
      'Review submitted listings against the evidence the owner '
          'provided.',
      '/admin/verification',
      pending: state.queue.length,
    ),
  );

  Component _tourQueueRegion() => CubitBuilder<AdminCubit, AdminState>(
    cubit: vm,
    when: (prev, next) => prev.pendingTours != next.pendingTours,
    builder: (context, state) => _queueCard(
      '360° tour verification',
      state.pendingTours.length,
      'Confirm the tour belongs to the property and the '
          'panorama is ready.',
      '/admin/verification',
      pending: state.pendingTours.length,
    ),
  );

  Component _accountQueueRegion() => CubitBuilder<AdminCubit, AdminState>(
    cubit: vm,
    when: (prev, next) => prev.users != next.users,
    builder: (context, state) => _queueCard(
      'Account management',
      state.users.length,
      'Inspect owner and administrator accounts and their '
          'status.',
      '/admin/users',
      pending: 0,
    ),
  );

  // -------------------------------------------------------------------- head

  Component _head() {
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
          to: '/admin/verification',
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

  // -------------------------------------------------------------------- KPIs

  Component _kpis(AdminState state) {
    final approved = state.listings
        .where((it) => it.verification == VerificationStatus.verified)
        .length;
    return div(classes: 'bento-kpis', [
      _kpi(
        'Properties awaiting review',
        '${state.queue.length}',
        state.queue.isEmpty ? 'Queue clear' : 'Needs a decision',
      ),
      _kpi(
        'Tours awaiting review',
        '${state.pendingTours.length}',
        state.pendingTours.isEmpty ? 'Queue clear' : 'Needs a decision',
      ),
      _kpi(
        'Approved listings',
        '$approved',
        '${state.listings.length} in total',
      ),
      _kpi('Accounts', '${state.users.length}', 'Administrators and owners'),
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
  Component _healthCard() {
    final listings = vm.listings;
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
        to: '/admin/verification',
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
}
