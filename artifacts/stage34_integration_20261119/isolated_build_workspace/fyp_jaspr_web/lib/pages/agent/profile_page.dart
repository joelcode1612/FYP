import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/dashboard_kit.dart';
import '../../components/ui.dart';
import '../../data/agent_records.dart';
import '../../data/auth_service.dart';
import '../../data/workspaces.dart';
import '../../layouts/app_layout.dart';

/// Agent profile — the real signed-in identity, the real assignment count,
/// and the access model the backend actually enforces.
///
/// Nothing on this page is editable. The account comes from the verified
/// session ([WebAuth.profile]); the assigned-listing count comes from the
/// same `GET /api/v1/staff/me/listings` dataset as the dashboard and the
/// listings page. The Supabase `agent` profile (agent_id, agency) is resolved
/// server-side per request and is not editable from any web screen.
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
        span(classes: 'card-note', [Component.text('Verified session')]),
      ]),
      DataTable(
        columns: const [DataColumn('Field'), DataColumn('Value')],
        rows: [
          [
            Component.text('Email'),
            Component.text(
              account?['email']?.toString() ?? 'Not signed in',
            ),
          ],
          [
            Component.text('Server role'),
            Component.text(account?['role']?.toString() ?? '—'),
          ],
          [Component.text('Portal'), Component.text(AppRole.agent.portal)],
          [
            Component.text('Assigned listings'),
            _assignedCount(),
          ],
          [
            Component.text('Assignment source'),
            Component.text('Administrator-assigned, enforced server-side'),
          ],
        ],
      ),
      p(classes: 'stat-note', [
        Component.text(
          'The Supabase agent profile (agent id, agency) is resolved from the '
          'verified bearer token on every request; no screen can edit or '
          'reassign it.',
        ),
      ]),
    ]);
  }

  /// The real assignment count, or an explicit unavailable state — never a
  /// stand-in number.
  Component _assignedCount() {
    return FutureBuilder<List<AgentAssignment>>(
      future: AgentRecords.assignedListings(),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return Component.text('Loading…');
        }
        if (snapshot.hasError) {
          return const Pill('Unavailable', tone: 'warning');
        }
        final count = (snapshot.data ?? const []).length;
        return Component.text('$count');
      },
    );
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
        span(classes: 'card-note', [Component.text('Server-enforced')]),
      ]),
      div(classes: 'aside-list', [
        for (final item in const [
          (
            'Listings',
            'View and manage the listings assigned to you; edits are proposed '
                'for administrator review, never applied directly.',
          ),
          (
            'Owners',
            'Owner identity is shown when the operational record carries one.',
          ),
        ])
          AsideRow(badge: '·', title: item.$1, caption: item.$2),
      ]),
    ]);
  }

  /// The access model the backend actually enforces today.
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
            Pill('Available', tone: 'success'),
            Component.text('Agent-role accounts sign in with staff MFA.'),
          ],
          [
            Component.text('Invitation'),
            Pill('Available', tone: 'success'),
            Component.text(
              'Issued from the administrator agent directory.',
            ),
          ],
          [
            Component.text('Write access to a listing'),
            Pill('Via review', tone: 'action'),
            Component.text(
              'Agents propose changes; an administrator approves them before '
              'the operational row changes.',
            ),
          ],
        ],
      ),
    ]);
  }
}
