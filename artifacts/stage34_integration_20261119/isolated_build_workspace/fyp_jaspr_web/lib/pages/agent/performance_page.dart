import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/dashboard_kit.dart';
import '../../components/ui.dart';
import '../../data/admin_api.dart';
import '../../data/agent_records.dart';
import '../../layouts/app_layout.dart';

/// Agent performance.
///
/// The reference design puts an impressions → views → enquiries funnel here.
/// **This project captures none of those events**, so the funnel is drawn as
/// unfilled stages with the reason under each one, and the only numbers on the
/// page are arithmetic over the agent's REAL assigned listings — the same
/// `GET /api/v1/staff/me/listings` dataset the dashboard and Assigned
/// Listings read. An empty portfolio is reported as empty, never padded with
/// catalogue stand-ins.
///
/// That split is the whole point of the page: a chart of invented views would
/// be indistinguishable from a real report to anyone reading a screenshot,
/// which is exactly the failure mode the brief warns about.
@client
class AgentPerformancePage extends StatelessComponent {
  const AgentPerformancePage({super.key});

  @override
  Component build(BuildContext context) {
    return AppLayout(
      role: AppRole.agent,
      currentRoute: '/agent/performance',
      title: 'Performance',
      subtitle:
          'Portfolio figures are computed from your assigned listings. '
          'Engagement figures need events that are not captured yet.',
      eyebrow: 'Staff portal · agent',
      showPageHead: true,
      child: FutureBuilder<List<AgentAssignment>>(
        future: AgentRecords.assignedListings(),
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return div(classes: 'loading', [
              span(classes: 'spinner', []),
              Component.text('Loading your assigned properties...'),
            ]);
          }
          if (snapshot.hasError) {
            return _errorState(snapshot.error);
          }
          final listings = snapshot.data ?? const <AgentAssignment>[];
          return div(classes: 'stack', [
            if (listings.isEmpty)
              EmptyState(
                title: 'No properties assigned yet.',
                body:
                    'An administrator has not assigned any properties to your '
                    'account, so there is no portfolio to measure.',
              )
            else ...[
              _portfolioKpis(listings),
              _byStatusCard(listings),
            ],
            _funnelCard(),
          ]);
        },
      ),
    );
  }

  Component _errorState(Object? error) {
    return div(classes: 'card stack', [
      span(classes: 'title', [
        Component.text('Unable to load assigned properties.'),
      ]),
      p(classes: 'body muted', [
        Component.text(
          error == null
              ? 'The backend did not answer. Please retry.'
              : '${AdminApi.message(error)} Please retry.',
        ),
      ]),
      const ActionLink(
        'Retry',
        href: '/agent/performance',
        variant: 'secondary',
      ),
    ]);
  }

  /// Arithmetic over the REAL assignment rows — no invented metrics, and no
  /// research suitability index (it is not an assignment or performance
  /// measurement).
  Component _portfolioKpis(List<AgentAssignment> listings) {
    final rents = [
      for (final l in listings)
        if (l.raw['rental_price'] is num) (l.raw['rental_price'] as num).toDouble(),
    ];
    final sizes = [
      for (final l in listings)
        if (l.raw['size_sqft'] is num) (l.raw['size_sqft'] as num).toDouble(),
    ];
    final published = listings.where((l) => l.raw['is_published'] == true).length;
    return div(classes: 'bento-kpis', [
      _kpi('Listings held', '${listings.length}', 'Assigned to you'),
      _kpi(
        'Median rent',
        rents.isEmpty ? 'Not available' : _median(rents),
        rents.isEmpty ? 'No rental recorded' : 'Across your portfolio',
      ),
      _kpi(
        'Average size',
        sizes.isEmpty
            ? 'Not available'
            : '${(sizes.reduce((x, y) => x + y) / sizes.length).toStringAsFixed(0)} sqft',
        sizes.isEmpty ? 'No floor area recorded' : 'Across your portfolio',
      ),
      _kpi(
        'Live listings',
        '$published',
        'Published on the public site',
      ),
    ]);
  }

  String _median(List<double> values) {
    final sorted = [...values]..sort();
    final mid = sorted.length ~/ 2;
    final median = sorted.length.isOdd
        ? sorted[mid]
        : (sorted[mid - 1] + sorted[mid]) / 2;
    return 'RM ${median.toStringAsFixed(0)}';
  }

  Component _kpi(String k, String v, String n) => div(classes: 'kpi', [
    span(classes: 'k', [Component.text(k)]),
    span(classes: 'v', [Component.text(v)]),
    span(classes: 'n', [Component.text(n)]),
  ]);

  /// The funnel with every stage marked uncaptured.
  Component _funnelCard() {
    return div(classes: 'bento-card bento-wide', [
      div(classes: 'bento-card__head', [
        h3([Component.text('Enquiry funnel')]),
        span(classes: 'card-note', [Component.text('Not captured')]),
      ]),
      div(classes: 'funnel', [
        for (final stage in const [
          (
            'Impressions',
            'Listing shown in a result set',
            'Search results are not logged anywhere.',
          ),
          (
            'Views',
            'Listing detail opened',
            'No page-view event is emitted by the detail page.',
          ),
          (
            'Contact clicks',
            'Enquiry started',
            'The contact control is a link, not a tracked action.',
          ),
          (
            'Enquiries',
            'Message stored against a listing',
            'There is no enquiry table to write to.',
          ),
        ])
          div(classes: 'funnel__stage', [
            span(classes: 'funnel__name', [Component.text(stage.$1)]),
            span(classes: 'funnel__value', [Component.text('—')]),
            span(classes: 'funnel__def', [Component.text(stage.$2)]),
            span(classes: 'funnel__gap', [Component.text(stage.$3)]),
          ]),
      ]),
      p(classes: 'stat-note', [
        Component.text(
          'The reference product reports this funnel over up to 180 days, per '
          'listing or across all listings. Both windows become available once '
          'the events exist — the range is a query parameter, not a schema '
          'change.',
        ),
      ]),
    ]);
  }

  /// Review-state breakdown of the SAME assignment rows the dashboard counts.
  Component _byStatusCard(List<AgentAssignment> listings) {
    int count(String wire) =>
        listings.where((l) => AgentRecords.wireStatus(l) == wire).length;
    const states = ['approved', 'pending', 'under_review', 'draft', 'rejected'];
    return div(classes: 'bento-card', [
      div(classes: 'bento-card__head', [
        h3([Component.text('Portfolio by review state')]),
        span(classes: 'card-note', [Component.text('Real')]),
      ]),
      div(classes: 'aside-list', [
        for (final wire in states)
          AsideRow(
            badge: '${count(wire)}',
            tone: AgentRecords.wireStatusTone(wire) == 'success'
                ? 'teal'
                : 'blue',
            title: AgentRecords.wireStatusLabel(wire),
            caption: 'Operational listing state',
          ),
      ]),
    ]);
  }
}
