import 'dart:async';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import '../data/admin_api.dart';
import '../data/app_locator.dart';
import 'ui.dart';

/// Administrator control: assign one operational property to an agent.
///
/// Reads the FK-backed assignment table through
/// `GET /api/v1/staff/assignments` and writes through
/// `POST|DELETE /api/v1/staff/listings/{id}/assign`. Only agents with a real
/// Supabase profile are listed; the assignment row itself is keyed by the
/// property primary key, so a non-existent property is refused server-side
/// (404) instead of creating a phantom assignment.
@client
class AgentAssignmentControl extends StatefulComponent {
  /// Operational property id (`fyp.rental_properties.id`), as a string from
  /// the admin route.
  final String propertyId;

  const AgentAssignmentControl({super.key, required this.propertyId});

  @override
  State<AgentAssignmentControl> createState() => _AgentAssignmentControlState();
}

class _AgentAssignmentControlState extends State<AgentAssignmentControl> {
  List<StaffAgent> _agents = const [];
  Map<String, dynamic>? _assignment;
  String _selectedUserId = '';
  bool _loading = true;
  bool _busy = false;
  String? _error;
  String? _status;

  int? get _listingId => int.tryParse(component.propertyId);

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final listingId = _listingId;
    if (listingId == null) {
      setState(() {
        _loading = false;
        _error = 'This property id is not numeric; assignment is unavailable.';
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final agents = await AppLocator.adminApi.listAgents();
      final assignments = await AppLocator.adminApi.listAssignments();
      final current = assignments.firstWhere(
        (row) => (row['listing_id'] as num?)?.toInt() == listingId,
        orElse: () => const <String, dynamic>{},
      );
      if (!mounted) return;
      setState(() {
        _agents = agents.where((agent) => agent.agentId.isNotEmpty).toList();
        _assignment = current.isEmpty ? null : current;
        _loading = false;
        final currentUserId = _agents
            .where(
              (agent) =>
                  _assignment != null &&
                  '${_assignment!['agent_id']}' == agent.agentId,
            )
            .map((agent) => agent.userId)
            .cast<String?>()
            .firstWhere((_) => true, orElse: () => null);
        _selectedUserId = currentUserId ?? _selectedUserId;
      });
    } catch (err) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = AdminApi.message(err);
      });
    }
  }

  Future<void> _assign() async {
    final listingId = _listingId;
    if (listingId == null || _selectedUserId.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
      _status = null;
    });
    try {
      final row = await AppLocator.adminApi.assignListing(
        listingId: listingId,
        agentUserId: _selectedUserId,
      );
      if (!mounted) return;
      setState(() {
        _busy = false;
        _assignment = row;
        _status = 'Assigned to agent #${row['agent_id']}.';
      });
    } catch (err) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = AdminApi.message(err);
      });
    }
  }

  Future<void> _unassign() async {
    final listingId = _listingId;
    if (listingId == null) return;
    setState(() {
      _busy = true;
      _error = null;
      _status = null;
    });
    try {
      await AppLocator.adminApi.unassignListing(listingId);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _assignment = null;
        _status = 'Assignment removed. The property itself is unchanged.';
      });
    } catch (err) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = AdminApi.message(err);
      });
    }
  }

  @override
  Component build(BuildContext context) {
    final assignedAgentId = _assignment?['agent_id'];
    final assignedName = _agents
        .where((agent) => '${assignedAgentId ?? ''}' == agent.agentId)
        .map((agent) => agent.fullName)
        .cast<String?>()
        .firstWhere((_) => true, orElse: () => null);
    return div(classes: 'card card-pad stack', [
      span(classes: 'title', [Component.text('Agent assignment')]),
      p(classes: 'body muted', [
        Component.text(
          'Assign this operational property to an agent. The agent can then '
          'manage only this listing and submit change requests for review.',
        ),
      ]),
      if (_loading)
        p(classes: 'body muted', [Component.text('Loading agents…')])
      else ...[
        p(classes: 'body', [
          Component.text(
            _assignment == null
                ? 'Currently unassigned.'
                : 'Currently assigned to '
                      '${assignedName ?? 'agent #$assignedAgentId'}'
                      '${_assignment!['property_exists'] == false ? ' — operational property missing' : ''}.',
          ),
        ]),
        if (_error != null)
          div(classes: 'notice notice-danger', [Component.text(_error!)]),
        if (_status != null)
          div(classes: 'notice notice-info', [Component.text(_status!)]),
        if (_agents.isEmpty)
          p(classes: 'body muted', [
            Component.text(
              'No agent profiles exist yet. Create an agent account first.',
            ),
          ])
        else ...[
          select(
            attributes: {'aria-label': 'Agent to assign'},
            events: events<List<String>>(
              onInput: (values) =>
                  _selectedUserId = values.isEmpty ? '' : values.first,
            ),
            [
              option(value: '', [Component.text('Select an agent…')]),
              for (final agent in _agents)
                option(
                  value: agent.userId,
                  attributes: agent.userId == _selectedUserId
                      ? const {'selected': ''}
                      : null,
                  [Component.text('${agent.fullName} · ${agent.email}')],
                ),
            ],
          ),
          div(classes: 'actions-row', [
            ActionButton(
              _busy ? 'Working…' : 'Assign / reassign',
              variant: 'primary',
              onClick: _busy || _selectedUserId.isEmpty
                  ? null
                  : () => unawaited(_assign()),
            ),
            if (_assignment != null)
              ActionButton(
                'Remove assignment',
                variant: 'secondary',
                onClick: _busy ? null : () => unawaited(_unassign()),
              ),
          ]),
        ],
      ],
    ]);
  }
}
