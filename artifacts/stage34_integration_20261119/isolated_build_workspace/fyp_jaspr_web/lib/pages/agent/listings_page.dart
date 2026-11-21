import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/dashboard_kit.dart';
import '../../components/ui.dart';
import '../../data/admin_api.dart';
import '../../data/agent_records.dart';
import '../../layouts/app_layout.dart';

/// Agent listing management — the workspace's main work surface.
///
/// The rows are the agent's REAL assignments: `GET /api/v1/staff/me/listings`
/// resolves the Supabase assignment records from the verified bearer token
/// server-side, so an agent can never see (or reach by editing the URL) a
/// listing that was not assigned to them. The former suitability-rank
/// selection survives only on the dashboard/performance displays, which label
/// themselves as demonstration data.
///
/// Assignment rows carry the numeric listing id (the operational
/// `fyp.rental_properties` id) and a display title — the verification state
/// lives on the operational record and is shown on the management page, so no
/// per-row status pill is fabricated here.
@client
class AgentListingsPage extends StatefulComponent {
  const AgentListingsPage({super.key});

  @override
  State<AgentListingsPage> createState() => _AgentListingsPageState();
}

class _AgentListingsPageState extends State<AgentListingsPage> {
  String _query = '';

  List<AgentAssignment> _matching(List<AgentAssignment> source) {
    final q = _query.toLowerCase();
    if (q.isEmpty) return source;
    return source.where((assignment) {
      final hay =
          '${assignment.displayTitle} ${assignment.displayId} '
          '${assignment.raw['city'] ?? ''}';
      return hay.toLowerCase().contains(q);
    }).toList();
  }

  @override
  Component build(BuildContext context) {
    return AppLayout(
      role: AppRole.agent,
      currentRoute: '/agent/listings',
      title: 'Assigned listings',
      subtitle:
          'Every unit an administrator assigned to you, with its management '
          'workspace one click away.',
      eyebrow: 'Staff portal · agent',
      showPageHead: true,
      child: FutureBuilder<List<AgentAssignment>>(
        future: AgentRecords.assignedListings(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return snapshot.connectionState == ConnectionState.done
                ? _errorState(snapshot.error)
                : div(classes: 'loading', [
                    span(classes: 'spinner', []),
                    Component.text('Loading assignments…'),
                  ]);
          }
          final all = snapshot.data!;
          final rows = _matching(all);
          return div(classes: 'stack', [
            SearchInput(
              ariaLabel: 'Search assigned listings',
              placeholder: 'Search by listing name or id…',
              onInput: (value) => setState(() => _query = value),
            ),
            SectionCard(
              title: '${rows.length} of ${all.length} assigned listings',
              flush: true,
              child: DataTable(
                columns: const [
                  DataColumn('Listing'),
                  DataColumn('Listing id', numeric: true),
                  DataColumn('Actions', actions: true),
                ],
                rows: [
                  for (final assignment in rows)
                    [
                      CellIdentity(
                        title: assignment.displayTitle.isEmpty
                            ? 'Listing ${assignment.displayId}'
                            : assignment.displayTitle,
                        caption:
                            assignment.raw['city'] is String &&
                                (assignment.raw['city'] as String).isNotEmpty
                            ? assignment.raw['city'] as String
                            : 'Assigned by an administrator',
                      ),
                      Component.text('${assignment.listingId}'),
                      AppLink(
                        to: '/agent/property-detail?id=${assignment.listingId}',
                        classes: 'text-action',
                        children: [Component.text('Manage')],
                      ),
                    ],
                ],
                emptyLabel: _query.isEmpty
                    ? 'No listings are assigned to your account yet. An '
                          'administrator assigns listings from the agent '
                          'directory.'
                    : 'Nothing matches “$_query”.',
              ),
            ),
            const Callout(
              '“Manage” opens the property management workspace: overview, '
              'draft editing, media, activity and the administrator review '
              'state of that one listing. Authorization is re-checked by the '
              'backend on every call.',
              icon: 'info',
            ),
          ]);
        },
      ),
    );
  }

  Component _errorState(Object? error) {
    return div(classes: 'card stack', [
      span(classes: 'title', [Component.text('Could not load assignments')]),
      p(classes: 'body muted', [
        Component.text(
          error == null
              ? 'The backend did not answer.'
              : AdminApi.message(error),
        ),
      ]),
      const ActionLink('Retry', href: '/agent/listings', variant: 'secondary'),
    ]);
  }
}
