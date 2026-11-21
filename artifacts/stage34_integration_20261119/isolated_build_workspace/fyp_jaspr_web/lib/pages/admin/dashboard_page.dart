import 'dart:async';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/admin_ops_kit.dart';
import '../../components/dashboard_kit.dart';
import '../../components/letter_reveal.dart';
import '../../components/ui.dart';
import '../../data/admin_api.dart';
import '../../data/app_locator.dart';
import '../../layouts/app_layout.dart';

/// Admin console home, in the bento grid used across the app.
///
/// ```text
/// .bento-head    eyebrow + greeting + actions
/// .bento-kpis    4 KPI tiles (server-computed verification totals)
/// .bento         hero (verification health) · wide (audit activity)
///               · 3 work-queue cards
/// ```
///
/// Every number comes from an authenticated, server-computed source:
///
/// * **Verification totals** — `GET /api/v1/staff/properties/` with no filters
///   and `limit=1`. `total` and both dimensions' status facets are separate SQL
///   aggregates over `property_verification ⋈ fyp.rental_properties`, so they
///   cover every operational property regardless of page size. This is the same
///   projection the Listings queue reads, which is why the two pages agree; the
///   previous catalogue-filtered queue was a different property-ID universe.
/// * **Accounts** — `GET /api/v1/users/`.
/// * **Recent activity** — `GET /api/v1/staff/audit`, fetched by its own
///   component so an audit failure cannot blank the rest of the dashboard.
///
/// No administrator tour-review workflow exists in the schema or the API, so
/// the dashboard no longer renders a tour queue or KPI. Mobile tour capture and
/// property-level tours are unaffected.
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
      unawaited(admin.loadUsers());
      unawaited(admin.loadVerificationSummary());
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

/// The verification slice the property regions render, selected as one value
/// so a region rebuilds exactly when the totals or their error change.
typedef _Summary = ({VerificationQueuePage? page, String? error});

_Summary _summaryOf(AdminState state) =>
    (page: state.verificationSummary, error: state.summaryError);

/// A facet count. An absent status key means the server's `GROUP BY` matched no
/// rows, i.e. a real zero — but only once a page has actually arrived. Before
/// that the number is unknown and must not be rendered as `0`.
int _facet(
  VerificationQueuePage page,
  VerificationDimension dimension,
  PropertyVerificationStatus status,
) => page.countOf(dimension, status) ?? 0;

/// Loading shell, shown only while *nothing* has arrived yet. Each region owns
/// its own error state, so one failed source never replaces the whole page.
class _Shells extends StatelessComponent {
  const _Shells();

  @override
  Component build(BuildContext context) {
    final slice = context.watch(
      adminNotifierProvider.select(
        (state) => (
          loading: state.loading,
          hasUsers: state.users.isNotEmpty,
          hasSummary: state.verificationSummary != null,
        ),
      ),
    );
    if (slice.loading && !slice.hasUsers && !slice.hasSummary) {
      return const BentoSkeleton();
    }
    return div(classes: 'stack', [
      const _Head(),
      const _KpisRegion(),
      div(classes: 'bento', [
        const _HealthRegion(),
        const _RecentActivityCard(),
        const _ListingQueueRegion(),
        const _OwnershipQueueRegion(),
        const _AccountQueueRegion(),
      ]),
      p(classes: 'stat-note', [
        Component.text(
          'Verification totals are computed by the backend over every '
          'operational property and use the same definitions as the Listings '
          'queue. Account counts are read from the authenticated user '
          'directory. Activity is the server’s own audit trail.',
        ),
      ]),
    ]);
  }
}

// ------------------------------------------------------- scoped regions

class _KpisRegion extends StatelessComponent {
  const _KpisRegion();

