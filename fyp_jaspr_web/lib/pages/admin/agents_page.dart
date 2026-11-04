import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/dashboard_kit.dart';
import '../../components/ui.dart';
import '../../data/agent_records.dart';
import '../../data/app_locator.dart';
import '../../layouts/app_layout.dart';

/// Agent roster for an administrator.
///
/// ## The invite form is deliberately two fields
///
/// Name and work email — nothing else. The brief's rule is that an
/// administrative screen must never set or display an agent password: an
/// invited agent creates their own credential through the same Supabase flow
/// the other roles use. A "temporary password" input here would be the exact
/// anti-pattern, so it is absent rather than disabled.
///
/// ## What is not real
///
/// There is no agent account to list. `profiles.role` has a check constraint
/// accepting only `entrepreneur`, `owner` and `admin`, `agent_profiles` does not
/// exist, and `test/app-api.js` serves six routes, none of which can create an
/// agent. The roster row below is the demonstration identity, and the invite
/// action composes the request without sending it.
class AdminAgentsPage extends StatefulComponent {
  const AdminAgentsPage({super.key});

  @override
  State<AdminAgentsPage> createState() => _AdminAgentsPageState();
}

class _AdminAgentsPageState extends State<AdminAgentsPage> {
  bool _inviteOpen = false;
  String _name = '';
  String _email = '';

  /// Set once an invite is "sent". Nothing can actually send it, so the notice
  /// names what would have to exist — a drafted request is not a delivered
  /// email, and the page must not read as if one were.
  bool _drafted = false;

  void _closeInvite() => setState(() {
    _inviteOpen = false;
    _drafted = false;
    _name = '';
    _email = '';
  });

  String? get _nameError => _drafted && _name.trim().isEmpty
      ? 'Enter the name the agent will be listed under'
      : null;

  String? get _emailError {
    if (!_drafted) return null;
    final value = _email.trim();
    if (value.isEmpty) return 'A work email is required to address the invite';
    if (!value.contains('@') || !value.contains('.')) {
      return 'This does not look like an email address';
    }
    return null;
  }

  bool get _canDraft =>
      _name.trim().isNotEmpty &&
      _email.trim().isNotEmpty &&
      _email.contains('@') &&
      _email.contains('.');

  @override
  Component build(BuildContext context) {
    return AppLayout(
      role: AppRole.admin,
      currentRoute: '/admin/agents',
      title: 'Agents',
      eyebrow: 'Staff portal',
      subtitle:
          'Who may represent listings, what they hold, and the invite that '
          'would create the account.',
      actions: [
        ActionButton(
          'Invite agent',
          onClick: () => setState(() => _inviteOpen = true),
        ),
      ],
      child: div(classes: 'stack', [
        Callout(
          'Agent is a proposed role. No agent can sign in: the profiles table '
          'rejects the value, and there is no endpoint that could create one. '
          'This screen is the administrator workflow, built against the shape '
          'of the data it will need.',
          tone: 'warning',
        ),
        _roster(),
        div(classes: 'bento', [_requirementsCard(), _assignmentCard()]),
        if (_inviteOpen) _inviteDialog(),
      ]),
    );
  }

  Component _roster() {
    return SectionCard(
      title: 'Roster · 1 demonstration agent',
      flush: true,
      child: DataTable(
        columns: const [
          DataColumn('Agent'),
          DataColumn('Agency'),
          DataColumn('Reference'),
          DataColumn('Listings', numeric: true),
          DataColumn('Account'),
          DataColumn('Actions', actions: true),
        ],
        rows: [
          [
            CellIdentity(
              title: AgentRecords.agentName,
              caption: 'No email — no account exists to hold one',
            ),
            Component.text(AgentRecords.agentAgency),
            Component.text(AgentRecords.agentId),
            Component.text('${AgentRecords.assignmentCount}'),
            Pill('Not issued', tone: 'warning'),
            ActionLink('Open workspace', href: '/agent', variant: 'secondary'),
          ],
        ],
      ),
    );
  }

