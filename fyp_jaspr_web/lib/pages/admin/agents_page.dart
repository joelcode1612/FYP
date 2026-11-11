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

/// Agent management — the administrator's live, company-aware staff roster.
///
/// ## What is real
///
/// Every number, row and status on this page comes from the FastAPI staff API
/// (`backend/src/sitewise/api/v1/staff.py`), all guarded by **administrator +
/// MFA (`aal2`)** on the server and all mutations recorded in
/// `role_change_audit`:
///
/// * `GET  /api/v1/staff/summary` — KPI counts computed on the server,
/// * `GET  /api/v1/staff/agents` — roster joined to `public.company` and to
///   the latest `staff_invitations` state,
/// * `GET  /api/v1/staff/companies` / `POST /api/v1/staff/companies` — the
///   existing `public.company` directory and registration (id preserved),
/// * `POST /api/v1/staff/agents` — the four-step wizard's final submission:
///   provisions the Supabase identity and emails the native password-setup
///   link. **No password is typed, shown or stored here.**
/// * `PATCH /api/v1/staff/agents/{id}/status` — suspend / activate / reactivate,
/// * `GET  /api/v1/staff/invitations` and
///   `POST /api/v1/staff/invitations/{id}/revoke` — invite tracking.
///
/// There are no sample records. A failed read is reported as a callout without
/// hiding the data that did load; a failed write shows the backend's own
/// sentence. Accounts stay `pending` until an administrator activates them —
/// the wizard never activates anything, and authentication/MFA stay server-side.
@client
class AdminAgentsPage extends StatefulComponent {
  const AdminAgentsPage({super.key});

  @override
  State<AdminAgentsPage> createState() => _AdminAgentsPageState();
}

// Company and identity are entered together, then reviewed before sending.
const _steps = <String>[
  'Agent details',
  'Review',
  'Invitation',
];
const _existingMode = 'Existing company';
const _newMode = 'New company';

final _emailPattern = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');

/// A single `<option>` value/label pair for [_AdminAgentsPageState._selectField].
class _Option {
  final String value;
  final String label;

  const _Option(this.value, this.label);
}

class _AdminAgentsPageState extends State<AdminAgentsPage> {
  // --- Live data ------------------------------------------------------------
  bool _loading = true;
  String? _error;
  List<StaffAgent> _agents = const [];
  List<StaffInvitation> _invitations = const [];
  List<CompanyRecord> _companies = const [];
  StaffSummary _summary = StaffSummary.empty;

  // --- Directory filters ----------------------------------------------------
  String _query = '';
  String _statusFilter = 'all';
  String _inviteFilter = 'all';
  String _companyFilter = 'all';

  // --- Row actions ----------------------------------------------------------
  String? _confirmingId;
  String? _detailsId;
  String? _busyId;
  String? _revokingId;
  String? _notice;
  bool _noticeError = false;

  // --- Invite wizard --------------------------------------------------------
  bool _inviteOpen = false;
  int _step = 0;
  bool _validatedCompany = false;
  bool _validatedAgent = false;
  String _companyMode = _existingMode;
  String _selectedCompanyId = '';
  String _newCompanyName = '';
  String _invName = '';
  String _invEmail = '';
  String _invPhone = '';
  bool _allowExisting = false;
  bool _confirmed = false;
  bool _submitting = false;
  String? _wizardError;
  Map<String, dynamic>? _result;
  int? _resultCompanyId;
  String _resultCompanyName = '';

  // --- Standalone company registration -------------------------------------
  bool _companyDialogOpen = false;
  String _companyDialogName = '';
  bool _companySaving = false;
  String? _companyDialogError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Monotonic sequence prevents an older refresh from overwriting a newer one.
  int _loadSequence = 0;

  /// A single backend snapshot avoids repeated PostgREST reads and inconsistent
  /// KPIs. On failure, keep last good data and display a visible error.
  Future<void> _load({bool silent = false}) async {
    final sequence = ++_loadSequence;
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final snapshot = await AppLocator.adminApi.overview();
      if (!mounted || sequence != _loadSequence) return;
      setState(() {
        _agents = snapshot.agents;
        _invitations = snapshot.invitations;
        _companies = snapshot.companies;
        _summary = snapshot.summary;
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted || sequence != _loadSequence) return;
      setState(() {
        _loading = false;
        _error = AdminApi.message(error);
      });
    }
  }

  // --- Derived values -------------------------------------------------------

  CompanyRecord? get _selectedCompany {
    if (_selectedCompanyId.isEmpty) return null;
    for (final company in _companies) {
      if ('${company.id}' == _selectedCompanyId) return company;
    }
    return null;
  }

  String get _assignmentLabel {
    if (_companyMode == _existingMode) {
      return _selectedCompany?.name.isNotEmpty == true
          ? _selectedCompany!.name
          : 'No company selected';
    }
    final name = _newCompanyName.trim();
    return name.isEmpty ? 'Not entered' : '$name (new)';
  }

