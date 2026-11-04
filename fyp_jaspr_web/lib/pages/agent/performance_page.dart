import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/dashboard_kit.dart';
import '../../components/ui.dart';
import '../../data/agent_records.dart';
import '../../layouts/app_layout.dart';

/// Agent performance.
///
/// The reference design puts an impressions → views → enquiries funnel here.
/// **This project captures none of those events**, so the funnel is drawn as
/// unfilled stages with the reason under each one, and the only numbers on the
/// page are arithmetic over the listing catalog that actually exists.
///
/// That split is the whole point of the page: a chart of invented views would
/// be indistinguishable from a real report to anyone reading a screenshot,
/// which is exactly the failure mode the brief warns about.
class AgentPerformancePage extends StatelessComponent {
  const AgentPerformancePage({super.key});

  @override
  Component build(BuildContext context) {
    return AppLayout(
      role: AppRole.agent,
      currentRoute: '/agent/performance',
      title: 'Performance',
      subtitle:
          'Portfolio figures are computed from the listing dataset. Engagement '
          'figures need events that are not captured yet.',
      eyebrow: 'Staff portal · agent',
      showPageHead: true,
      child: FutureBuilder<List<CommercialProperty>>(
        future: AgentRecords.assignedProperties(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return div(classes: 'loading', [
              span(classes: 'spinner', []),
              Component.text('Loading portfolio…'),
            ]);
          }
          final listings = snapshot.data!;
          return div(classes: 'stack', [
            _catalogKpis(listings),
            _funnelCard(),
            div(classes: 'bento', [
              _byStatusCard(listings),
              _prerequisitesCard(),
            ]),
          ]);
        },
      ),
    );
  }

  /// Arithmetic over real catalog rows — no invented metrics.
  Component _catalogKpis(List<CommercialProperty> listings) {
    if (listings.isEmpty) {
      return EmptyState(
        title: 'No listings to measure',
        body:
            'The demonstration assignment returned nothing, so there is no '
            'portfolio to average over.',
      );
    }
    final rents = listings.map((l) => l.rentalRm).toList();
    final sizes = listings.map((l) => l.sizeSqft).toList();
    final scores = listings.map((l) => l.suitabilityScore).toList();
    double avg(List<double> values) =>
        values.fold<double>(0, (sum, v) => sum + v) / values.length;
    return div(classes: 'bento-kpis', [
      _kpi('Listings held', '${listings.length}', 'Demonstration assignment'),
      _kpi('Median rent', _median(rents), 'From the imported dataset'),
      _kpi(
        'Average size',
        '${avg(sizes).toStringAsFixed(0)} sqft',
        'Across the portfolio',
      ),
      _kpi(
        'Mean suitability',
        avg(scores).toStringAsFixed(1),
        'Computed from the stored index',
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

  Component _byStatusCard(List<CommercialProperty> listings) {
    return div(classes: 'bento-card', [
      div(classes: 'bento-card__head', [
        h3([Component.text('Portfolio by review state')]),
        span(classes: 'card-note', [Component.text('Real')]),
      ]),
      div(classes: 'aside-list', [
        for (final status in VerificationStatus.values)
          AsideRow(
            badge: '${listings.where((l) => l.verification == status).length}',
            tone: status == VerificationStatus.verified ? 'teal' : 'blue',
            title: AgentRecords.listingLabel(status),
            caption: status.label,
          ),
      ]),
    ]);
  }

  Component _prerequisitesCard() {
    return div(classes: 'bento-card', [
      div(classes: 'bento-card__head', [
        h3([Component.text('What has to be recorded first')]),
        span(classes: 'card-note', [Component.text('Plan')]),
      ]),
      div(classes: 'aside-list', [
        for (final item in const [
          ('Event table', 'listing id, event type, timestamp, session.'),
          ('Attribution', 'Which agent held the listing when the event fired.'),
          (
            'Agent identity',
            'profiles.role must accept agent, plus an account.',
          ),
          (
            'Retention window',
            'How long events are kept defines the 180 days.',
          ),
        ])
          AsideRow(badge: '→', tone: 'blue', title: item.$1, caption: item.$2),
      ]),
    ]);
  }
}