  @override
  Component build(BuildContext context) {
    final summary = context.watch(adminNotifierProvider.select(_summaryOf));
    final page = summary.page;
    if (page == null) {
      final note = summary.error == null ? 'Loading…' : 'Unavailable';
      return div(classes: 'bento-kpis', [
        _kpi('Listings awaiting review', '—', note),
        _kpi('Ownership awaiting review', '—', note),
        _kpi('Approved listings', '—', note),
        _kpi('Rejected reviews', '—', note),
      ]);
    }

    final listingPending = _facet(
      page,
      VerificationDimension.listing,
      PropertyVerificationStatus.pending,
    );
    final ownershipPending = _facet(
      page,
      VerificationDimension.ownership,
      PropertyVerificationStatus.pending,
    );
    final approved = _facet(
      page,
      VerificationDimension.listing,
      PropertyVerificationStatus.verified,
    );
    final rejected =
        _facet(
          page,
          VerificationDimension.listing,
          PropertyVerificationStatus.rejected,
        ) +
        _facet(
          page,
          VerificationDimension.ownership,
          PropertyVerificationStatus.rejected,
        );

    return div(classes: 'bento-kpis', [
      _kpi(
        'Listings awaiting review',
        '$listingPending',
        'Listing dimension · ${PropertyVerificationStatus.pending.label}',
      ),
      _kpi(
        'Ownership awaiting review',
        '$ownershipPending',
        'Ownership dimension · ${PropertyVerificationStatus.pending.label}',
      ),
      _kpi(
        'Approved listings',
        '$approved',
        'Listing verified · ${page.total} submissions in total',
      ),
      _kpi('Rejected reviews', '$rejected', 'Listing + ownership decisions'),
    ]);
  }
}

/// Verification-health hero. Depends on the server totals only, so an account
/// or audit emit never rebuilds it (or restarts the donut transition).
class _HealthRegion extends StatelessComponent {
  const _HealthRegion();

  @override
  Component build(BuildContext context) {
    final summary = context.watch(adminNotifierProvider.select(_summaryOf));
    return _healthCard(
      summary,
      () => unawaited(
        context.read(adminNotifierProvider.notifier).loadVerificationSummary(),
      ),
    );
  }
}

class _ListingQueueRegion extends StatelessComponent {
  const _ListingQueueRegion();

  @override
  Component build(BuildContext context) {
    final summary = context.watch(adminNotifierProvider.select(_summaryOf));
    return _verificationQueueCard(
      summary,
      VerificationDimension.listing,
      'Listing verification',
      'Decide each submitted listing against the evidence the owner provided.',
    );
  }
}

class _OwnershipQueueRegion extends StatelessComponent {
  const _OwnershipQueueRegion();

  @override
  Component build(BuildContext context) {
    final summary = context.watch(adminNotifierProvider.select(_summaryOf));
    return _verificationQueueCard(
      summary,
      VerificationDimension.ownership,
      'Ownership verification',
      'Confirm the submitter may let this property, independently of the '
          'listing decision.',
    );
  }
}

class _AccountQueueRegion extends StatelessComponent {
  const _AccountQueueRegion();