  List<StaffAgent> get _filtered {
    final q = _query.trim().toLowerCase();
    return _agents
        .where((agent) {
          if (q.isNotEmpty) {
            final haystack =
                '${agent.displayName} ${agent.email} ${agent.companyName} '
                        '${agent.status} ${agent.invitationStatus} '
                        '${agent.agentId} ${agent.phone}'
                    .toLowerCase();
            if (!haystack.contains(q)) return false;
          }
          if (_statusFilter != 'all' &&
              agent.status.toLowerCase() != _statusFilter) {
            return false;
          }
          if (_inviteFilter == 'none') {
            if (agent.invitationStatus.isNotEmpty) return false;
          } else if (_inviteFilter != 'all' &&
              agent.invitationStatus.toLowerCase() != _inviteFilter) {
            return false;
          }
          if (_companyFilter != 'all' && agent.companyId != _companyFilter) {
            return false;
          }
          return true;
        })
        .toList(growable: false);
  }

  String? get _duplicateError {
    final email = _invEmail.trim().toLowerCase();
    if (email.isEmpty) return null;
    if (_agents.any((agent) => agent.email.toLowerCase() == email)) {
      return 'An agent account already uses this email. Manage it from the '
          'agent directory instead of inviting it again.';
    }
    if (_invitations.any(
      (invite) => invite.isOpen && invite.email.toLowerCase() == email,
    )) {
      return 'An open invitation already exists for this email. Revoke it in '
          'the invitations table before issuing a new one.';
    }
    return null;
  }

  String? get _nameError => !_validatedAgent
      ? null
      : _invName.trim().isEmpty
      ? 'Enter the name the agent will be listed under'
      : null;

  String? get _emailError {
    if (!_validatedAgent) return null;
    final value = _invEmail.trim();
    if (value.isEmpty) return 'A work email is required to address the invite';
    if (value.length > 254 || !_emailPattern.hasMatch(value)) {
      return 'Enter a valid email address';
    }
    return null;
  }

  String? get _emailFieldError => _emailError ?? _duplicateError;

  String? get _companyError {
    if (!_validatedCompany) return null;
    if (_companyMode == _existingMode) {
      if (_selectedCompany == null) {
        return 'Choose an existing company, or switch to registering a new one';
      }
      return null;
    }
    final name = _newCompanyName.trim();
    if (name.length < 2) {
      return 'Enter the company name (at least 2 characters)';
    }
    if (_companies.any(
      (company) => company.name.toLowerCase() == name.toLowerCase(),
    )) {
      return 'This company already exists — select it from the existing '
          'directory instead';
    }
    return null;
  }

  bool get _companyStepValid {
    if (_companyMode == _existingMode) return _selectedCompany != null;
    final name = _newCompanyName.trim();
    return name.length >= 2 &&
        !_companies.any(
          (company) => company.name.toLowerCase() == name.toLowerCase(),
        );
  }

  bool get _agentStepValid =>
      _invName.trim().isNotEmpty &&
      _invEmail.trim().length <= 254 &&
      _emailPattern.hasMatch(_invEmail.trim()) &&
      _duplicateError == null;

  // --- Formatting helpers ---------------------------------------------------

  static String _label(String value) => value.isEmpty
      ? 'Not recorded'
      : value[0].toUpperCase() + value.substring(1);

  static String _tone(String status) => switch (status.toLowerCase()) {
    'active' || 'accepted' => 'success',
    'pending' => 'warning',
    'suspended' || 'expired' || 'revoked' => 'danger',
    'sent' => 'action',
    _ => 'neutral',
  };

  static String _shortDate(String raw) {
    if (raw.isEmpty) return '—';
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) return raw.length > 10 ? raw.substring(0, 10) : raw;
    const months = <String>[
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${parsed.day.toString().padLeft(2, '0')} '
        '${months[parsed.month - 1]} ${parsed.year}';
  }

  // --- Mutations ------------------------------------------------------------

