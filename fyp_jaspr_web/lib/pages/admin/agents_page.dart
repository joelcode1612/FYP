import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';
import 'package:universal_web/web.dart' as web;

import '../../components/admin_ops_kit.dart';
import '../../components/dashboard_kit.dart';
import '../../components/ui.dart';
import '../../data/admin_api.dart';
import '../../data/app_locator.dart';
import '../../layouts/app_layout.dart';

/// Agent management — the administrator's live staff roster.
///
/// ## What is real
///
/// Every control on this page drives an existing backend route
/// (`backend/src/sitewise/api/v1/staff.py`), all guarded by **administrator +
/// MFA (`aal2`)** on the server, all recorded in `role_change_audit`:
///
/// * `GET  /api/v1/staff/agents` — roster (local enforcement mirror merged
///   with the Supabase `agent` profile),
/// * `POST /api/v1/staff/agents` — invite: creates the Supabase identity and
///   emails the native password-setup link. **No password is ever typed or
///   displayed here** — the agent chooses their own credential, which is why
///   the form has name/email/company/phone and nothing else.
/// * `PATCH /api/v1/staff/agents/{id}/status` — suspend / activate /
///   reactivate. The backend rejects no-ops with 409, so entries never
///   pretend a change stuck when it did not.
/// * `GET  /api/v1/staff/invitations` — Supabase invite tracking.
///
/// Failures surface as the backend's own sentence (the 409 that asks for
/// `allow_existing=true`, an identity-collision notice, the structured MFA
/// refusal) — never as a fabricated success and never as a silent retry. The
/// previous build's demo roster and stale "no agent role exists" callout are
/// gone: `public.agent`, the `agent` role value and the invitation flow are
/// all live.
@client
class AdminAgentsPage extends StatefulComponent {
  const AdminAgentsPage({super.key});

  @override
  State<AdminAgentsPage> createState() => _AdminAgentsPageState();
}

class _AdminAgentsPageState extends State<AdminAgentsPage> {
  bool _loading = true;
  String? _error;
  List<StaffAgent> _agents = const [];
  List<StaffInvitation> _invitations = const [];
  String _query = '';

  /// Row currently awaiting a suspend confirmation (id of the account).
  String? _confirmingId;

  /// `busyId` — the row whose PATCH is in flight (disables its buttons).
  String? _busyId;

  /// Success or failure of the last mutation, shown over the roster.
  String? _notice;
  bool _noticeError = false;