  Component _requirementsCard() {
    return div(classes: 'bento-card bento-wide', [
      div(classes: 'bento-card__head', [
        h3([Component.text('What an agent account requires')]),
        span(classes: 'card-note', [Component.text('Schema proposal')]),
      ]),
      DataTable(
        columns: const [
          DataColumn('Piece'),
          DataColumn('Currently'),
          DataColumn('Needed'),
        ],
        rows: [
          [
            Component.text('Role value'),
            Component.text('Rejected by a CHECK constraint'),
            Component.text('Migration widening profiles_role_check'),
          ],
          [
            Component.text('Agent profile'),
            Component.text('No table'),
            Component.text('agency, phone, account status'),
          ],
          [
            Component.text('Assignment'),
            Component.text('No relation'),
            Component.text('listing → agent → owner, with a status'),
          ],
          [
            Component.text('Authorisation'),
            Component.text(
              'POST /api/me upserts email only; a role claim cannot self-promote',
            ),
            Component.text(
              'Server-side check that the caller administers the target agency',
            ),
          ],
          [
            Component.text('Invitation delivery'),
            Component.text('Supabase signup is self-service'),
            Component.text('Admin-initiated invite link, no password set here'),
          ],
        ],
      ),
      p(classes: 'stat-note', [
        Component.text(
          'Proposed only — this build changes no schema and no backend file.',
        ),
      ]),
    ]);
  }

  /// The listing catalog is real, so the only honest number on this page is a
  /// count of it.
  Component _assignmentCard() {
    return div(classes: 'bento-card', [
      div(classes: 'bento-card__head', [
        h3([Component.text('Catalog coverage')]),
        span(classes: 'card-note', [Component.text('Live')]),
      ]),
      FutureBuilder<List<CommercialProperty>>(
        future: AppLocator.properties.listings(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return div(classes: 'dialog__loading', [
              Component.text('Loading catalog…'),
            ]);
          }
          final listings = snapshot.data!;
          final verified = listings
              .where((l) => l.verification == VerificationStatus.verified)
              .length;
          return div(classes: 'aside-list', [
            AsideRow(
              badge: '${listings.length}',
              tone: 'blue',
              title: 'Listings in the dataset',
              caption: 'Served by the authenticated catalog endpoint',
            ),
            AsideRow(
              badge: '$verified',
              tone: 'teal',
              title: 'Active',
              caption:
                  'Approved, and therefore assignable once the table exists',
            ),
            AsideRow(
              badge: '${AgentRecords.assignmentCount}',
              title: 'Held by the demonstration agent',
              caption: 'Chosen by rank in the browser, not granted by a server',
            ),
            AsideRow(
              badge: '0',
              tone: 'amber',
              title: 'Owners recorded against listings',
              caption: 'The dataset carries no ownership relation',
            ),
          ]);
        },
      ),
    ]);
  }

  Component _inviteDialog() {
    return SitewiseDialog(
      title: 'Invite an agent',
      ariaLabel: 'Invite an agent',
      onClose: _closeInvite,
      body: div(classes: 'stack', [
        p(classes: 'body', [
          Component.text(
            'Two fields, because two are all an invite needs. The agent sets '
            'their own password through the sign-up flow; no credential is '
            'created or shown here.',
          ),
        ]),
        Field(
          labelText: 'Full name',
          error: _nameError,
          hint: 'How the agent appears on the roster',
          child: input(
            type: InputType.text,
            attributes: {
              'placeholder': 'e.g. Aina Rahman',
              'autocomplete': 'name',
              'autofocus': '',
            },
            events: events<String>(
              onInput: (value) => setState(() => _name = value),
            ),
          ),
        ),
        Field(
          labelText: 'Work email',
          error: _emailError,
          hint: 'The invite is addressed here',
          child: input(
            type: InputType.email,
            attributes: {
              'placeholder': 'name@agency.my',
              'autocomplete': 'email',
            },
            events: events<String>(
              onInput: (value) => setState(() => _email = value),
            ),
          ),
        ),
        if (_drafted && _canDraft)
          ActionNotice(
            'Drafted in this browser only. Sending needs an admin-only invite '
            'endpoint and a Supabase invite call, neither of which exists, so '
            'no email has left this page.',
            tone: 'warn',
          ),
      ]),
      actions: [
        ActionButton('Cancel', onClick: _closeInvite, variant: 'secondary'),
        ActionButton(
          'Draft invite',
          onClick: () => setState(() => _drafted = true),
        ),
      ],
    );
  }
}