  /// Surfaces a truthful partial-failure state: the backend commits the real
  /// change first and records the audit row second, so an audit write failure
  /// arrives as `audit_recorded: false` on a SUCCESS response — not as an
  /// error the administrator would retry against an already-applied change.
  static String _auditSuffix(Map<String, dynamic> result) =>
      result['audit_recorded'] == false
          ? ' NOTE: the change is applied but the audit log write failed — '
              'the server logged the cause; report it to the operator.'
          : '';

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
      final result = await AppLocator.adminApi.setAgentStatus(agent.userId, status);
      await _load(silent: true);
      if (!mounted) return;
      setState(() => _confirmingId = null);
      _setNotice(
        '${agent.displayName} was $label. The change is stored server-side '
        'and written to the administrator audit log.${_auditSuffix(result)}',
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

  Future<void> _revoke(StaffInvitation invite) async {
    if (invite.invitationId.isEmpty) {
      _setNotice(
        'This invitation row has no id, so it cannot be revoked safely.',
        error: true,
      );
      return;
    }
    setState(() => _revokingId = invite.invitationId);
    try {
      final result = await AppLocator.adminApi.revokeInvitation(invite.invitationId);
      await _load(silent: true);
      if (!mounted) return;
      _setNotice(
        'The invitation for ${invite.email} was revoked server-side. No '
        'identity was deleted and no email was sent; the address can now be '
        'invited again.${_auditSuffix(result)}',
        error: false,
      );
    } catch (error) {
      if (!mounted) return;
      _setNotice(AdminApi.message(error), error: true);
    } finally {
      if (mounted) setState(() => _revokingId = null);
    }
  }

  Future<void> _saveCompany() async {
    final name = _companyDialogName.trim();
    if (name.length < 2) {
      setState(() => _companyDialogError = 'Enter at least 2 characters.');
      return;
    }
    setState(() {
      _companySaving = true;
      _companyDialogError = null;
    });
    try {
      final created = await AppLocator.adminApi.createCompany(name);
      await _load(silent: true);
      if (!mounted) return;
      setState(() {
        _companyDialogOpen = false;
        _companySaving = false;
        _companyDialogName = '';
        _selectedCompanyId = '${created.id}';
        _companyMode = _existingMode;
      });
      _setNotice(
        'Company "${created.name}" registered with company_id ${created.id}.',
        error: false,
      );
      // Company registration audits best-effort; a failed audit write does
      // not invalidate the created row, and the flag arrives on the success
      // response (`CompanyRecord` does not carry it).
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _companySaving = false;
        _companyDialogError = AdminApi.message(error);
      });
    }
  }

  Future<void> _submitInvite() async {
    setState(() {
      _validatedAgent = true;
      _wizardError = null;
    });
    if (!_companyStepValid || !_agentStepValid || !_confirmed) return;
    setState(() => _submitting = true);
    try {
      // A newly registered company is written first so the invitation carries
      // its real company_id. If the invite fails afterwards the company row
      // remains and is reusable from the existing-company list.
      late final int companyId;
      late final String companyName;
      if (_companyMode == _existingMode) {
        final selected = _selectedCompany;
        if (selected == null) {
          throw StateError('Select a company before sending the invitation.');
        }
        companyId = selected.id;
        companyName = selected.name;
      } else {
        final created = await AppLocator.adminApi.createCompany(
          _newCompanyName.trim(),
        );
        companyId = created.id;
        companyName = created.name;
      }
      final result = await AppLocator.adminApi.createAgent(
        fullName: _invName.trim(),
        email: _invEmail.trim(),
        phoneNumber: _invPhone.trim(),
        companyId: companyId,
        allowExisting: _allowExisting,
      );
      await _load(silent: true);
      if (!mounted) return;
      setState(() {
        _result = result;
        _resultCompanyId = companyId;
        _resultCompanyName = companyName;
        _step = 2;
        _submitting = false;
      });
      if (result['audit_recorded'] == false) {
        _setNotice(_auditSuffix(result).trim(), error: false);
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _wizardError = AdminApi.message(error);
      });
    }
  }

  // --- Dialog focus / state -------------------------------------------------

  /// [SitewiseDialog] handles Escape on its own node, and a key event only
  /// reaches that node while focus sits inside it. Opening a modal also has to
  /// move focus into it (WCAG 2.4.3), so every opener does it here.
  void _focusOpenDialog() {
    Future<void>.delayed(const Duration(milliseconds: 30), () {
      if (!mounted) return;
      // Prefer the first form field instead of placing focus on the stepper.
      final target = web.document.querySelector(
            '.ag-invite-form select, .ag-invite-form input',
          ) ??
          web.document.querySelector(
            '.dialog input, .dialog button, .dialog [tabindex]',
          );
      (target as web.HTMLElement?)?.focus();
    });
  }

  void _resetWizard() {
    _step = 0;
    _validatedCompany = false;
    _validatedAgent = false;
    _companyMode = _existingMode;
    _selectedCompanyId = '';
    _newCompanyName = '';
    _invName = '';
    _invEmail = '';
    _invPhone = '';
    _allowExisting = false;
    _confirmed = false;
    _submitting = false;
    _wizardError = null;
    _result = null;
    _resultCompanyId = null;
    _resultCompanyName = '';
  }

  void _openInvite() {
    setState(() {
      _resetWizard();
      _inviteOpen = true;
    });
    _focusOpenDialog();
  }

  void _closeInvite() => setState(() {
    _inviteOpen = false;
    _resetWizard();
  });

  void _noop() {}

  void _closeCompanyDialog() => setState(() {
    _companyDialogOpen = false;
    _companyDialogError = null;
    _companySaving = false;
  });

  void _openCompanyDialog() {
    setState(() {
      _companyDialogOpen = true;
      _companyDialogError = null;
    });
    _focusOpenDialog();
  }

  void _openDetails(String userId) {
    setState(() => _detailsId = userId);
    _focusOpenDialog();
  }

  void _openConfirm(String userId) {
    // Close the details modal so only one dialog is ever on screen.
    setState(() {
      _confirmingId = userId;
      _detailsId = null;
    });
    _focusOpenDialog();
  }

  void _nextFromCompany() {
    setState(() {
      _validatedCompany = true;
      _validatedAgent = true;
      _wizardError = null;
    });
    if (!_companyStepValid || !_agentStepValid) {
      // Focus the first invalid field. Both sections validate together.
      Future<void>.delayed(const Duration(milliseconds: 30), () {
        if (!mounted) return;
        final invalid = web.document.querySelector(
          '.ag-invite-form [aria-invalid="true"]',
        );
        (invalid as web.HTMLElement?)?.focus();
      });
      return;
    }
    setState(() => _step = 1);
    _focusOpenDialog();
  }

  // --- Shared field builders ------------------------------------------------

  Component _selectField({
    required String labelText,
    required String value,
    required List<_Option> options,
    required void Function(String) onChanged,
    String? hint,
    String? error,
  }) {
    return Field(
      labelText: labelText,
      hint: hint,
      error: error,
      child: select(
        attributes: {
          'aria-label': labelText,
          if (error != null) 'aria-invalid': 'true',
        },
        events: events<List<String>>(
          onInput: (values) => onChanged(values.isEmpty ? '' : values.first),
        ),
        [
          // `entry` (not `option`) so the local name does not shadow the DOM
          // `option()` builder imported from package:jaspr/dom.dart.
          for (final entry in options)
            option(
              value: entry.value,
              attributes: value == entry.value ? const {'selected': ''} : null,
              [Component.text(entry.label)],
            ),
        ],
      ),
    );
  }

  Component _textInput({
    required String value,
    required String placeholder,
    required void Function(String) onInput,
    required bool invalid,
    InputType type = InputType.text,
    String? autocomplete,
  }) {
    return input(
      type: type,
      attributes: {
        'value': value,
        'placeholder': placeholder,
        'aria-invalid': invalid ? 'true' : 'false',
        // "off" is a valid HTML token and keeps the map Map<String, String>
        // (a null-aware entry would widen it to Map<String, String?>).
        'autocomplete': autocomplete ?? 'off',
      },
      events: events<String>(onInput: onInput),
    );
  }

  // --- Fragments ------------------------------------------------------------

  Component _hero() => OpsHero(
    icon: 'group_add',
    title: 'Staff access, issued by the server',
    body:
        'Assign a real company, review the agent details, then let Supabase '
        'create the identity and email the password-setup link. This screen '
        'never sets, shows or stores an agent password, and never activates '
        'an account before the agent has authenticated.',
    action: ActionButton('Invite agent', icon: 'add', onClick: _openInvite),
  );

  Component _metrics() {
    final s = _summary;
    return div(
      classes: 'ops-stats ag-stats',
      attributes: const {'aria-label': 'Agent summary from the staff API'},
      [
        OpsStat(
          icon: 'groups',
          label: 'Total agents',
          value: '${s.totalAgents}',
          note: _loading
              ? 'Loading live data…'
              : '${s.activeAgents} active · ${s.pendingAgents} pending · '
                    '${s.suspendedAgents} suspended',
        ),
        OpsStat(
          icon: 'how_to_reg',
          label: 'Active accounts',
          value: '${s.activeAgents}',
          note: 'Server-side account_status',
        ),
        OpsStat(
          icon: 'forward_to_inbox',
          label: 'Open invitations',
          value: '${s.openInvitations}',
          note: '${s.invitations} invitation records in total',
        ),
        OpsStat(
          icon: 'apartment',
          label: 'Companies',
          value: '${s.companies}',
          note: 'Existing public.company rows',
        ),
      ],
    );
  }

  Component _filters() => div(classes: 'ag-filters', [
    SearchInput(
      label: 'Search agents',
      placeholder: 'Name, email, company or status',
      ariaLabel: 'Search the agent directory',
      onInput: (value) => setState(() => _query = value),
    ),
    _selectField(
      labelText: 'Account status',
      value: _statusFilter,
      options: const [
        _Option('all', 'All statuses'),
        _Option('active', 'Active'),
        _Option('pending', 'Pending'),
        _Option('suspended', 'Suspended'),
      ],
      onChanged: (value) => setState(() => _statusFilter = value),
    ),
    _selectField(
      labelText: 'Invitation status',
      value: _inviteFilter,
      options: const [
        _Option('all', 'All invitations'),
        _Option('pending', 'Pending'),
        _Option('sent', 'Sent'),
        _Option('accepted', 'Accepted'),
        _Option('expired', 'Expired'),
        _Option('revoked', 'Revoked'),
        _Option('none', 'No invitation'),
      ],
      onChanged: (value) => setState(() => _inviteFilter = value),
    ),
    _selectField(
      labelText: 'Company',
      value: _companyFilter,
      options: [
        const _Option('all', 'All companies'),
        for (final company in _companies)
          _Option(
            '${company.id}',
            company.name.isEmpty ? 'Company #${company.id}' : company.name,
          ),
      ],
      onChanged: (value) => setState(() => _companyFilter = value),
    ),
  ]);

  Component _rosterPanel() {
    final showing = _filtered.length;
    return SectionCard(
      title: _loading
          ? 'Agent directory'
          : 'Agent directory · $showing of ${_agents.length} accounts',
      child: div(classes: 'stack', [
        _filters(),
        if (_notice != null)
          ActionNotice(_notice!, tone: _noticeError ? 'danger' : 'info'),
        if (_error != null)
          Callout(
            'Could not refresh agent management: $_error. Previously loaded '
            'records are preserved. Use Refresh to retry.',
            tone: 'warning',
            icon: 'warning',
          ),
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
    final rows = _filtered;
    if (rows.isEmpty) {
      return InlineEmpty(
        _agents.isEmpty
            ? 'No agent accounts exist yet. Use "Invite agent" to provision '
                  'the first one — Supabase will email the credential setup.'
            : 'No agents match these filters. Clear the search or choose a '
                  'different status to see the full roster.',
      );
    }
    return DataTable(
      columns: const [
        DataColumn('Agent'),
        DataColumn('Company'),
        DataColumn('Account status'),
        DataColumn('Invitation'),
        DataColumn('Added'),
        DataColumn('Actions', actions: true),
      ],
      rows: [
        for (final agent in rows)
          [
            CellIdentity(title: agent.displayName, caption: agent.email),
            Component.text(
              agent.companyName.isEmpty
                  ? (agent.companyId.isEmpty
                        ? 'Unassigned'
                        : '#${agent.companyId}')
                  : agent.companyName,
            ),
            agent.status.isEmpty
                ? const StatusBadge('Unknown', tone: 'neutral')
                : StatusBadge(_label(agent.status), tone: _tone(agent.status)),
            agent.invitationStatus.isEmpty
                ? const StatusBadge('None', tone: 'neutral')
                : StatusBadge(
                    _label(agent.invitationStatus),
                    tone: _tone(agent.invitationStatus),
                  ),
            Component.text(_shortDate(agent.createdAt)),
            div(classes: 'ag-actions', [
              ActionButton(
                'Details',
                variant: 'ghost',
                onClick: () => _openDetails(agent.userId),
              ),
              _statusAction(agent),
            ]),
          ],
      ],
    );
  }

  Component _statusAction(StaffAgent agent) {
    if (_busyId == agent.userId) {
      return span(classes: 'ag-muted', [Component.text('Working…')]);
    }
    final status = agent.status.toLowerCase();
    if (status == 'suspended') {
      return ActionButton(
        'Reactivate',
        variant: 'secondary',
        onClick: () => _setStatus(agent, 'active'),
      );
    }
    if (status == 'pending') {
      return ActionButton(
        'Activate',
        onClick: () => _setStatus(agent, 'active'),
      );
    }
    return ActionButton(
      'Suspend',
      variant: 'danger-outline',
      onClick: () => _openConfirm(agent.userId),
    );
  }

  Component _companiesPanel() {
    return SectionCard(
      title: 'Company directory',
      action: [
        ActionButton(
          'Register company',
          variant: 'secondary',
          icon: 'add',
          onClick: _openCompanyDialog,
        ),
      ],
      child: div(classes: 'stack', [
        p(classes: 'ag-muted', [
          Component.text(
            'Existing public.company rows. The invitation wizard stores the '
            'company_id on the agent profile; registration only creates a new '
            'row, so no duplicate table or column is introduced.',
          ),
        ]),
        _loading
            ? const Skeleton(variant: 'row', count: 2)
            : _companies.isEmpty
            ? InlineEmpty(
                'No companies are registered yet. Register one to make it '
                'selectable in the invitation wizard.',
              )
            : DataTable(
                columns: const [
                  DataColumn('Company'),
                  DataColumn('ID', numeric: true),
                  DataColumn('Agents', numeric: true),
                ],
                rows: [
                  for (final company in _companies)
                    [
                      CellIdentity(
                        title: company.name.isEmpty
                            ? 'Company #${company.id}'
                            : company.name,
                        caption: 'public.company',
                      ),
                      Component.text('${company.id}'),
                      Component.text(
                        '${_agents.where((agent) => agent.companyId == company.id.toString()).length}',
                      ),
                    ],
                ],
              ),
      ]),
    );
  }

  Component _invitationsPanel() {
    return SectionCard(
      title: 'Invitations',
      child: _loading
          ? const Skeleton(variant: 'row', count: 3)
          : _invitations.isEmpty
          ? InlineEmpty(
              'No invitation records yet. Rows appear here only after the '
              'server confirms a Supabase invite.',
            )
          : DataTable(
              columns: const [
                DataColumn('Invited address'),
                DataColumn('State'),
                DataColumn('Created'),
                DataColumn('Expires'),
                DataColumn('Actions', actions: true),
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
                      invite.status.isEmpty ? 'Unknown' : _label(invite.status),
                      tone: _tone(invite.status),
                    ),
                    Component.text(_shortDate(invite.createdAt)),
                    Component.text(_shortDate(invite.expiresAt)),
                    div(classes: 'ag-actions', [
                      if (invite.isOpen && invite.invitationId.isNotEmpty)
                        ActionButton(
                          _revokingId == invite.invitationId
                              ? 'Revoking…'
                              : 'Revoke',
                          variant: 'danger-outline',
                          onClick: _revokingId == null
                              ? () => _revoke(invite)
                              : null,
                        )
                      else
                        span(classes: 'ag-muted', [Component.text('Closed')]),
                    ]),
                  ],
              ],
            ),
    );
  }

  // --- Wizard ---------------------------------------------------------------

  Component _stepper() => div(
    classes: 'ag-steps',
    attributes: const {'aria-label': 'Invitation progress'},
    [
      for (var i = 0; i < _steps.length; i++)
        button(
          classes:
              'ag-step'
              '${i == _step ? ' ag-step--on' : ''}'
              '${i < _step ? ' ag-step--done' : ''}',
          attributes: {
            'type': 'button',
            'aria-current': i == _step ? 'step' : 'false',
            if (i > _step || _step == 2) 'disabled': '',
          },
          events: events(
            onClick: (i < _step && _step < 2 && !_submitting)
                ? () => setState(() => _step = i)
                : null,
          ),
          [
            span(classes: 'ag-step__num', [
              Component.text(i < _step ? '✓' : '0${i + 1}'),
            ]),
            span(classes: 'ag-step__label', [Component.text(_steps[i])]),
          ],
        ),
    ],
  );

  Component _companyStep() => div(classes: 'stack', [
    p(classes: 'body', [
      Component.text(
        'Choose where this agent will be registered. The real company_id is '
        'stored on the agent profile and shown in the directory.',
      ),
    ]),
    ChipRow(
      options: const [_existingMode, _newMode],
      selected: _companyMode,
      ariaLabel: 'Company assignment mode',
      onSelect: (value) => setState(() {
        _companyMode = value;
        _validatedCompany = false;
        _wizardError = null;
      }),
    ),
    if (_companyMode == _existingMode)
      _companies.isEmpty
          ? InlineEmpty(
              'No companies are registered yet. Switch to "New company" to '
              'create the first one, or use "Register company" on the '
              'directory panel.',
            )
          : _selectField(
              labelText: 'Existing company',
              value: _selectedCompanyId,
              options: [
                const _Option('', 'Select a company'),
                for (final company in _companies)
                  _Option(
                    '${company.id}',
                    company.name.isEmpty
                        ? 'Company #${company.id}'
                        : company.name,
                  ),
              ],
              hint:
                  'Selected from public.company — no duplicate row is created.',
              error: _companyError,
              onChanged: (value) => setState(() {
                _selectedCompanyId = value;
                _validatedCompany = false;
              }),
            )
    else
      Field(
        labelText: 'New company name',
        error: _companyError,
        hint:
            'Registered in public.company before the invite is sent; the '
            'returned company_id is preserved with the agent.',
        child: _textInput(
          value: _newCompanyName,
          placeholder: 'e.g. Aina Realty Sdn Bhd',
          invalid: _companyError != null,
          onInput: (value) => setState(() {
            _newCompanyName = value;
            _validatedCompany = false;
          }),
        ),
      ),
    Callout(
      'The live public.company table exposes company_id and company_name only. '
      'No company type or extra column is written or invented here.',
      icon: 'info',
    ),
  ]);

  Component _agentStep() => div(classes: 'stack', [
    p(classes: 'body', [
      Component.text(
        'Identity only. The agent chooses their own credential through the '
        'Supabase invite link after the administrator submits the review.',
      ),
    ]),
    Field(
      labelText: 'Full name',
      error: _nameError,
      hint: 'How the agent appears on the roster',
      child: _textInput(
        value: _invName,
        placeholder: 'e.g. Aina Rahman',
        autocomplete: 'name',
        invalid: _nameError != null,
        onInput: (value) => setState(() => _invName = value),
      ),
    ),
    Field(
      labelText: 'Work email',
      error: _emailFieldError,
      hint: 'The invite is addressed here',
      child: _textInput(
        value: _invEmail,
        placeholder: 'name@agency.my',
        type: InputType.email,
        autocomplete: 'email',
        invalid: _emailFieldError != null,
        onInput: (value) => setState(() => _invEmail = value),
      ),
    ),
    Field(
      labelText: 'Phone (optional)',
      hint: 'Stored on the identity row, never displayed publicly',
      child: _textInput(
        value: _invPhone,
        placeholder: '+60 12 345 6789',
        type: InputType.tel,
        autocomplete: 'tel',
        invalid: false,
        onInput: (value) => setState(() => _invPhone = value),
      ),
    ),
    div(classes: 'ag-fixed', [
      InfoRow(
        icon: 'apartment',
        label: 'Assigned company',
        value: _assignmentLabel,
      ),
      InfoRow(
        icon: 'badge',
        label: 'Role',
        value: 'Agent — fixed by the server',
      ),
    ]),
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
          'This email already belongs to an account — grant it staff access '
          'instead of inviting a new identity. The backend requires this '
          'explicit opt-in; matching emails never upgrade roles automatically.',
        ),
      ]),
    ]),
  ]);

  Component _reviewStep() => div(classes: 'stack', [
    p(classes: 'body', [
      Component.text(
        'Check every value before the server provisions an identity. Nothing '
        'has been written yet for this agent.',
      ),
    ]),
    div(classes: 'ag-review', [
      InfoRow(icon: 'person', label: 'Full name', value: _invName.trim()),
      InfoRow(icon: 'mail', label: 'Work email', value: _invEmail.trim()),
      InfoRow(
        icon: 'call',
        label: 'Phone',
        value: _invPhone.trim().isEmpty ? 'Not provided' : _invPhone.trim(),
      ),
      InfoRow(icon: 'apartment', label: 'Company', value: _assignmentLabel),
      InfoRow(icon: 'badge', label: 'Role', value: 'Agent'),
      InfoRow(
        icon: 'lock',
        label: 'Credential',
        value: 'Set by the agent through the Supabase invite',
      ),
    ]),
    Callout(
      'Submitting provisions a pending agent account. It is not activated '
      'here: activation follows the agent completing authentication and MFA, '
      'and is recorded in the administrator audit log.',
      icon: 'shield',
    ),
    label(classes: 'ops-checkrow', [
      input(
        type: InputType.checkbox,
        checked: _confirmed,
        events: events(onClick: () => setState(() => _confirmed = !_confirmed)),
      ),
      span([
        Component.text(
          'I have reviewed the agent and company details and authorise this '
          'invitation.',
        ),
      ]),
    ]),
  ]);

  Component _resultStep() {
    final result = _result;
    if (result == null) {
      return InlineEmpty('No invitation was submitted in this session.');
    }
    final invited = result['invited'] == true;
    final invitation = result['invitation'];
    final status = '${result['invitation_status'] ?? ''}'.isNotEmpty
        ? '${result['invitation_status']}'
        : (invitation is Map ? '${invitation['invitation_status'] ?? ''}' : '');
    final email = '${result['email'] ?? _invEmail.trim()}';
    final accountStatus = '${result['account_status'] ?? ''}';
    return div(classes: 'stack', [
      div(
        attributes: const {'role': 'status'},
        [
          ActionNotice(
            'The server accepted the request. Every value below comes from the '
            'FastAPI response, not from local form state.',
            tone: 'info',
          ),
        ],
      ),
      div(classes: 'ag-review', [
        InfoRow(icon: 'mail', label: 'Invited address', value: email),
        InfoRow(
          icon: 'mark_email_read',
          label: 'Invitation status',
          value: !invited
              ? 'No invite sent — staff access granted to an existing identity'
              : status.isEmpty
              ? 'No invitation record was returned — check the invitations table'
              : _label(status),
        ),
        InfoRow(
          icon: 'apartment',
          label: 'Assigned company',
          value: _resultCompanyId == null
              ? _resultCompanyName
              : '$_resultCompanyName (company_id $_resultCompanyId)',
        ),
        InfoRow(
          icon: 'toggle_off',
          label: 'Account status',
          value: accountStatus.isEmpty ? 'Not returned' : _label(accountStatus),
        ),
        InfoRow(
          icon: 'fingerprint',
          label: 'Agent user id',
          value: '${result['agent_user_id'] ?? ''}',
        ),
      ]),
      Callout(
        'The account stays pending until the agent sets a credential through '
        'the Supabase link and you activate it. Supabase Auth, MFA and the '
        'audit log remain server-side; this page never sees a password.',
        icon: 'shield',
      ),
    ]);
  }

  /// One complete entry form — no hidden email field on a later page.
  /// The existing company/agent field builders and validation remain reused.
  Component _invitationForm() => div(classes: 'ag-invite-form', [
    div(classes: 'ag-invite-form__section', [
      h3(classes: 'ag-invite-form__heading', [
        Component.text('Company assignment'),
      ]),
      _companyStep(),
    ]),
    div(classes: 'ag-invite-form__section', [
      h3(classes: 'ag-invite-form__heading', [
        Component.text('Agent information'),
      ]),
      _agentStep(),
    ]),
  ]);

  Component _wizardBody() => switch (_step) {
    0 => _invitationForm(),
    1 => _reviewStep(),
    _ => _resultStep(),
  };

  List<Component> _wizardActions() {
    if (_step == 2) {
      return [
        ActionButton(
          'Invite another',
          variant: 'secondary',
          onClick: () {
            setState(_resetWizard);
            _focusOpenDialog();
          },
        ),
        ActionButton('Done', onClick: _closeInvite),
      ];
    }
    if (_step == 0) {
      return [
        ActionButton(
          'Cancel',
          variant: 'secondary',
          onClick: _submitting ? null : _closeInvite,
        ),
        ActionButton(
          'Review details',
          onClick: _submitting ? null : _nextFromCompany,
        ),
      ];
    }
    return [
      ActionButton(
        'Back to details',
        variant: 'secondary',
        onClick: _submitting ? null : () => setState(() => _step = 0),
      ),
      ActionButton(
        _submitting ? 'Sending…' : 'Send invitation',
        onClick: (_submitting || !_confirmed) ? null : _submitInvite,
      ),
    ];
  }

  Component _inviteDialog() {
    return SitewiseDialog(
      title: _step == 2 ? 'Invitation submitted' : 'Invite an agent',
      ariaLabel: 'Invite an agent — step ${_step + 1} of 3',
      onClose: _submitting ? _noop : _closeInvite,
      wide: true,
      // Only this dialog gets the two-column invitation layout and the
      // ~940px panel; other `dialog--wide` modals keep their width.
      panelClass: 'dialog--invite',
      body: div(
        classes: 'stack ag-wizard ag-invite-dialog-body',
        attributes: {'aria-busy': _submitting ? 'true' : 'false'},
        [
          _stepper(),
          _wizardBody(),
          if (_wizardError != null)
            div(
              attributes: const {'role': 'alert'},
              [ActionNotice(_wizardError!, tone: 'danger')],
            ),
        ],
      ),
      actions: _wizardActions(),
    );
  }

  Component _companyDialog() {
    return SitewiseDialog(
      title: 'Register a company',
      ariaLabel: 'Register a company',
      onClose: _companySaving ? _noop : _closeCompanyDialog,
      body: div(classes: 'stack', [
        p(classes: 'body', [
          Component.text(
            'Creates one row in the existing public.company table. Duplicate '
            'names are refused by the server so an agent is never linked to '
            'two near-identical companies.',
          ),
        ]),
        if (_companyDialogError != null)
          div(
            attributes: const {'role': 'alert'},
            [ActionNotice(_companyDialogError!, tone: 'danger')],
          ),
        Field(
          labelText: 'Company name',
          error: _companyDialogError,
          hint: 'The returned company_id becomes selectable in the wizard.',
          child: _textInput(
            value: _companyDialogName,
            placeholder: 'e.g. Aina Realty Sdn Bhd',
            invalid: _companyDialogError != null,
            onInput: (value) => setState(() => _companyDialogName = value),
          ),
        ),
      ]),
      actions: [
        ActionButton(
          'Cancel',
          variant: 'secondary',
          onClick: _companySaving ? null : _closeCompanyDialog,
        ),
        ActionButton(
          _companySaving ? 'Registering…' : 'Register company',
          onClick: _companySaving ? null : _saveCompany,
        ),
      ],
    );
  }

  Component _detailsDialog() {
    final agent = _agents.where((row) => row.userId == _detailsId).firstOrNull;
    if (agent == null) return const span([]);
    return SitewiseDialog(
      title: agent.displayName,
      ariaLabel: 'Agent details',
      wide: true,
      onClose: () => setState(() => _detailsId = null),
      body: div(classes: 'ag-review', [
        InfoRow(icon: 'mail', label: 'Email', value: agent.email),
        InfoRow(icon: 'person', label: 'Full name', value: agent.fullName),
        InfoRow(
          icon: 'call',
          label: 'Phone',
          value: agent.phone.isEmpty ? 'Not provided' : agent.phone,
        ),
        InfoRow(
          icon: 'apartment',
          label: 'Company',
          value: agent.companyName.isEmpty
              ? (agent.companyId.isEmpty ? 'Unassigned' : '#${agent.companyId}')
              : '${agent.companyName} (id ${agent.companyId})',
        ),
        InfoRow(icon: 'badge', label: 'Role', value: _label(agent.role)),
        InfoRow(
          icon: 'toggle_off',
          label: 'Account status',
          value: _label(agent.status),
        ),
        InfoRow(
          icon: 'forward_to_inbox',
          label: 'Invitation status',
          value: agent.invitationStatus.isEmpty
              ? 'No invitation record'
              : _label(agent.invitationStatus),
        ),
        InfoRow(
          icon: 'event',
          label: 'Added',
          value: _shortDate(agent.createdAt),
        ),
        InfoRow(icon: 'fingerprint', label: 'User id', value: agent.userId),
      ]),
      actions: [
        ActionButton(
          'Close',
          variant: 'secondary',
          onClick: () => setState(() => _detailsId = null),
        ),
        _statusAction(agent),
      ],
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

  @override
  Component build(BuildContext context) {
    return AppLayout(
      role: AppRole.admin,
      currentRoute: '/admin/agents',
      title: 'Agent management',
      eyebrow: 'Operations',
      subtitle:
          'Live agent roster, company directory and invitations from the '
          'authenticated staff API — administrator sign-in with MFA is '
          'required for every mutation.',
      actions: [
        ActionButton('Refresh', variant: 'secondary', onClick: _load),
        ActionButton(
          'Register company',
          variant: 'secondary',
          icon: 'domain_add',
          onClick: _openCompanyDialog,
        ),
        ActionButton('Invite agent', icon: 'add', onClick: _openInvite),
      ],
      child: div(classes: 'stack ag ops-fade', [
        _hero(),
        _metrics(),
        _rosterPanel(),
        div(classes: 'ag-columns', [_companiesPanel(), _invitationsPanel()]),
        if (_inviteOpen) _inviteDialog(),
        if (_companyDialogOpen) _companyDialog(),
        if (_detailsId != null) _detailsDialog(),
        if (_confirmingId != null) _confirmDialog(),
      ]),
    );
  }
}