  @override
  Component build(BuildContext context) {
    final slice = context.watch(
      adminNotifierProvider.select(
        (state) => (users: state.users, error: state.error),
      ),
    );
    final users = slice.users;
    if (users.isEmpty && slice.error != null) {
      return div(classes: 'bento-card', [
        div(classes: 'bento-card__head', [
          h3([Component.text('Account management')]),
          span(classes: 'card-note', [Component.text('Unavailable')]),
        ]),
        Callout(
          'The account directory could not be read: ${slice.error}',
          tone: 'danger',
          icon: 'error',
        ),
        ActionButton(
          'Try again',
          variant: 'secondary',
          onClick: () => unawaited(
            context.read(adminNotifierProvider.notifier).loadUsers(),
          ),
        ),
      ]);
    }
    final pending = users.where((user) => user.status == 'Pending').length;
    return _queueCard(
      'Account management',
      '${users.length}',
      'Inspect owner, agent and administrator accounts and their status.',
      '/admin/users',
      pending: pending,
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
            'Listing and ownership queues are counted by the verification '
            'backend, so this page and the Listings queue always agree. '
            'Privileged account actions are recorded in the server’s audit '
            'trail with the acting administrator and a timestamp.',
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
          to: '/admin/agents',
          classes: 'bento-period',
          children: [Component.text('Manage agents')],
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

Component _kpi(String k, String v, String n) {
  return div(classes: 'kpi', [
    span(classes: 'k', [Component.text(k)]),
    span(classes: 'v', [Component.text(v)]),
    span(classes: 'n', [Component.text(n)]),
  ]);
}

// ----------------------------------------------------- verification health

/// Dark hero card: the share of verification submissions whose listing
/// dimension is verified, plus the full status breakdown of both dimensions.
Component _healthCard(_Summary summary, void Function() onRetry) {
  final page = summary.page;

  if (page == null) {
    final failed = summary.error != null;
    return div(classes: 'bento-hero', [
      div(classes: 'bento-card__head', [
        h3([Component.text('Verification health')]),
        span(classes: 'hero-badge', [
          Component.text(failed ? 'Unavailable' : 'Loading'),
        ]),
      ]),
      div(classes: 'stack', [
        span(classes: 'title', [
          Component.text(
            failed
                ? 'Verification totals unavailable'
                : 'Reading verification totals…',
          ),
        ]),
        p(classes: 'hero-cap', [
          Component.text(
            failed
                ? summary.error!
                : 'Approval health appears here once the verification backend '
                      'answers.',
          ),
        ]),
        if (failed)
          ActionButton('Try again', variant: 'secondary', onClick: onRetry),
      ]),
    ]);
  }

  final total = page.total;
  if (total == 0) {
    return div(classes: 'bento-hero', [
      div(classes: 'bento-card__head', [
        h3([Component.text('Verification health')]),
        span(classes: 'hero-badge', [Component.text('No data')]),
      ]),
      div(classes: 'stack', [
        span(classes: 'title', [Component.text('No submissions yet')]),
        p(classes: 'hero-cap', [
          Component.text(
            'Approval health appears here once an owner submits a property '
            'for verification.',
          ),
        ]),
      ]),
    ]);
  }

  final approved = _facet(
    page,
    VerificationDimension.listing,
    PropertyVerificationStatus.verified,
  );
  final inFlight = total - approved;
  final pct = approved * 100 ~/ total;

  String breakdown(VerificationDimension dimension) => [
    for (final status in PropertyVerificationStatus.values)
      '${status.label} ${_facet(page, dimension, status)}',
  ].join(' · ');

  return div(classes: 'bento-hero', [
    div(classes: 'bento-card__head', [
      h3([Component.text('Verification health')]),
      span(classes: 'hero-badge', [Component.text('$total submissions')]),
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
        Component.text('$approved listing verified'),
      ]),
      span(classes: 'lg', [
        span(classes: 'dot b', []),
        Component.text('$inFlight not yet verified'),
      ]),
    ]),
    p(classes: 'hero-cap', [
      Component.text(
        'Listing dimension — ${breakdown(VerificationDimension.listing)}.',
      ),
    ]),
    p(classes: 'hero-cap', [
      Component.text(
        'Ownership dimension — ${breakdown(VerificationDimension.ownership)}.',
      ),
    ]),
    AppLink(
      to: '/admin/listings',
      classes: 'bento-cta',
      children: [Component.text('Open verification queue')],
    ),
  ]);
}

// ------------------------------------------------------------ work queues

/// One dimension's work queue: everything the backend considers decisionable
/// (`pending` + `under_review`), with both facet values spelled out so the card
/// cannot be read as a different metric from the Listings status tabs.
Component _verificationQueueCard(
  _Summary summary,
  VerificationDimension dimension,
  String title,
  String body,
) {
  final page = summary.page;
  if (page == null) {
    return _queueCard(
      title,
      '—',
      body,
      '/admin/listings',
      pending: 0,
      note: summary.error == null ? 'Loading' : 'Unavailable',
    );
  }
  final pending = _facet(page, dimension, PropertyVerificationStatus.pending);
  final underReview = _facet(
    page,
    dimension,
    PropertyVerificationStatus.underReview,
  );
  return _queueCard(
    title,
    '${pending + underReview}',
    '$body ${PropertyVerificationStatus.pending.label}: $pending · '
        '${PropertyVerificationStatus.underReview.label}: $underReview.',
    '/admin/listings',
    pending: pending + underReview,
  );
}

Component _queueCard(
  String title,
  String count,
  String body,
  String href, {
  required int pending,
  String? note,
}) => AppLink(
  to: href,
  classes: 'bento-card',
  children: [
    div(classes: 'bento-card__head', [
      h3([Component.text(title)]),
      span(classes: 'card-note', [
        Component.text(note ?? (pending > 0 ? 'Action needed' : 'Queue clear')),
      ]),
    ]),
    p(classes: 'muted', [Component.text(body)]),
    p(classes: 'queue-count', [Component.text(count)]),
  ],
);

// -------------------------------------------------------- audit activity

/// Recent privileged actions, straight from `GET /api/v1/staff/audit`.
///
/// Self-contained on purpose: the audit table lives in the Supabase identity
/// database and is reached over HTTPS, so it can fail while the rest of the
/// dashboard is perfectly healthy. Its loading, empty, denied and failure
/// states render inside this card only.
class _RecentActivityCard extends StatefulComponent {
  const _RecentActivityCard();

