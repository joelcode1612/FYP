import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/admin_ops_kit.dart';
import '../../components/dashboard_kit.dart';
import '../../components/ui.dart';
import '../../data/admin_api.dart';
import '../../data/app_locator.dart';
import '../../layouts/app_layout.dart';

/// System activity — the administrator's operational timeline.
///
/// ## What is real
///
/// The feed is `GET /api/v1/staff/audit`: the backend's `role_change_audit`
/// table, newest first, written by privileged operations themselves (agent
/// invites, suspensions, reactivations, MFA factor resets, listing
/// assignment). Each row carries the acting administrator and the affected
/// account, so every line is attributable server-side — the browser never
/// contributes an event.
///
/// ## Stated limits (the page says them too)
///
/// * The endpoint returns the **most recent 200 rows** (server commit —
///   `list_role_audit` limits to 200); this is an operations feed, not an
///   immutable security log, and the page never calls it one.
/// * Only the one optional server-side filter exists:
///   `?affected_user_id=`. Broader search/filtering happens on the rows the
///   API returned, in the browser.
/// * Audit is unavailable whenever the identity backend is — the load fails
///   loudly with the server's sentence instead of rendering an empty
///   timeline that would read as "nothing happened".
@client
class AdminActivityPage extends StatefulComponent {
  const AdminActivityPage({super.key});

  @override
  State<AdminActivityPage> createState() => _ActivityState();
}

class _ActivityState extends State<AdminActivityPage> {
  bool _loading = true;
  String? _error;
  List<AuditEvent> _events = const [];

