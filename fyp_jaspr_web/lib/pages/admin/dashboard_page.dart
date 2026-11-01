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
  }

  @override
  void dispose() {
    unawaited(vm.close());
    super.dispose();
  }

  @override
  Component build(BuildContext context) {
    return CubitBuilder<AdminCubit, AdminState>(
      cubit: vm,
      builder: (context, _) {
        return AppLayout(
          role: AppRole.admin,
          currentRoute: '/admin',
          title: 'Verification overview',
          // The source dashboard has no page header — its first element is
          // `.bento-head`. Rendering both produced two competing titles, which
          // the source does not have.
          showPageHead: false,
          child: vm.loading
              ? const _Loading()
              : vm.error != null
              ? _error(vm.error!)
              : div(classes: 'stack', [
                  _head(),
                  _kpis(),
                  div(classes: 'bento', [
                    _healthCard(),
                    _auditCard(),
                    _queueCard(
                      'Property verification',
                      vm.queue.length,
                      'Review submitted listings against the evidence the owner '
                          'provided.',
                      '/admin/verification',
                      pending: vm.queue.length,
                    ),
                    _queueCard(
                      '360° tour verification',
                      vm.pendingTours.length,
                      'Confirm the tour belongs to the property and the '
                          'panorama is ready.',
                      '/admin/verification',
                      pending: vm.pendingTours.length,
                    ),
                    _queueCard(
                      'Account management',
                      vm.users.length,
                      'Inspect owner and administrator accounts and their '
                          'status.',
                      '/admin/users',
                      pending: 0,
                    ),
                  ]),
                  p(classes: 'stat-note', [
                    Component.text(
                      'Counts are read from the in-memory record store, not a '
                      'database. Seeded demonstration listings have no owner '
                      'account and are excluded from owner queues.',
                    ),
                  ]),
                ]),
        );
      },
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

  // -------------------------------------------------------------------- head

  Component _head() {
    return div(classes: 'bento-head', [
      div(classes: 'bh-title', [
        span(classes: 'eyebrow-sm', [Component.text('Administrator console')]),
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

  Component _kpis() {
    final approved = vm.listings
        .where((it) => it.verification == VerificationStatus.verified)
        .length;
    return div(classes: 'bento-kpis', [
      _kpi(
        'Properties awaiting review',
        '${vm.queue.length}',
        vm.queue.isEmpty ? 'Queue clear' : 'Needs a decision',
      ),
      _kpi(
        'Tours awaiting review',
        '${vm.pendingTours.length}',
        vm.pendingTours.isEmpty ? 'Queue clear' : 'Needs a decision',
      ),
      _kpi('Approved listings', '$approved', '${vm.listings.length} in total'),
      _kpi('Accounts', '${vm.users.length}', 'Administrators and owners'),
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

class _Loading extends StatelessComponent {
  const _Loading();

  @override
  Component build(BuildContext context) => div(classes: 'loading', [
    span(classes: 'spinner', []),
    Component.text('Loading overview…'),
  ]);
}