  @override
  State<_RecentActivityCard> createState() => _RecentActivityCardState();
}

class _RecentActivityCardState extends State<_RecentActivityCard> {
  static const _limit = 6;

  bool _loading = true;
  String? _error;
  List<AuditEvent> _events = const [];

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final events = await AppLocator.adminApi.listAudit();
      if (!mounted) return;
      setState(() {
        _events = events.take(_limit).toList(growable: false);
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = AdminApi.message(error);
        _loading = false;
      });
    }
  }

  @override
  Component build(BuildContext context) {
    return div(classes: 'bento-card bento-wide', [
      div(classes: 'bento-card__head', [
        h3([Component.text('Recent administrative activity')]),
        span(classes: 'card-note', [
          Component.text(_loading ? 'Loading' : 'Server audit trail'),
        ]),
      ]),
      if (_loading)
        const Skeleton(variant: 'row', count: 3)
      else if (_error != null)
        div(classes: 'stack', [
          Callout(
            'The audit feed could not be read: $_error',
            tone: 'danger',
            icon: 'error',
          ),
          p(classes: 'small muted', [
            Component.text(
              'An unreadable feed does not mean nothing happened. The rest of '
              'the dashboard is unaffected; retrying is safe because this is '
              'a read.',
            ),
          ]),
          ActionButton('Try again', variant: 'secondary', onClick: _load),
        ])
      else if (_events.isEmpty)
        const InlineEmpty(
          'The audit table returned no events yet: no privileged action has '
          'been recorded for this deployment.',
        )
      else ...[
        div(classes: 'ops-ev-list', [
          for (final event in _events)
            TimelineEntry(
              icon: event.group == 'listing' ? 'business' : 'shield',
              title: event.action,
              subject: event.subject,
              meta: [
                if (event.performedByEmail.isNotEmpty) event.performedByEmail,
                _when(event.createdAt),
                if (event.newStatus != null)
                  '${event.previousStatus ?? '—'} → ${event.newStatus!}',
                if (event.newRole != null)
                  '${event.previousRole ?? '—'} → ${event.newRole!}',
              ].join(' · '),
              badge: StatusBadge(_groupLabel(event.group), tone: _tone(event)),
            ),
        ]),
        p(classes: 'small muted', [
          Component.text(
            'Newest ${_events.length} of the most recent 200 retained events.',
          ),
        ]),
        AppLink(
          to: '/admin/activity',
          classes: 'bento-cta',
          children: [Component.text('Open full activity')],
        ),
      ],
    ]);
  }

  /// `2026-11-06T10:24:31+00:00` → `6 Nov · 10:24`. Unparseable stamps pass
  /// through verbatim rather than being shown as the epoch.
  static String _when(String iso) {
    final parsed = DateTime.tryParse(iso);
    if (parsed == null) return iso.isEmpty ? 'Time not recorded' : iso;
    final local = parsed.toLocal();
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    return '${local.day} ${months[local.month - 1]} · $hh:$mm';
  }

  static String _tone(AuditEvent event) {
    if (event.action.contains('suspend')) return 'danger';
    if (event.action.contains('invite') || event.action.contains('granted')) {
      return 'action';
    }
    if (event.action.contains('reset') || event.action.contains('assigned')) {
      return 'warning';
    }
    return 'neutral';
  }

  static String _groupLabel(String group) => switch (group) {
    'staff' => 'Staff access',
    'listing' => 'Listings',
    'role' => 'Roles',
    'status' => 'Status',
    'mfa' => 'MFA',
    _ => 'System',
  };
}
