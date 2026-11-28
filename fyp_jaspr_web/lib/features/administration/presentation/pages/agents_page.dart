import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';
import 'package:universal_web/web.dart' as web;

import 'package:sitewise_jaspr_web/features/administration/presentation/components/admin_ops_kit.dart';
import 'package:sitewise_jaspr_web/shared/presentation/components/dashboard_kit.dart';
import 'package:sitewise_jaspr_web/shared/presentation/components/ui.dart';
import 'package:sitewise_jaspr_web/features/administration/data/admin_api.dart';
import 'package:sitewise_jaspr_web/core/di/app_locator.dart';
import 'package:sitewise_jaspr_web/shared/presentation/layouts/app_layout.dart';

class AdminAgentsPage extends StatefulComponent {
  const AdminAgentsPage({super.key, this.openInvitation = false});

  final bool openInvitation;

  @override
  State<AdminAgentsPage> createState() => _AdminAgentsPageState();
}

const _steps = <String>['Agent details', 'Review', 'Invitation'];

final _emailPattern = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');

/// Presentation-only initials, never used as an account identifier.
String _agentInitials(String fullName) {
  final words = fullName
      .trim()
      .split(RegExp(r'\s+'))
      .where((word) => word.isNotEmpty)
      .toList(growable: false);
  if (words.isEmpty) return 'A';
  final first = words.first.substring(0, 1).toUpperCase();
  final last = words.length > 1 ? words.last.substring(0, 1).toUpperCase() : '';
  return '$first$last';
}

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
  StaffSummary _summary = StaffSummary.empty;

  // --- Directory filters ----------------------------------------------------
  String _query = '';
  String _statusFilter = 'all';
  String _inviteFilter = 'all';

  // --- Row actions ----------------------------------------------------------
  String? _confirmingId;
  String? _detailsId;
  String? _busyId;
  String? _revokingId;
  // Identifies the open invitation awaiting an explicit cancellation decision.
  String? _cancelInvitationId;
  String? _cancelInvitationError;
  String? _notice;
  bool _noticeError = false;

  // --- Invite wizard --------------------------------------------------------
  bool _inviteOpen = false;
  int _step = 0;
  bool _validatedAgent = false;
  String _invName = '';
  String _invEmail = '';
  String _invPhone = '';
  bool _allowExisting = false;
  bool _confirmed = false;
  bool _submitting = false;
  String? _wizardError;
  Map<String, dynamic>? _result;

  // --- Supervised MFA recovery ---------------------------------------------
  String? _mfaId;
  String _mfaReason = '';
  bool _mfaBusy = false;
  String? _mfaError;

  @override
  void initState() {
    super.initState();
    _inviteOpen = component.openInvitation;
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
        _invitations = snapshot.invitations
            .where((row) => row.invitedRole == 'agent')
            .toList();
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

  List<StaffAgent> get _filtered {
    final q = _query.trim().toLowerCase();
    return _agents
        .where((agent) {
          if (q.isNotEmpty) {
            final haystack =
                '${agent.displayName} ${agent.email} '
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
      return 'An open invitation already exists for this email. Cancel it in '
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
      'suspended' => 'blocked',
      _ => 'updated',
    };
    setState(() => _busyId = agent.userId);
    try {
      final result = await AppLocator.adminApi.setAgentStatus(
        agent.userId,
        status,
      );
      await _load(silent: true);
      if (!mounted) return;
      setState(() => _confirmingId = null);
      _setNotice(
        '${agent.displayName} was $label.${_auditSuffix(result)}',
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

  void _openCancelInvitation(StaffInvitation invite) {
    if (!invite.isOpen || invite.invitationId.isEmpty || _revokingId != null) {
      return;
    }
    setState(() {
      _cancelInvitationId = invite.invitationId;
      _cancelInvitationError = null;
    });
    _focusOpenDialog();
  }

  void _closeCancelInvitation() {
    if (_revokingId != null) return;
    setState(() {
      _cancelInvitationId = null;
      _cancelInvitationError = null;
    });
  }

  /// Cancels only an OPEN invitation record. The staff account and any
  /// previously emailed Supabase setup link are not disabled by this endpoint.
  Future<void> _revoke(StaffInvitation invite) async {
    if (!invite.isOpen || invite.invitationId.isEmpty) {
      setState(() {
        _cancelInvitationError =
            'This invitation is no longer available for cancellation. Refresh '
            'the directory to see its current status.';
      });
      return;
    }
    if (_revokingId != null) return;

    setState(() {
      _revokingId = invite.invitationId;
      _cancelInvitationError = null;
    });
    try {
      // Retain the existing backend route; only the UI wording changes.
      final result = await AppLocator.adminApi.revokeInvitation(
        invite.invitationId,
      );
      await _load(silent: true);
      if (!mounted) return;
      setState(() {
        _cancelInvitationId = null;
        _cancelInvitationError = null;
      });
      _setNotice(
        'Invitation for ${invite.email} cancelled. The invitation record '
        'is closed, but the agent account has not been suspended or deleted. '
        'The address can be invited again.${_auditSuffix(result)}',
        error: false,
      );
    } catch (error) {
      if (!mounted) return;
      final message = AdminApi.message(error);
      setState(() => _cancelInvitationError = message);
      _setNotice(message, error: true);
    } finally {
      if (mounted) setState(() => _revokingId = null);
    }
  }

  /// Administrator-supervised MFA recovery through the existing authorised
  /// endpoint. Only verified TOTP factors are removed server-side; the agent
  /// keeps their identity, password and role, and must re-enroll on next
  /// sign-in. The reason is mandatory and is stored in the audit event.
  Future<void> _resetMfa(StaffAgent agent) async {
    final reason = _mfaReason.trim();
    if (reason.length < 3) {
      setState(() => _mfaError = 'Enter a reason of at least 3 characters.');
      return;
    }
    setState(() {
      _mfaBusy = true;
      _mfaError = null;
    });
    try {
      final result = await AppLocator.adminApi.resetAgentMfa(
        userId: agent.userId,
        reason: reason,
      );
      await _load(silent: true);
      if (!mounted) return;
      final removed = (result['removed_factors'] as List?)?.length ?? 0;
      setState(() {
        _mfaId = null;
        _mfaReason = '';
        _mfaBusy = false;
      });
      _setNotice(
        removed == 0
            ? '${agent.displayName} has no verified authenticator factor to '
                  'remove. Nothing was changed; they can enroll normally on '
                  'next sign-in.${_auditSuffix(result)}'
            : '$removed authenticator factor${removed == 1 ? '' : 's'} removed '
                  'for ${agent.displayName}. Their password and role are '
                  'unchanged; they must enroll a new authenticator on next '
                  'sign-in.${_auditSuffix(result)}',
        error: false,
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _mfaBusy = false;
        _mfaError = AdminApi.message(error);
      });
    }
  }

  Future<void> _submitInvite() async {
    setState(() {
      _validatedAgent = true;
      _wizardError = null;
    });
    if (!_agentStepValid || !_confirmed) return;
    setState(() => _submitting = true);
    try {
      final result = await AppLocator.adminApi.createAgent(
        fullName: _invName.trim(),
        email: _invEmail.trim(),
        phoneNumber: _invPhone.trim(),
        allowExisting: _allowExisting,
      );
      await _load(silent: true);
      if (!mounted) return;
      setState(() {
        _result = result;
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
      final target =
          web.document.querySelector(
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
    _validatedAgent = false;
    _invName = '';
    _invEmail = '';
    _invPhone = '';
    _allowExisting = false;
    _confirmed = false;
    _submitting = false;
    _wizardError = null;
    _result = null;
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

  void _openMfaRecovery(String userId) {
    setState(() {
      _mfaId = userId;
      _detailsId = null;
      _mfaReason = '';
      _mfaError = null;
      _mfaBusy = false;
    });
    _focusOpenDialog();
  }

  void _closeMfaRecovery() => setState(() {
    _mfaId = null;
    _mfaReason = '';
    _mfaError = null;
    _mfaBusy = false;
  });

  void _reviewInvite() {
    setState(() {
      _validatedAgent = true;
      _wizardError = null;
    });
    if (!_agentStepValid) {
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
                    '${s.suspendedAgents} blocked',
        ),
        OpsStat(
          icon: 'how_to_reg',
          label: 'Active accounts',
          value: '${s.activeAgents}',
          note: 'Agents with active access',
        ),
        OpsStat(
          icon: 'forward_to_inbox',
          label: 'Open invitations',
          value: '${s.openInvitations}',
          note: '${s.invitations} invitation records in total',
        ),
      ],
    );
  }

  Component _filters() => div(classes: 'ag-filters', [
    SearchInput(
      label: 'Search agents',
      placeholder: 'Name, email or status',
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
        _Option('suspended', 'Blocked'),
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
        _Option('revoked', 'Cancelled'),
        _Option('none', 'No invitation'),
      ],
      onChanged: (value) => setState(() => _inviteFilter = value),
    ),
  ]);

  Component _rosterPanel() {
    final showing = _filtered.length;
    return SectionCard(
      title: _loading
          ? 'Agent directory'
          : 'Agent directory · $showing of ${_agents.length} accounts',
      child: div(classes: 'stack ag-roster-panel', [
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
            ? 'No Agent accounts yet. Use “Invite agent” to send an invitation.'
            : 'No agents match these filters. Clear the search or choose a '
                  'different status to see the full roster.',
      );
    }
    return div(classes: 'ag-roster-table', [
      div(classes: 'ag-roster-summary', [
        span(classes: 'ag-roster-summary__count', [
          Component.text(
            '${rows.length} ${rows.length == 1 ? 'agent' : 'agents'} shown',
          ),
        ]),
        span(classes: 'ag-roster-summary__hint', [
          Component.text('Select View details to manage an account'),
        ]),
      ]),
      DataTable(
        scrollLabel: 'Agent roster',
        columns: const [
          DataColumn('Agent'),
          DataColumn('Account status'),
          DataColumn('Invitation status'),
          DataColumn('Joined'),
          DataColumn('Actions', actions: true),
        ],
        rows: [
          for (final agent in rows)
            [
              div(classes: 'ag-agent', [
                span(
                  classes: 'ag-agent__avatar',
                  attributes: const {'aria-hidden': 'true'},
                  [Component.text(_agentInitials(agent.displayName))],
                ),
                div(classes: 'ag-agent__text', [
                  CellIdentity(
                    title: agent.displayName.isEmpty
                        ? 'Unnamed agent'
                        : agent.displayName,
                    caption: agent.email,
                  ),
                ]),
              ]),
              agent.status.isEmpty
                  ? const StatusBadge('Unknown', tone: 'neutral')
                  : StatusBadge(
                      _label(agent.status),
                      tone: _tone(agent.status),
                      dot: true,
                    ),
              agent.invitationStatus.isEmpty
                  ? const StatusBadge('None', tone: 'neutral')
                  : StatusBadge(
                      _label(agent.invitationStatus),
                      tone: _tone(agent.invitationStatus),
                      dot: true,
                    ),
              Component.text(_shortDate(agent.createdAt)),
              div(classes: 'ag-actions', [
                ActionButton(
                  'View details',
                  variant: 'ghost',
                  onClick: () => _openDetails(agent.userId),
                ),
                _statusAction(agent),
              ]),
            ],
        ],
      ),
    ]);
  }

  Component _statusAction(StaffAgent agent) {
    if (_busyId == agent.userId) {
      return span(classes: 'ag-muted', [Component.text('Working…')]);
    }
    final status = agent.status.toLowerCase();
    if (status == 'suspended') {
      return ActionButton(
        'Unblock account',
        variant: 'secondary',
        onClick: () => _openConfirm(agent.userId),
      );
    }
    if (status == 'pending') {
      return ActionButton(
        'Activate',
        onClick: () => _setStatus(agent, 'active'),
      );
    }
    return ActionButton(
      'Block account',
      variant: 'danger-outline',
      onClick: () => _openConfirm(agent.userId),
    );
  }

  Component _invitationsPanel() {
    return SectionCard(
      title: 'Agent invitations',
      child: _loading
          ? const Skeleton(variant: 'row', count: 3)
          : _invitations.isEmpty
          ? InlineEmpty('No Agent invitations yet.')
          : DataTable(
              scrollLabel: 'Agent invitations',
              columns: const [
                DataColumn('Invited address'),
                DataColumn('Role'),
                DataColumn('State'),
                DataColumn('Created'),
                DataColumn('Expires'),
                DataColumn('Actions', actions: true),
              ],
              rows: [
                for (final invite in _invitations)
                  [
                    Component.text(invite.email),
                    Component.text(
                      invite.invitedRole == 'owner'
                          ? 'Property Owner'
                          : invite.invitedRole == 'agent'
                          ? 'Agent'
                          : 'Unknown',
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
                          'Cancel invitation',
                          variant: 'danger-outline',
                          onClick: _revokingId == null
                              ? () => _openCancelInvitation(invite)
                              : null,
                        )
                      else
                        span(classes: 'ag-muted', [
                          Component.text(switch (invite.status.toLowerCase()) {
                            'accepted' => 'Completed',
                            'revoked' => 'Cancelled',
                            'expired' => 'Expired',
                            _ => '—',
                          }),
                        ]),
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

  Component _agentStep() => div(classes: 'stack', [
    p(classes: 'body', [
      Component.text(
        'The Agent sets their password using the invitation link.',
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
      hint: 'For account contact',
      child: _textInput(
        value: _invPhone,
        placeholder: '+60 12 345 6789',
        type: InputType.tel,
        autocomplete: 'tel',
        invalid: false,
        onInput: (value) => setState(() => _invPhone = value),
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
          'Grant Agent access to an existing account with this email.',
        ),
      ]),
    ]),
  ]);

  Component _reviewStep() => div(classes: 'stack', [
    p(classes: 'body', [
      Component.text('Review the details before sending the invitation.'),
    ]),
    div(classes: 'ag-review', [
      InfoRow(icon: 'person', label: 'Full name', value: _invName.trim()),
      InfoRow(icon: 'mail', label: 'Work email', value: _invEmail.trim()),
      InfoRow(
        icon: 'call',
        label: 'Phone',
        value: _invPhone.trim().isEmpty ? 'Not provided' : _invPhone.trim(),
      ),
      InfoRow(icon: 'badge', label: 'Role', value: 'Agent'),
      InfoRow(
        icon: 'lock',
        label: 'Password',
        value: 'Set by the Agent using the invitation link',
      ),
    ]),
    Callout(
      'The Agent will receive an email with a link to set up their account.',
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
          'I have reviewed the Agent details and approve this '
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
            invited ? 'Invitation sent.' : 'Agent access granted.',
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
              ? 'Agent access granted to an existing account'
              : status.isEmpty
              ? 'No invitation record was returned — check the invitations table'
              : _label(status),
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
        'The Agent must complete account setup before activation.',
        icon: 'shield',
      ),
    ]);
  }

  /// One complete entry form — no hidden email field on a later page.
  Component _invitationForm() => div(classes: 'ag-invite-form', [
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
          onClick: _submitting ? null : _reviewInvite,
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

  Component _workload(StaffAgent agent) {
    final rows = agent.assignedProperties;
    int count(String state) => rows.where((row) => row.status == state).length;
    return div(classes: 'stack ag-workload', [
      h3([Component.text('Inspection workload')]),
      p([
        Component.text(
          '${rows.length - count('declined')} assigned · '
          '${count('ongoing') + count('needs_correction')} ongoing · '
          '${count('pending_review')} pending Admin review · '
          '${count('completed')} completed',
        ),
      ]),
      if (rows.isEmpty)
        const InlineEmpty('No property assignments yet.')
      else
        DataTable(
          scrollLabel: 'Assigned properties',
          columns: const [
            DataColumn('Property'),
            DataColumn('Inspection status'),
          ],
          rows: [
            for (final row in rows)
              [
                a(
                  href:
                      '/admin/listing-detail?id=${Uri.encodeComponent(row.id)}',
                  [Component.text(row.name)],
                ),
                Component.text(switch (row.status) {
                  'requested' => 'Awaiting Agent response',
                  'ongoing' => 'In progress',
                  'pending_review' => 'Pending Admin review',
                  'completed' => 'Completed',
                  'needs_correction' => 'Needs correction',
                  'declined' => 'Declined',
                  _ => 'Status unavailable',
                }),
              ],
          ],
        ),
    ]);
  }

  Component _detailsDialog() {
    final agent = _agents.where((row) => row.userId == _detailsId).firstOrNull;
    if (agent == null) return const span([]);
    return SitewiseDialog(
      title: agent.displayName,
      ariaLabel: 'Agent details',
      wide: true,
      panelClass: 'ag-details-dialog',
      onClose: () => setState(() => _detailsId = null),
      body: div(classes: 'ag-review', [
        InfoRow(icon: 'mail', label: 'Email', value: agent.email),
        InfoRow(icon: 'person', label: 'Full name', value: agent.fullName),
        InfoRow(
          icon: 'call',
          label: 'Phone',
          value: agent.phone.isEmpty ? 'Not provided' : agent.phone,
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
        _workload(agent),
      ]),
      actions: [
        ActionButton(
          'Close',
          variant: 'secondary',
          onClick: () => setState(() => _detailsId = null),
        ),
        ActionButton(
          'Reset two-step verification',
          variant: 'secondary',
          icon: 'lock_reset',
          onClick: () => _openMfaRecovery(agent.userId),
        ),
        _statusAction(agent),
      ],
    );
  }

  Component _mfaDialog() {
    final agent = _agents.where((row) => row.userId == _mfaId).firstOrNull;
    if (agent == null) return const span([]);
    final canSubmit = !_mfaBusy && _mfaReason.trim().length >= 3;
    return SitewiseDialog(
      title: 'Reset MFA for ${agent.displayName}?',
      ariaLabel: 'Confirm MFA recovery',
      onClose: _mfaBusy ? _noop : _closeMfaRecovery,
      body: div(classes: 'stack', [
        p(classes: 'body', [
          Component.text(
            'Removes the verified authenticator factors on ${agent.email} so '
            'they can enroll a new device. Their password, role and account '
            'status are unchanged, and no recovery code or factor secret is '
            'shown to you. Until they re-enroll, staff routes that require MFA '
            'will send them to the enrollment screen. The reset is recorded in '
            'the audit log with your administrator identity and this reason.',
          ),
        ]),
        if (_mfaError != null)
          div(
            attributes: const {'role': 'alert'},
            [ActionNotice(_mfaError!, tone: 'danger')],
          ),
        Field(
          labelText: 'Reason (required)',
          error: _mfaError,
          hint:
              'Stored in the audit event, e.g. "Lost phone, identity verified by phone".',
          child: _textInput(
            value: _mfaReason,
            placeholder: 'Why is this reset authorised?',
            invalid: _mfaError != null,
            onInput: (value) => setState(() => _mfaReason = value),
          ),
        ),
      ]),
      actions: [
        ActionButton(
          'Cancel',
          variant: 'secondary',
          onClick: _mfaBusy ? null : _closeMfaRecovery,
        ),
        ActionButton(
          _mfaBusy ? 'Resetting…' : 'Remove authenticator factors',
          variant: 'danger-outline',
          onClick: canSubmit ? () => _resetMfa(agent) : null,
        ),
      ],
    );
  }

  Component _cancelInvitationDialog() {
    final invite = _invitations
        .where((row) => row.invitationId == _cancelInvitationId)
        .firstOrNull;
    if (invite == null) return const span([]);
    return SitewiseDialog(
      title: 'Cancel invitation?',
      ariaLabel: 'Confirm invitation cancellation',
      onClose: _revokingId == null ? _closeCancelInvitation : _noop,
      body: div(classes: 'stack', [
        p(classes: 'body', [
          Component.text(
            'Cancel the open invitation for ${invite.email}? This closes '
            'the invitation record so a new invitation can be issued. It '
            'does not delete or suspend an agent account, and it does not '
            'invalidate a setup link that was already emailed.',
          ),
        ]),
        if (_cancelInvitationError != null)
          div(
            attributes: const {'role': 'alert'},
            [ActionNotice(_cancelInvitationError!, tone: 'danger')],
          ),
      ]),
      actions: [
        ActionButton(
          'Keep invitation',
          variant: 'secondary',
          onClick: _revokingId == null ? _closeCancelInvitation : null,
        ),
        ActionButton(
          _revokingId == invite.invitationId
              ? 'Cancelling…'
              : 'Cancel invitation',
          variant: 'danger-outline',
          onClick: _revokingId == null && invite.isOpen
              ? () => _revoke(invite)
              : null,
        ),
      ],
    );
  }

  Component _confirmDialog() {
    final agent = _agents
        .where((row) => row.userId == _confirmingId)
        .firstOrNull;
    if (agent == null) return const span([]);
    final restoring = agent.status.toLowerCase() == 'suspended';
    final action = restoring ? 'Unblock account' : 'Block account';
    return SitewiseDialog(
      title: '$action?',
      ariaLabel: action,
      onClose: () => setState(() => _confirmingId = null),
      body: div(classes: 'stack', [
        p(classes: 'body', [
          Component.text(
            restoring
                ? '${agent.email} will regain access with the same Agent role. '
                      'They still need to meet the usual sign-in requirements.'
                : '${agent.email} will lose access to the Agent workspace. '
                      'Their account and invitation history will be kept.',
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
          action,
          variant: restoring ? 'primary' : 'danger-outline',
          onClick: () => _setStatus(agent, restoring ? 'active' : 'suspended'),
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
      subtitle: 'Manage Agent access, invitations and inspection workloads.',
      actions: [
        ActionButton('Refresh', variant: 'secondary', onClick: _load),
        ActionButton('Invite agent', icon: 'add', onClick: _openInvite),
      ],
      child: div(classes: 'stack stack--sections ag ops-fade', [
        _metrics(),
        _rosterPanel(),
        _invitationsPanel(),
        if (_inviteOpen) _inviteDialog(),
        if (_detailsId != null) _detailsDialog(),
        if (_confirmingId != null) _confirmDialog(),
        if (_cancelInvitationId != null) _cancelInvitationDialog(),
        if (_mfaId != null) _mfaDialog(),
      ]),
    );
  }
}