  // --- Invite dialog state --------------------------------------------------
  bool _inviteOpen = false;
  String _invName = '';
  String _invEmail = '';
  String _invCompany = '';
  String _invPhone = '';
  bool _allowExisting = false;
  bool _submitting = false;
  String? _inviteError;
  String? _inviteSuccess;
  bool _validated = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final results = await Future.wait([
        AppLocator.adminApi.listAgents(),
        AppLocator.adminApi.listInvitations(),
      ]);
      if (!mounted) return;
      setState(() {
        _agents = results[0].cast<StaffAgent>();
        _invitations = results[1].cast<StaffInvitation>();
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = AdminApi.message(error);
      });
    }
  }

  List<StaffAgent> get _filtered {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return _agents;
    return _agents
        .where(
          (agent) =>
              '${agent.displayName} ${agent.email} ${agent.status} '
                      '${agent.agentId}'
                  .toLowerCase()
                  .contains(q),
        )
        .toList(growable: false);
  }

  // --- Mutations ------------------------------------------------------------

  void _setNotice(String text, {required bool error}) {
    setState(() {
      _notice = text;
      _noticeError = error;
    });
  }

  Future<void> _setStatus(StaffAgent agent, String status) async {
    final label = switch (status) {
      'active' => 'reactivated',
      'suspended' => 'suspended',
      _ => 'updated',
    };
    setState(() => _busyId = agent.userId);
    try {
      await AppLocator.adminApi.setAgentStatus(agent.userId, status);
      await _load(silent: true);
      if (!mounted) return;
      setState(() => _confirmingId = null);
      _setNotice(
        '${agent.displayName} was $label. The change is stored server-side '
        'and written to the administrator audit log.',
        error: false,
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _confirmingId = null);
      _setNotice(AdminApi.message(error), error: true);
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  // --- Invite dialog --------------------------------------------------------

  /// Moves keyboard focus into a dialog the moment it opens.
  ///
  /// [SitewiseDialog] handles Escape on its own node, and a key event only
  /// reaches that node while focus sits inside it — an unfocused dialog
  /// cannot be dismissed from the keyboard at all. Opening a modal also has
  /// to move focus into it (WCAG 2.4.3); the shared dialog is stateless and
  /// cannot do that itself, so every opener on this page does it here.
  void _focusOpenDialog() {
    Future<void>.delayed(const Duration(milliseconds: 30), () {
      if (!mounted) return;
      final target = web.document.querySelector(
        '.dialog input, .dialog button, .dialog [tabindex]',
      );
      // The selector only ever matches HTML form/interactive elements.
      (target as web.HTMLElement?)?.focus();
    });
  }

  void _openInvite() {
    setState(() => _inviteOpen = true);
    _focusOpenDialog();
  }

  void _openConfirm(String userId) {
    setState(() => _confirmingId = userId);
    _focusOpenDialog();
  }

  void _closeInvite() => setState(() {
    _inviteOpen = false;
    _inviteError = null;
    _inviteSuccess = null;
    _validated = false;
    _submitting = false;
    _allowExisting = false;
  });

  String? get _nameError => !_validated
      ? null
      : _invName.trim().isEmpty
      ? 'Enter the name the agent will be listed under'
      : null;

  String? get _emailError {
    if (!_validated) return null;
    final value = _invEmail.trim();
    if (value.isEmpty) return 'A work email is required to address the invite';
    if (!value.contains('@') || !value.contains('.')) {
      return 'This does not look like an email address';
    }
    return null;
  }

  bool get _formValid =>
      _invName.trim().isNotEmpty &&
      _invEmail.trim().contains('@') &&
      _invEmail.trim().contains('.');

  Future<void> _sendInvite() async {
    setState(() {
      _validated = true;
      _inviteError = null;
      _inviteSuccess = null;
    });
    if (!_formValid) return;
    setState(() => _submitting = true);
    try {
      final result = await AppLocator.adminApi.createAgent(
        fullName: _invName.trim(),
        email: _invEmail.trim(),
        companyName: _invCompany.trim(),
        phoneNumber: _invPhone.trim(),
        allowExisting: _allowExisting,
      );
      if (!mounted) return;
      final invited = result['invited'] == true;
      final email = '${result['email'] ?? _invEmail.trim()}';
      setState(() {
        _inviteSuccess = invited
            ? 'Invite sent to $email. Supabase emailed the password-setup '
                  'link; the account stays pending until the agent sets a '
                  'credential and you activate it.'
            : 'Staff access granted to $email without a new invite (the '
                  'email already belonged to an account). The account is '
                  'pending and audited as a role grant.';
      });
      await _load(silent: true);
      return; // dialog stays open showing exactly what the server did
    } catch (error) {
      if (!mounted) return;
      setState(() => _inviteError = AdminApi.message(error));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  // --- Fragments ------------------------------------------------------------

  Component _hero() => OpsHero(
    icon: 'group_add',
    title: 'Staff access, issued by the server',
    body:
        'An invite creates the Supabase identity and emails the native '
        'password-setup link — this screen never sets, shows or stores an '
        'agent password. Suspension is immediate and written to the audit log.',
    action: ActionButton('Invite agent', icon: 'add', onClick: _openInvite),
  );

  Component _rosterPanel() {
    return SectionCard(
      title: _loading
          ? 'Agent directory'
          : 'Agent directory · '
                '${_agents.length} ${_agents.length == 1 ? 'account' : 'accounts'}',
      child: div(classes: 'stack', [
        SearchInput(
          label: 'Search agents',
          placeholder: 'Name, email or status',
          ariaLabel: 'Search agents or regions',
          onInput: (value) => setState(() => _query = value),
        ),
        if (_notice != null)
          ActionNotice(_notice!, tone: _noticeError ? 'danger' : 'info'),
        _rosterBody(),
      ]),
    );
  }

  Component _rosterBody() {
    if (_loading) {
      return div(classes: 'ops-grid', [
        for (var i = 0; i < 3; i++)
          div(classes: 'ops-card', [const Skeleton(variant: 'text', count: 3)]),
      ]);
    }
    if (_error != null) {
      return div(classes: 'stack', [
        Callout(
          'The staff directory could not be read: $_error',
          tone: 'danger',
          icon: 'error',
        ),
        ActionButton('Try again', variant: 'secondary', onClick: _load),
      ]);
    }
    final rows = _filtered;
    if (rows.isEmpty) {
      return InlineEmpty(
        _agents.isEmpty
            ? 'No agent accounts exist yet. Use “Invite agent” to provision '
                  'the first one — Supabase will email the credential setup.'
            : 'No agents match this search.',
      );
    }
    return div(classes: 'ops-grid', [
      for (final agent in rows) _agentCard(agent),
    ]);
  }

  Component _agentCard(StaffAgent agent) {
    final busy = _busyId == agent.userId;
    final status = agent.status.toLowerCase();
    final actions = <Component>[
      if (status == 'suspended')
        ActionButton(
          'Reactivate',
          variant: 'secondary',
          onClick: busy ? null : () => _setStatus(agent, 'active'),
        )
      else if (status == 'pending')
        ActionButton(
          'Activate',
          onClick: busy ? null : () => _setStatus(agent, 'active'),
        )
      else
        ActionButton(
          'Suspend',
          variant: 'danger-outline',
          onClick: busy ? null : () => _openConfirm(agent.userId),
        ),
    ];

    return article(classes: 'ops-card', [
      div(classes: 'ops-card__head', [
        span(classes: 'ops-tile', [const Icon('person')]),
        div([
          h3(classes: 'ops-card__title', [Component.text(agent.displayName)]),
          p(classes: 'ops-card__meta', [Component.text(agent.email)]),
        ]),
      ]),
      div(classes: 'ops-card__tags', [
        agent.status.isEmpty
            ? const StatusBadge('Unknown', tone: 'neutral')
            : StatusBadge.forText(agent.status),
        if (agent.agentId.isNotEmpty)
          StatusBadge('Agent #${agent.agentId}', tone: 'action'),
        if (agent.companyId.isNotEmpty)
          StatusBadge('Company ${agent.companyId}', tone: 'neutral'),
        if (agent.phone.isNotEmpty) StatusBadge(agent.phone, tone: 'neutral'),
      ]),
      div(classes: 'ops-card__actions', [
        ...actions,
        if (busy) span(classes: 'ops-card__meta', [Component.text('Working…')]),
      ]),
    ]);
  }

  Component _invitationsPanel() {
    return SectionCard(
      title: 'Invitations',
      child: _loading
          ? const Skeleton(variant: 'row', count: 3)
          : _error != null
          ? InlineEmpty('Invitations could not be read: $_error')
          : _invitations.isEmpty
          ? InlineEmpty(
              'No invitation records. Rows appear here once an invite is '
              'sent — this is Supabase’s own tracking, not a page-local '
              'list.',
            )
          : DataTable(
              columns: const [
                DataColumn('Invited address'),
                DataColumn('State'),
                DataColumn('Sent'),
              ],
              rows: [
                for (final invite in _invitations)
                  [
                    CellIdentity(
                      title: invite.email,
                      caption: invite.invitedById.isEmpty
                          ? 'Invitation record'
                          : 'By ${invite.invitedById}',
                    ),
                    StatusBadge(
                      invite.status.isEmpty ? 'Unknown' : invite.status,
                      tone: 'warning',
                    ),
                    Component.text(invite.createdAt),
                  ],
              ],
            ),
    );
  }

  Component _confirmDialog() {
    final agent = _agents
        .where((row) => row.userId == _confirmingId)
        .firstOrNull;
    if (agent == null) return const span([]);
    return SitewiseDialog(
      title: 'Suspend ${agent.displayName}?',
      ariaLabel: 'Confirm suspension',
      onClose: () => setState(() => _confirmingId = null),
      body: div(classes: 'stack', [
        p(classes: 'body', [
          Component.text(
            'Suspension takes effect immediately on every route the backend '
            'guards: the account keeps its identity and its invitation '
            'history, but ${agent.email} loses staff access until you '
            'reactivate it. The change is recorded in the audit log with '
            'your administrator identity.',
          ),
        ]),
      ]),
      actions: [
        ActionButton(
          'Cancel',
          variant: 'secondary',
          onClick: () => setState(() => _confirmingId = null),
        ),
        ActionButton(
          'Suspend account',
          variant: 'danger-outline',
          onClick: () => _setStatus(agent, 'suspended'),
        ),
      ],
    );
  }

  Component _inviteDialog() {
    return SitewiseDialog(
      title: 'Invite an agent',
      ariaLabel: 'Invite an agent',
      onClose: _closeInvite,
      wide: true,
      body: div(classes: 'stack', [
        p(classes: 'body', [
          Component.text(
            'Identity only — name and work email are what an invite needs. '
            'The agent sets their own password through the Supabase link; '
            'no credential is created or shown here.',
          ),
        ]),
        if (_inviteSuccess != null) ActionNotice(_inviteSuccess!, tone: 'info'),
        if (_inviteError != null) ActionNotice(_inviteError!, tone: 'danger'),
        Field(
          labelText: 'Full name',
          error: _nameError,
          hint: 'How the agent appears on the roster',
          child: input(
            type: InputType.text,
            attributes: const {
              'placeholder': 'e.g. Aina Rahman',
              'autocomplete': 'name',
            },
            events: events<String>(
              onInput: (value) => setState(() => _invName = value),
            ),
          ),
        ),
        Field(
          labelText: 'Work email',
          error: _emailError,
          hint: 'The invite is addressed here',
          child: input(
            type: InputType.email,
            attributes: const {
              'placeholder': 'name@agency.my',
              'autocomplete': 'email',
            },
            events: events<String>(
              onInput: (value) => setState(() => _invEmail = value),
            ),
          ),
        ),
        Field(
          labelText: 'Company (optional)',
          hint: 'Linked to the agent profile, creating the company if new',
          child: input(
            type: InputType.text,
            attributes: const {'placeholder': 'e.g. Aina Realty Sdn Bhd'},
            events: events<String>(
              onInput: (value) => setState(() => _invCompany = value),
            ),
          ),
        ),
        Field(
          labelText: 'Phone (optional)',
          hint: 'Stored on the identity row, never displayed publicly',
          child: input(
            type: InputType.tel,
            attributes: const {'placeholder': '+60 12 345 6789'},
            events: events<String>(
              onInput: (value) => setState(() => _invPhone = value),
            ),
          ),
        ),
        label(classes: 'ops-checkrow', [
          input(
            type: InputType.checkbox,
            checked: _allowExisting,
            events: events(
              onClick: () => setState(() => _allowExisting = !_allowExisting),
            ),
          ),
          span([
            Component.text(
              'This email already belongs to an account — grant it staff '
              'access instead of inviting a new identity. Required by the '
              'backend whenever the address is already registered; matching '
              'emails never upgrade roles automatically.',
            ),
          ]),
        ]),
      ]),
      actions: [
        ActionButton(
          'Close',
          variant: 'secondary',
          onClick: _submitting ? null : _closeInvite,
        ),
        ActionButton(
          _submitting
              ? 'Sending…'
              : (_allowExisting ? 'Grant access' : 'Send invite'),
          onClick: _submitting ? null : _sendInvite,
        ),
      ],
    );
  }

  @override
  Component build(BuildContext context) {
    return AppLayout(
      role: AppRole.admin,
      currentRoute: '/admin/agents',
      title: 'Agent management',
      eyebrow: 'Operations',
      subtitle:
          'Roster, invitations and account status from the live staff API — '
          'administrator sign-in with MFA is required for every mutation.',
      actions: [
        ActionButton('Refresh', variant: 'secondary', onClick: _load),
        ActionButton('Invite agent', icon: 'add', onClick: _openInvite),
      ],
      child: div(classes: 'stack ops-fade', [
        _hero(),
        Callout(
          'Invitations and status changes run through the server-side staff '
          'API, which requires an administrator account with MFA and writes '
          'every change to the audit log. There is no password field here by '
          'design: the invited agent sets their own credential.',
          icon: 'shield',
        ),
        _rosterPanel(),
        _invitationsPanel(),
        if (_inviteOpen) _inviteDialog(),
        if (_confirmingId != null) _confirmDialog(),
      ]),
    );
  }
}
