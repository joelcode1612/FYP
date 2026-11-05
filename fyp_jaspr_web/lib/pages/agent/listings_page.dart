import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/dashboard_kit.dart';
import '../../components/ui.dart';
import '../../data/agent_records.dart';
import '../../layouts/app_layout.dart';

/// Agent listing management — the workspace's main work surface.
///
/// Modelled on PropertyGuru's AgentNet listing tabs (Active / Draft / Past /
/// Suspended), but filtered through what Sitewise actually stores:
///
/// * Active, Draft and Suspended map onto `VerificationStatus.verified`,
///   `.draft` and `.rejected`.
/// * **Past has no counterpart.** Listings here have no expiry field, so the
///   tab is named in the footnote rather than presented as an empty filter a
///   user would read as "no expiring listings" when the truth is "this system
///   does not track expiry".
///
/// Editing is deliberately absent. `ApiPropertyRepository` throws
/// `UnsupportedError` from `updateProperty`, and agent write-authorisation is a
/// server-side decision that does not exist yet — so the row actions navigate
/// to a read-only record instead of offering a form that cannot save.
@client
class AgentListingsPage extends StatefulComponent {
  const AgentListingsPage({super.key});

  @override
  State<AgentListingsPage> createState() => _AgentListingsPageState();
}

class _AgentListingsPageState extends State<AgentListingsPage> {
  /// `all` plus the [VerificationStatus] names the tabs filter on.
  String _tab = 'all';
  String _query = '';

  List<CommercialProperty> _matching(List<CommercialProperty> source) {
    final q = _query.toLowerCase();
    return source.where((property) {
      final tabOk = switch (_tab) {
        'all' => true,
        'verified' => property.verification == VerificationStatus.verified,
        'draft' => property.verification == VerificationStatus.draft,
        'rejected' => property.verification == VerificationStatus.rejected,
        _ => property.verification == VerificationStatus.pending,
      };
      final queryOk =
          q.isEmpty ||
          '${property.title} ${property.city} ${property.address} '
                  '${property.id}'
              .toLowerCase()
              .contains(q);
      return tabOk && queryOk;
    }).toList();
  }

  @override
  Component build(BuildContext context) {
    return AppLayout(
      role: AppRole.agent,
      currentRoute: '/agent/listings',
      title: 'Assigned listings',
      subtitle:
          'Every unit this agent handles, filterable by the state an '
          'administrator can move it to.',
      eyebrow: 'Staff portal · agent',
      showPageHead: true,
      child: FutureBuilder<List<CommercialProperty>>(
        future: AgentRecords.assignedProperties(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return div(classes: 'loading', [
              span(classes: 'spinner', []),
              Component.text('Loading listings…'),
            ]);
          }
          final all = snapshot.data!;
          final rows = _matching(all);
          return div(classes: 'stack', [
            _tabs(all),
            SearchInput(
              ariaLabel: 'Search assigned listings',
              placeholder: 'Search by listing name, location or id…',
              onInput: (value) => setState(() => _query = value),
            ),
            SectionCard(
              title: '${rows.length} of ${all.length} listings',
              flush: true,
              child: DataTable(
                columns: const [
                  DataColumn('Listing'),
                  DataColumn('Status'),
                  DataColumn('Type'),
                  DataColumn('Size', numeric: true),
                  DataColumn('Rent', numeric: true),
                  DataColumn('Score', numeric: true),
                  DataColumn('Actions', actions: true),
                ],
                rows: [
                  for (final property in rows)
                    [
                      CellIdentity(
                        title: property.title,
                        caption:
                            '${property.address}, ${property.city} '
                            '${property.postcode}',
                      ),
                      Pill(
                        AgentRecords.listingLabel(property.verification),
                        tone: AgentRecords.listingTone(property.verification),
                      ),
                      Component.text(property.propertyType),
                      Component.text(
                        '${property.sizeSqft.toStringAsFixed(0)} sqft',
                      ),
                      Component.text(property.rentalDisplay),
                      Component.text(
                        property.suitabilityScore.toStringAsFixed(0),
                      ),
                      AppLink(
                        to: '/agent/property-detail?id=${property.id}',
                        classes: 'text-action',
                        children: [Component.text('View')],
                      ),
                    ],
                ],
                emptyLabel: _query.isEmpty
                    ? 'No listing sits in this state.'
                    : 'Nothing matches “$_query” in this state.',
              ),
            ),
            Callout(
              'Tab names follow the agent workflow in the reference product. '
              '“Past” is not offered: nothing in this dataset records a '
              'listing expiry, and an empty tab would read as a fact about '
              'the listings rather than about the missing field.',
              icon: 'info',
            ),
          ]);
        },
      ),
    );
  }

  Component _tabs(List<CommercialProperty> all) {
    int count(VerificationStatus? status) => status == null
        ? all.length
        : all.where((l) => l.verification == status).length;
    return div(classes: 'tabs', [
      _tabButton('all', 'All', count(null)),
      _tabButton('verified', 'Active', count(VerificationStatus.verified)),
      _tabButton('draft', 'Draft', count(VerificationStatus.draft)),
      _tabButton(
        'pending',
        'Pending review',
        count(VerificationStatus.pending),
      ),
      _tabButton('rejected', 'Suspended', count(VerificationStatus.rejected)),
    ]);
  }

  Component _tabButton(String key, String label, int count) {
    final selected = _tab == key;
    return button(
      classes: 'tab',
      attributes: {
        'type': 'button',
        // `.tab[aria-selected="true"]` carries the active state; a page-level
        // `aria-current` would be wrong for a filter that is not a location.
        'aria-selected': selected ? 'true' : 'false',
      },
      events: events(onClick: () => setState(() => _tab = key)),
      [
        Component.text('$label '),
        span(classes: 'tab__count', [Component.text('$count')]),
      ],
    );
  }
}
