import 'dart:async';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import '../data/admin_api.dart';
import '../data/app_locator.dart';
import 'ui.dart';

/// Administrator queue for **agent-proposed listing changes** (workflow B).
///
/// Deliberately separate from the property-verification queue (workflow A):
/// this panel reads `GET /api/v1/staff/change-requests` and decides through
/// `POST /api/v1/staff/listings/{id}/change-requests/{rid}/decision`.
/// Approving here never changes ownership verification, listing verification
/// or publication — those stay with their own workflow.
///
/// The table shows the LIVE value captured when the agent proposed the change
/// (`from`) next to the proposal (`to`); the backend re-checks both against
/// the current row at approval time and refuses a stale approval with 409, so
/// the reviewer sees the conflict message instead of silently overwriting
/// newer data.
@client
class AgentChangeRequestsPanel extends StatefulComponent {
  const AgentChangeRequestsPanel({super.key});

  @override
  State<AgentChangeRequestsPanel> createState() =>
      _AgentChangeRequestsPanelState();
}

class _AgentChangeRequestsPanelState extends State<AgentChangeRequestsPanel> {
  List<Map<String, dynamic>> _requests = const [];
  String _status = 'pending';
  bool _loading = true;
  String? _error;
  String? _busyId;
  final Map<String, String> _notes = {};

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rows = await AppLocator.adminApi.listChangeRequests(
        status: _status,
      );
      if (!mounted) return;
      setState(() {
        _requests = rows;
        _loading = false;
      });
    } catch (err) {
      if (!mounted) return;
      setState(() {
        _error = AdminApi.message(err);
        _loading = false;
      });
    }
  }

  Future<void> _decide(Map<String, dynamic> request, String decision) async {
    final requestId = '${request['change_request_id'] ?? ''}';
    final listingId = (request['listing_id'] as num?)?.toInt();
    if (requestId.isEmpty || listingId == null) return;
    setState(() {
      _busyId = requestId;
      _error = null;
    });
    try {
      await AppLocator.adminApi.decideChangeRequest(
        listingId: listingId,
        requestId: requestId,
        decision: decision,
        note: _notes[requestId],
      );
      await _load();
    } catch (err) {
      if (!mounted) return;
      setState(() {
        _error = AdminApi.message(err);
        _busyId = null;
      });
    }
  }

  @override
  Component build(BuildContext context) {
    return div(classes: 'stack stack--sections', [
      div(classes: 'row row--between', [
        div(classes: 'stack', [
          span(classes: 'title', [Component.text('Agent change requests')]),
          p(classes: 'body muted', [
            Component.text(
              'Proposals submitted by agents for their assigned listings. '
              'Approving applies only the proposed fields to the operational '
              'property; ownership, listing verification and publication are '
              'decided elsewhere.',
            ),
          ]),
        ]),
        div(classes: 'actions-row', [
          for (final entry in const [
            ('pending', 'Pending'),
            ('changes_requested', 'Changes requested'),
            ('approved', 'Approved'),
            ('rejected', 'Rejected'),
            ('all', 'All'),
          ])
            ActionButton(
              entry.$2,
              variant: _status == entry.$1 ? 'primary' : 'secondary',
              onClick: () {
                setState(() => _status = entry.$1);
                unawaited(_load());
              },
            ),
        ]),
      ]),
      if (_error != null)
        div(classes: 'notice notice-danger', [Component.text(_error!)]),
      if (_loading)
        div(classes: 'loading', [
          span(classes: 'spinner', []),
          Component.text('Loading change requests…'),
        ])
      else if (_requests.isEmpty)
        const EmptyState(
          title: 'No change requests',
          body:
              'When an agent saves and submits a proposal for an assigned '
              'listing, it appears here for a decision.',
        )
      else
        for (final request in _requests) _requestCard(request),
    ]);
  }

  Component _requestCard(Map<String, dynamic> request) {
    final requestId = '${request['change_request_id'] ?? ''}';
    final property = (request['property'] as Map<String, dynamic>?) ?? const {};
    final agent = (request['agent'] as Map<String, dynamic>?) ?? const {};
    final changes = (request['changes'] as Map<String, dynamic>?) ?? const {};
    final status = '${request['status'] ?? ''}';
    final busy = _busyId == requestId;
    final propertyExists = property['property_exists'] == true;

    return div(classes: 'card card-pad stack', [
      div(classes: 'row row--between', [
        div(classes: 'stack', [
          span(classes: 'title', [
            Component.text(
              '${property['name'] ?? 'Listing ${request['listing_id']}'} '
              '· #${request['listing_id']}',
            ),
          ]),
          p(classes: 'body muted', [
            Component.text(
              [
                if (agent['agent_name'] != null)
                  'Agent: ${agent['agent_name']}',
                if (property['address'] != null) '${property['address']}',
                if (property['city'] != null) '${property['city']}',
              ].join(' · '),
            ),
          ]),
        ]),
        span(classes: 'chip', [Component.text(status.replaceAll('_', ' '))]),
      ]),
      if (!propertyExists)
        div(classes: 'notice notice-danger', [
          Component.text(
            'The operational property for this assignment no longer exists; '
            'the request cannot be approved.',
          ),
        ]),
      if ((request['reason'] as String?)?.isNotEmpty == true)
        p(classes: 'body', [Component.text('Reason: ${request['reason']}')]),
      _changesTable(changes),
      p(classes: 'small muted', [
        Component.text(
          'Submitted ${_short(request['created_at'])} · '
          'last updated ${_short(request['updated_at'])}',
        ),
      ]),
      if (status == 'pending')
        div(classes: 'stack', [
          input(
            attributes: {
              'type': 'text',
              'placeholder': 'Review note (required for reject / changes)',
              'aria-label': 'Review note',
              'value': _notes[requestId] ?? '',
            },
            events: events<String>(
              onInput: (value) => _notes[requestId] = value,
            ),
          ),
          div(classes: 'actions-row', [
            ActionButton(
              busy ? 'Working…' : 'Approve',
              variant: 'primary',
              onClick: busy
                  ? null
                  : () => unawaited(_decide(request, 'approve')),
            ),
            ActionButton(
              'Reject',
              variant: 'secondary',
              onClick: busy
                  ? null
                  : () => unawaited(_decide(request, 'reject')),
            ),
            ActionButton(
              'Request changes',
              variant: 'secondary',
              onClick: busy
                  ? null
                  : () => unawaited(_decide(request, 'changes_requested')),
            ),
          ]),
        ])
      else if ((request['review_note'] as String?)?.isNotEmpty == true)
        p(classes: 'body muted', [
          Component.text('Review note: ${request['review_note']}'),
        ]),
    ]);
  }

  Component _changesTable(Map<String, dynamic> changes) {
    if (changes.isEmpty) {
      return p(classes: 'body muted', [Component.text('No field changes.')]);
    }
    return div(classes: 'stack', [
      for (final entry in changes.entries)
        div(classes: 'row row--between', [
          span(classes: 'small', [
            Component.text(entry.key.replaceAll('_', ' ')),
          ]),
          span(classes: 'small muted', [
            Component.text(
              '${_value((entry.value as Map?)?['from'])} → '
              '${_value((entry.value as Map?)?['to'])}',
            ),
          ]),
        ]),
    ]);
  }

  static String _value(Object? raw) {
    if (raw == null) return '—';
    if (raw is bool) return raw ? 'yes' : 'no';
    return '$raw';
  }

  static String _short(Object? iso) {
    final text = '${iso ?? ''}';
    return text.length >= 16
        ? '${text.substring(0, 10)} ${text.substring(11, 16)}'
        : text;
  }
}