  String _query = '';
  String _filter = 'All';
  String _accountInput = '';
  String? _activeAccount;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final events = await AppLocator.adminApi.listAudit(
        affectedUserId: _activeAccount,
      );
      if (!mounted) return;
      setState(() {
        _events = events;
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

  /// Re-runs the fetch with the server-side `affected_user_id` filter — the
  /// one filter the API itself supports, so it must reload rather than slice
  /// rows the browser never received.
  void _applyAccountFilter() {
    final trimmed = _accountInput.trim();
    setState(() => _activeAccount = trimmed.isEmpty ? null : trimmed);
    _load();
  }

  /// Chip label → the action prefixes it selects. Anything unmatched stays
  /// visible under "All" rather than being silently dropped by a filter the
  /// reader cannot see.
  static const Map<String, List<String>> _groups = {
    'All': <String>[],
    'Staff access': ['staff'],
    'Listings': ['listing'],
    'Roles & status': ['role', 'status'],
    'MFA': ['mfa'],
  };

  List<AuditEvent> get _visible {
    final prefixes = _groups[_filter] ?? const <String>[];
    final q = _query.trim().toLowerCase();
    return _events
        .where((event) {
          final matchesKind =
              prefixes.isEmpty || prefixes.contains(event.group);
          if (!matchesKind) return false;
          if (q.isEmpty) return true;
          return '${event.action} ${event.subject} ${event.performedByEmail} '
                  '${event.previousStatus ?? ''} ${event.newStatus ?? ''} '
                  '${event.previousRole ?? ''} ${event.newRole ?? ''}'
              .toLowerCase()
              .contains(q);
        })
        .toList(growable: false);
  }

  /// `2026-11-06T10:24:31+00:00` → `6 Nov · 10:24`. Unparseable stamps are
  /// passed through verbatim rather than shown as the epoch.
  static String _when(String iso) {
    final parsed = DateTime.tryParse(iso);
    if (parsed == null) return iso.isEmpty ? 'Time not recorded' : iso;
    final local = parsed.toLocal();
    const months = [
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
    const days = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    return '${days[local.weekday % 7]} ${local.day} '
        '${months[local.month - 1]} · $hh:$mm';
  }

  /// Human tone for the chip badge beside an event: key actions read as
  /// access changes, destructive ones get the danger tone.
  String _tone(String action) {
    if (action.contains('suspend')) return 'danger';
    if (action.contains('invite') || action.contains('granted')) {
      return 'action';
    }
    if (action.contains('reset') || action.contains('assigned')) {
      return 'warning';
    }
    return 'neutral';
  }

  String _groupLabel(String group) => switch (group) {
    'staff' => 'Staff access',
    'listing' => 'Listings',
    'role' => 'Roles',
    'status' => 'Status',
    'mfa' => 'MFA',
    _ => 'System',
  };

  // --- Fragments ------------------------------------------------------------

  Component _timelineBody() {
    if (_loading) return const Skeleton(variant: 'row', count: 5);
    if (_error != null) {
      return div(classes: 'stack', [
        Callout(
          'The audit feed could not be read: $_error',
          tone: 'danger',
          icon: 'error',
        ),
        p(classes: 'ops-qrow__meta', [
          Component.text(
            'This is usually the identity backend being unreachable from '
            'this environment — not an empty log. Retrying is safe; nothing '
            'is written by a read.',
          ),
        ]),
        ActionButton('Try again', variant: 'secondary', onClick: _load),
      ]);
    }
    final rows = _visible;
    if (rows.isEmpty) {
      return InlineEmpty(
        _events.isEmpty
            ? 'The audit table returned no events yet: no privileged action '
                  'has been recorded for this deployment.'
            : 'No events match this filter.',
      );
    }
    return div(classes: 'ops-ev-list', [
      for (final event in rows)
        TimelineEntry(
          icon: event.group == 'listing' ? 'business' : 'shield',
          title: event.action,
          subject: event.subject,
          meta: [
            if (event.performedByEmail.isNotEmpty) event.performedByEmail,
            _when(event.createdAt),
            if (event.newStatus != null)
              '${event.previousStatus ?? '—'} → ${event.newStatus!}',
            if (event.newRole != null)
              '${event.previousRole ?? '—'} → ${event.newRole!}',
          ].join(' · '),
          badge: StatusBadge(
            _groupLabel(event.group),
            tone: _tone(event.action),
          ),
        ),
    ]);
  }

  @override
  Component build(BuildContext context) {
    return AppLayout(
      role: AppRole.admin,
      currentRoute: '/admin/activity',
      title: 'System activity',
      eyebrow: 'Operations',
      subtitle:
          'Privileged actions in one timeline: who did what to which '
          'account, as recorded by the server when the action happened.',
      actions: [ActionButton('Refresh', variant: 'secondary', onClick: _load)],
      child: div(classes: 'stack ops-fade', [
        Callout(
          'This is the backend’s role-change audit (most recent 200 events). '
          'Failures are shown, never papered over: an unreadable feed does '
          'not mean nothing happened.',
          icon: 'history',
        ),
        SectionCard(
          title: 'Activity timeline',
          child: div(classes: 'stack', [
            SearchInput(
              label: 'Search activity',
              placeholder: 'Action, account or administrator',
              ariaLabel: 'Search activity',
              onInput: (value) => setState(() => _query = value),
            ),
            ChipRow(
              options: const [
                'All',
                'Staff access',
                'Listings',
                'Roles & status',
                'MFA',
              ],
              selected: _filter,
              ariaLabel: 'Filter activity by kind',
              onSelect: (value) => setState(() => _filter = value),
            ),
            div(classes: 'filters', [
              div(classes: 'grid-3', [
                Field(
                  labelText: 'Affected account (optional)',
                  hint: 'Server-side filter: a user id (UUID)',
                  child: input(
                    type: InputType.text,
                    attributes: const {'placeholder': 'e.g. 3f2c…-…-…'},
                    events: events<String>(
                      onInput: (value) => _accountInput = value,
                    ),
                  ),
                ),
                div(classes: 'ops-card__actions', [
                  ActionButton(
                    'Filter by account',
                    variant: 'secondary',
                    onClick: _applyAccountFilter,
                  ),
                  if (_activeAccount != null)
                    ActionButton(
                      'Clear account filter',
                      variant: 'ghost',
                      onClick: () => setState(() {
                        _accountInput = '';
                        _activeAccount = null;
                      }),
                    ),
                ]),
              ]),
            ]),
            if (_activeAccount != null)
              p(classes: 'ops-qrow__meta', [
                Component.text(
                  'Showing only events whose affected account is '
                  '$_activeAccount.',
                ),
              ]),
            _timelineBody(),
          ]),
        ),
      ]),
    );
  }
}
