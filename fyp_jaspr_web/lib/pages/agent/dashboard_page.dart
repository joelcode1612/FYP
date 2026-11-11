import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/dashboard_kit.dart';
import '../../components/letter_reveal.dart';
import '../../components/ui.dart';
import '../../data/admin_api.dart';
import '../../data/agent_records.dart';
import '../../layouts/app_layout.dart';

/// Agent workspace home.
///
/// Every number on this page derives from the SAME authorized assignment
/// dataset as Assigned Listings: `GET /api/v1/staff/me/listings`, which
/// resolves the authenticated agent's profile server-side and returns the
/// `agent_listing_assignment` rows (real foreign keys to
/// `fyp.rental_properties`) joined with the operational property fields in
/// one query. The former suitability-rank demonstration portfolio is gone.
///
/// Status wording: "Active" = the listing passed administrator review
/// (`verification_status = approved`). Publication (`is_published`) is a
/// separate flag and is never inferred from approval.
///
/// Layout reuses the app's bento grid (`.bento-head` / `.bento-kpis` /
/// `.bento`) so the agent shell is the same object as the admin and owner
/// shells rather than a fourth one-off.
@client
class AgentDashboardPage extends StatelessComponent {
  const AgentDashboardPage({super.key});

  @override
  Component build(BuildContext context) {
    return AppLayout(
      role: AppRole.agent,
      currentRoute: '/agent',
      title: 'Assigned portfolio',
      showPageHead: false,
      child: FutureBuilder<List<AgentAssignment>>(
        future: AgentRecords.assignedListings(),
        builder: (context, snapshot) {
          // A failed request and a genuinely empty portfolio must stay
          // distinguishable: the error card never collapses into zeros.
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
            _head(listings.length),
            // Zeros are truthful when nothing is assigned; the strip is
            // always rendered so "0" is visible rather than implied.
            _kpis(listings),
            if (listings.isEmpty)
              _noAssignments()
            else
              div(classes: 'bento', [
                _portfolioCard(listings),
                _verificationCard(listings),
              ]),
          ]);
        },
      ),
    );
  }

  Component _head(int count) {
    final sub = count == 0
        ? 'No listings are assigned to your account yet.'
        : 'The listings you handle, their review state and what is waiting '
            'for an administrator. $count ${count == 1 ? 'unit' : 'units'} '
            'assigned to you.';
    return div(classes: 'bento-head', [
      div(classes: 'bh-title', [
        span(classes: 'eyebrow-sm', [Component.text('Staff portal · agent')]),
        LetterRevealHeading.text('Assigned portfolio', level: 1),
        p(classes: 'muted', [Component.text(sub)]),
      ]),
      div(classes: 'bh-actions', [
        AppLink(
          to: '/agent/listings',
          classes: 'bento-cta',
          children: [Component.text('Manage listings')],
        ),
      ]),
    ]);
  }

  Component _noAssignments() {
    return SectionCard(
      title: 'Portfolio overview',
      child: EmptyState(
        title: 'No properties assigned yet.',
        body:
            'An administrator has not assigned any properties to your '
            'account. Once one is assigned, it appears here and on the '
            'Assigned Listings page with the same details.',
        action: AppLink(
          to: '/agent/listings',
          classes: 'text-action',
          children: [Component.text('Open Assigned Listings')],
        ),
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
      const ActionLink('Retry', href: '/agent', variant: 'secondary'),
    ]);
  }

  Component _kpis(List<AgentAssignment> listings) {
    String count(String? wire) =>
        '${listings.where((l) => AgentRecords.wireStatus(l) == wire).length}';
    return div(classes: 'bento-kpis', [
      _kpi(
        'Assigned listings',
        '${listings.length}',
        'From your administrator\u2019s assignments',
      ),
      _kpi(
        'Active',
        count('approved'),
        'Passed administrator review',
      ),
      _kpi(
        'Pending review',
        count('pending'),
        'Awaiting an administrator',
      ),
      _kpi(
        'Draft or suspended',
        '${listings.where((l) => AgentRecords.wireStatus(l) == 'draft' || AgentRecords.wireStatus(l) == 'rejected').length}',
        'Not live on the public site',
      ),
    ]);
  }

  Component _kpi(String k, String v, String n) => div(classes: 'kpi', [
    span(classes: 'k', [Component.text(k)]),
    span(classes: 'v', [Component.text(v)]),
    span(classes: 'n', [Component.text(n)]),
  ]);

  /// The assigned units as records rather than cards: an agent works a queue,
  /// so the table gets the widest cell and links straight into the record.
  Component _portfolioCard(List<AgentAssignment> listings) {
    return div(classes: 'bento-card bento-wide', [
      div(classes: 'bento-card__head', [
        h3([Component.text('Portfolio overview')]),
        AppLink(
          to: '/agent/listings',
          classes: 'card-note',
          children: [Component.text('Open in Assigned Listings')],
        ),
      ]),
      DataTable(
        columns: const [
          DataColumn('Property'),
          DataColumn('Location'),
          DataColumn('Status'),
          DataColumn('Rent', numeric: true),
          DataColumn('Listing id', numeric: true),
          DataColumn('Manage', actions: true),
        ],
        rows: [
          for (final assignment in listings)
            [
              CellIdentity(
                title: assignment.displayTitle.isEmpty
                    ? 'Listing ${assignment.displayId}'
                    : assignment.displayTitle,
                caption: AgentRecords.propertyExists(assignment)
                    ? AgentRecords.typeDisplay(assignment)
                    : 'Operational record missing',
              ),
              Component.text(AgentRecords.locationDisplay(assignment)),
              Pill(
                AgentRecords.wireStatusLabel(AgentRecords.wireStatus(assignment)),
                tone: AgentRecords.wireStatusTone(AgentRecords.wireStatus(assignment)),
              ),
              Component.text(AgentRecords.rentDisplay(assignment)),
              Component.text('${assignment.listingId}'),
              AppLink(
                to: '/agent/property-detail?id=${assignment.listingId}',
                classes: 'text-action',
                children: [Component.text('Manage')],
              ),
            ],
        ],
        emptyLabel: 'No properties are assigned to your account yet.',
      ),
    ]);
  }

  /// Pending property verification, driven by the same assignment rows as
  /// every other panel on this page. When the queue is empty the panel says
  /// so instead of padding itself with rows that do not exist.
  Component _verificationCard(List<AgentAssignment> listings) {
    final pending = listings
        .where((l) => AgentRecords.wireStatus(l) == 'pending')
        .toList();
    return div(classes: 'bento-card', [
      div(classes: 'bento-card__head', [
        h3([Component.text('Pending verification')]),
        span(classes: 'card-note', [
          Component.text('${pending.length} waiting'),
        ]),
      ]),
      if (pending.isEmpty)
        EmptyState(
          title: 'Nothing awaiting review',
          body:
              'No assigned listing currently sits in the pending state, so '
              'there is no verification queue to work through.',
        )
      else
        div(classes: 'aside-list', [
          for (final assignment in pending)
            AsideRow(
              badge: '!',
              tone: 'warning',
              title: assignment.displayTitle.isEmpty
                  ? 'Listing ${assignment.displayId}'
                  : assignment.displayTitle,
              caption:
                  '${AgentRecords.locationDisplay(assignment)} · '
                  '${AgentRecords.typeDisplay(assignment)}',
              end: Pill(
                AgentRecords.wireStatusLabel(AgentRecords.wireStatus(assignment)),
                tone: AgentRecords.wireStatusTone(AgentRecords.wireStatus(assignment)),
              ),
            ),
        ]),
    ]);
  }
}
