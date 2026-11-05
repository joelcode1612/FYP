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
              _tasksCard(),
              _enquiriesCard(),
              _performanceCard(),
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
            'waiting for a response. $count units in the demonstration portfolio.',
          ),
        ]),
      ]),
      div(classes: 'bh-actions', [
        AppLink(
          to: '/agent/listings',
          classes: 'bento-cta',
          children: [Component.text('Manage listings')],
        ),
        AppLink(
          to: '/agent/enquiries',
          classes: 'bento-period',
          children: [Component.text('Open enquiries')],
        ),
        AppLink(
          to: '/agent/performance',
          classes: 'bento-period',
          children: [Component.text('View performance')],
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
        'New enquiries',
        '${demoEnquiries.where((e) => e.status == 'New').length}',
        'Not stored — see the enquiries page',
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
        h3([Component.text('Listings needing attention')]),
        AppLink(
          to: '/agent/listings',
          classes: 'card-note',
          children: [Component.text('See all')],
        ),
      ]),
      DataTable(
        columns: const [
          DataColumn('Listing'),
          DataColumn('Status'),
          DataColumn('Owner'),
          DataColumn('Rent', numeric: true),
          DataColumn('Open', actions: true),
        ],
        rows: [
          for (final property in listings.take(4))
            [
              CellIdentity(
                title: property.title,
                caption: '${property.city} · ${property.propertyType}',
              ),
              Pill(
                AgentRecords.listingLabel(property.verification),
                tone: AgentRecords.listingTone(property.verification),
              ),
              Component.text(AgentRecords.ownerLabel(property)),
              Component.text(property.rentalDisplay),
              AppLink(
                to: '/agent/property-detail?id=${property.id}',
                classes: 'text-action',
                children: [Component.text('Open')],
              ),
            ],
        ],
      ),
    ]);
  }

  Component _tasksCard() {
    final tasks = demoTasks();
    return div(classes: 'bento-card', [
      div(classes: 'bento-card__head', [
        h3([Component.text('Today')]),
        span(classes: 'card-note', [Component.text('Prototype')]),
      ]),
      div(classes: 'aside-list', [
        for (var i = 0; i < tasks.length; i++)
          AsideRow(
            badge: tasks[i].done ? '✓' : '${i + 1}',
            tone: tasks[i].done ? 'teal' : 'blue',
            title: tasks[i].title,
            caption: tasks[i].detail,
            end: Pill(tasks[i].status),
          ),
      ]),
      p(classes: 'stat-note', [
        Component.text(
          'No task model exists in the domain layer, so these are static rows '
          'that describe the work the missing storage would create.',
        ),
      ]),
    ]);
  }

  Component _enquiriesCard() {
    return div(classes: 'bento-card', [
      div(classes: 'bento-card__head', [
        h3([Component.text('Latest enquiries')]),
        AppLink(
          to: '/agent/enquiries',
          classes: 'card-note',
          children: [Component.text('See all')],
        ),
      ]),
      div(classes: 'aside-list', [
        for (final enquiry in demoEnquiries.take(3))
          AsideRow(
            badge: enquiry.enquirer.substring(0, 1).toUpperCase(),
            tone: enquiry.status == 'New' ? 'blue' : 'neutral',
            title: enquiry.enquirer,
            caption: enquiry.property,
            end: Pill(
              enquiry.status,
              tone: switch (enquiry.status) {
                'New' => 'action',
                'Closed' => 'neutral',
                _ => 'warning',
              },
            ),
          ),
      ]),
    ]);
  }

  /// Performance is deliberately empty.
  ///
  /// The reference design shows a views chart; nothing in this project records
  /// an impression or a view, so drawing bars would be inventing the numbers
  /// the brief forbids. The card states what would have to be captured first.
  Component _performanceCard() {
    return div(classes: 'bento-card bento-wide', [
      div(classes: 'bento-card__head', [
        h3([Component.text('Listing performance')]),
        AppLink(
          to: '/agent/performance',
          classes: 'card-note',
          children: [Component.text('Details')],
        ),
      ]),
      EmptyState(
        title: 'No interaction events are tracked',
        body:
            'Impressions, views and contact clicks would need to be stored '
            'before a funnel can be drawn. Until then this page shows what '
            'would be measured rather than a chart of numbers that do not '
            'exist.',
        action: ActionLink(
          'See the proposed metrics',
          href: '/agent/performance',
        ),
      ),
    ]);
  }
}
