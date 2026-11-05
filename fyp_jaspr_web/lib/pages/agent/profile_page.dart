import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/dashboard_kit.dart';
import '../../components/ui.dart';
import '../../data/agent_records.dart';
import '../../data/auth_service.dart';
import '../../data/workspaces.dart';
import '../../layouts/app_layout.dart';

/// Agent profile — identity an administrator would issue, and what the backend
/// can actually confirm about it today.
///
/// Nothing on this page is editable. There is no agent row to write to, and
/// `/api/me` upserts only the email and role of the signed-in Supabase user, so
/// a form here would accept input it cannot store. The account panel therefore
/// reports the real session and names the gap, rather than rendering disabled
/// fields that imply an eventual save.
@client
class AgentProfilePage extends StatelessComponent {
  const AgentProfilePage({super.key});

  @override
  Component build(BuildContext context) {
    final account = WebAuth.profile;
    return AppLayout(
      role: AppRole.agent,
      currentRoute: '/agent/profile',
      title: 'Agent profile',
      subtitle:
          'Who is working, which listings they hold, and what the '
          'account can currently be proven to be.',
      eyebrow: 'Staff portal · agent',
      actions: [
        ActionLink(
          'Assigned listings',
          href: '/agent/listings',
          variant: 'secondary',
        ),
      ],
      child: div(classes: 'stack', [
        Callout(
          'An agent sign-in does not exist yet: the profiles table rejects the '
          'role and no agent accounts have been issued. The identity shown '
          'here is the demonstration one; the session below is the real one.',
          tone: 'warning',
        ),
        div(classes: 'bento', [
          _identityCard(account),
          _accessCard(account),
          _portfolioCard(),
          _securityCard(),
        ]),
      ]),
    );
  }

  Component _identityCard(Map<String, dynamic>? account) {
    return div(classes: 'bento-card bento-wide', [
      div(classes: 'bento-card__head', [
        h3([Component.text('Agent identity')]),
        span(classes: 'card-note', [Component.text('Demonstration')]),
      ]),
      DataTable(
        columns: const [DataColumn('Field'), DataColumn('Value')],
        rows: [
          [Component.text('Agent id'), Component.text(AgentRecords.agentId)],
          [Component.text('Name'), Component.text(AgentRecords.agentName)],
          [Component.text('Agency'), Component.text(AgentRecords.agentAgency)],
          [Component.text('Portal'), Component.text(AppRole.agent.portal)],
          [
            Component.text('Assigned listings'),
            Component.text(
              '${AgentRecords.assignmentCount} (rank-selected from the '
              'catalog, not granted by a server)',
            ),
          ],
          [
            Component.text('Account status'),
            Pill('Not issued', tone: 'warning'),
          ],
        ],
      ),
      if (account != null)
        p(classes: 'stat-note', [
          Component.text(
            'Signed in as ${account['email']} with the server-assigned role '
            '“${account['role']}”. That role, not the panel above, is what '
            'the API authorises.',
          ),
        ]),
    ]);
  }

  Component _accessCard(Map<String, dynamic>? account) {
    final primary = Workspaces.primary;
    return div(classes: 'bento-card', [
      div(classes: 'bento-card__head', [
        h3([Component.text('Workspaces open to this account')]),
        span(classes: 'card-note', [Component.text('Session')]),
      ]),
      div(classes: 'aside-list', [
        for (final role in Workspaces.openable)
          AsideRow(
            badge: role.label.substring(0, 1),
            tone: role == primary ? 'teal' : 'blue',
            title: role.label,
            caption: role.portal,
            end: Pill(role == primary ? 'Assigned' : 'Demo grant'),
          ),
        if (Workspaces.openable.length <= 1)
          AsideRow(
            badge: '?',
            title: 'No second workspace',
            caption:
                'The backend assigns exactly one role per account, so nothing '
                'else can be opened.',
          ),
      ]),
      if (account == null)
        p(classes: 'stat-note', [
          Component.text(
            'This page is being read without a signed-in session — the '
            'workspace list above is empty because no role was assigned.',
          ),
        ]),
    ]);
  }

  Component _portfolioCard() {
    return div(classes: 'bento-card', [
      div(classes: 'bento-card__head', [
        h3([Component.text('Handling')]),
        span(classes: 'card-note', [Component.text('Read-only')]),
      ]),
      div(classes: 'aside-list', [
        for (final item in const [
          ('Listings', 'View and filter; no edit is authorised.'),
          ('Enquiries', 'Prototype inbox; nothing is stored.'),
          ('Performance', 'Catalog arithmetic; no events captured.'),
          ('Owners', 'The dataset records no ownership relation.'),
        ])
          AsideRow(badge: '·', title: item.$1, caption: item.$2),
      ]),
    ]);
  }

  /// The rule the brief states outright, kept visible on the page where an
  /// administrator might otherwise expect a credential field.
  Component _securityCard() {
    return div(classes: 'bento-card bento-wide', [
      div(classes: 'bento-card__head', [
        h3([Component.text('Credentials')]),
        span(classes: 'card-note', [Component.text('Policy')]),
      ]),
      Callout(
        'Agent accounts are invited, never self-registered, and no password is '
        'created or shown from any administrative screen. An invited agent sets '
        'their own credential through the same Supabase flow the other roles '
        'use — so this page has no password field to fill in.',
        tone: 'info',
        icon: 'lock',
      ),
      DataTable(
        columns: const [
          DataColumn('Capability'),
          DataColumn('Status'),
          DataColumn('Why'),
        ],
        rows: [
          [
            Component.text('Agent sign-in'),
            Pill('Not available', tone: 'warning'),
            Component.text('profiles.role rejects the value "agent".'),
          ],
          [
            Component.text('Invitation'),
            Pill('Planned', tone: 'neutral'),
            Component.text(
              'An access_requests row plus a Supabase invite would carry it.',
            ),
          ],
          [
            Component.text('Write access to a listing'),
            Pill('Blocked', tone: 'danger'),
            Component.text(
              'The repository throws on update; assignment does not exist.',
            ),
          ],
        ],
      ),
    ]);
  }
}
