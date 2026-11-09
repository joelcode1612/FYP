import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/dashboard_kit.dart';
import '../../components/letter_reveal.dart';
import '../../components/ui.dart';
import '../../data/agent_records.dart';
import '../../layouts/app_layout.dart';

/// Agent workspace home.
///
/// ## Why this page is a prototype and says so out loud
///
/// `profiles.role` has a database check constraint accepting only
/// `entrepreneur`, `owner` and `admin`; there is no agent table, no
/// `property_assignments` relation and no endpoint that could authorise one.
/// So this workspace is built from the **real** listing catalog with a
/// stand-in assignment rule, and every card that depends on the missing
/// relations names the gap instead of hiding it. That is the brief's rule:
/// show the shape of the workflow, never imply the backend enforces it.
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
      child: FutureBuilder<List<CommercialProperty>>(
        future: AgentRecords.assignedProperties(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return div(classes: 'loading', [
              span(classes: 'spinner', []),
              Component.text('Loading assigned listings…'),
            ]);
          }
          final listings = snapshot.data!;
          return div(classes: 'stack', [
            _head(listings.length),
            Callout(
              'Agent is a proposed capability. The catalog, prices and areas '
              'below are the imported dataset; which listings are "assigned" '
              'to this agent is a demonstration rule that lives in this '
              'browser only — no agent account or assignment table exists yet.',
              tone: 'warning',
            ),
            _kpis(listings),
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
    return div(classes: 'bento-head', [
      div(classes: 'bh-title', [
        span(classes: 'eyebrow-sm', [Component.text('Staff portal · agent')]),
        LetterRevealHeading.text('Assigned portfolio', level: 1),
        p(classes: 'muted', [
          Component.text(
            'The listings this agent handles, their review state and what is '
            'waiting for an administrator. $count units in the demonstration '
            'portfolio.',
          ),
        ]),
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

  Component _kpis(List<CommercialProperty> listings) {
    String count(VerificationStatus status) =>
        '${listings.where((l) => l.verification == status).length}';
    return div(classes: 'bento-kpis', [
      _kpi(
        'Assigned listings',
        '${listings.length}',
        'Demonstration portfolio',
      ),
      _kpi(
        'Active',
        count(VerificationStatus.verified),
        'Approved for display',
      ),
      _kpi(
        'Pending review',
        count(VerificationStatus.pending),
        'Awaiting an administrator',
      ),
      _kpi(
        'Draft or suspended',
        '${listings.where((l) => l.verification == VerificationStatus.draft || l.verification == VerificationStatus.rejected).length}',
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
  Component _portfolioCard(List<CommercialProperty> listings) {
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
          DataColumn('Detail', actions: true),
        ],
        rows: [
          for (final property in listings)
            [
              CellIdentity(
                title: property.title,
                caption: property.propertyType,
              ),
              Component.text(property.city),
              Pill(
                AgentRecords.listingLabel(property.verification),
                tone: AgentRecords.listingTone(property.verification),
              ),
              Component.text(property.rentalDisplay),
              AppLink(
                to: '/agent/property-detail?id=${property.id}',
                classes: 'text-action',
                children: [Component.text('View')],
              ),
            ],
        ],
      ),
    ]);
  }

  /// Pending property verification, driven by the real catalog states. When
  /// the queue is empty the panel says so instead of padding itself with rows
  /// that do not exist — the same honesty rule the old performance card used.
  Component _verificationCard(List<CommercialProperty> listings) {
    final pending = listings
        .where((l) => l.verification == VerificationStatus.pending)
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
          for (final property in pending)
            AsideRow(
              badge: '!',
              tone: 'warning',
              title: property.title,
              caption: '${property.city} · ${property.propertyType}',
              end: Pill(
                AgentRecords.listingLabel(property.verification),
                tone: AgentRecords.listingTone(property.verification),
              ),
            ),
        ]),
    ]);
  }
}
