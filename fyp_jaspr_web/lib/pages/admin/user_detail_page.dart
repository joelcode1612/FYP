import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/ui.dart';
import '../../data/app_locator.dart';
import '../../data/auth_service.dart';
import '../../layouts/app_layout.dart';

/// Simplified Sitewise Admin user detail.
///
/// Four sections only: user summary, user information, role & status, and the
/// page actions (Back to Users / Save Changes). The record still comes from
/// [AppLocator.userRepo] through the unchanged `UserDetailPage(id: userId)`
/// constructor and the existing
/// `AppLayout(role: AppRole.admin, currentRoute: '/admin/users')` chrome.
///
/// Saving uses the existing authorised administrative operation
/// `PATCH /api/v1/users/{id}` (`backend/src/sitewise/api/v1/users.py`). That
/// endpoint is guarded by `require_admin_mfa`, validates the role/status
/// vocabularies, syncs the identity row and writes `role_change_audit`
/// server-side. [_UserDetailPageState._isAdmin] is only a presentation guard;
/// FastAPI remains the authority. Nothing here reads or stores credentials.
@client
class UserDetailPage extends StatefulComponent {
  final String id;

  const UserDetailPage({super.key, required this.id});

  @override
  State<UserDetailPage> createState() => _UserDetailPageState();
}

/// Backend values are lowercase; the second element of each pair is the label.
/// These are exactly `rbac.ALL_ROLES` and `rbac.ACCOUNT_STATUSES`.
const List<(String, String)> _roles = [
  ('entrepreneur', 'Entrepreneur'),
  ('agent', 'Agent'),
  ('admin', 'Administrator'),
];

const List<(String, String)> _statuses = [
  ('pending', 'Pending'),
  ('active', 'Active'),
  ('suspended', 'Suspended'),
];

class _UserDetailPageState extends State<UserDetailPage> {
  late Future<_UserRecord?> _future;

  /// Last server-confirmed values. The selected values are compared against
  /// these, never against a locally optimistic copy.
  String _savedRole = 'entrepreneur';
  String _savedStatus = 'pending';
  String _role = 'entrepreneur';
  String _status = 'pending';

  bool _saving = false;
  String? _notice;
  bool _noticeIsError = false;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  /// Presentation-only guard. The API independently enforces administrator +
  /// aal2 on every read and write, and the workspace router guard already
  /// keeps non-administrators out of `/admin/*`.
  bool get _isAdmin {
    final raw = (WebAuth.profile?['role'] as String?)?.toLowerCase().trim();
    return raw == 'admin' || raw == 'administrator';
  }

  Future<_UserRecord?> _load() async {
    final id = component.id.trim();
    if (id.isEmpty) return null;

    // Existing repository contract — no new API surface, no demo records.
    final user = await AppLocator.userRepo.getUserById(id);
    if (user == null) return null;

    // `SitewiseUser` (shared_logic) exposes neither phone_number nor
    // last_login, and shared_logic cannot be changed from this file. Read
    // those two optional fields from the SAME authorised `/users/{id}`
    // payload through the existing bearer-aware bridge. A failure of this
    // secondary read is non-fatal: the fields simply show "Not provided".
    Map<String, dynamic> extra = const <String, dynamic>{};
    try {
      extra = await WebAuth.request('/api/v1/users/${Uri.encodeComponent(id)}');
    } catch (_) {
      extra = const <String, dynamic>{};
    }

    _savedRole = _roleValue(user.role);
    _savedStatus = _statusValue(user.status);
    _role = _savedRole;
    _status = _savedStatus;

    return _UserRecord(
      user: user,
      phone: _text(extra['phone_number']),
      lastLogin: _text(extra['last_login']),
    );
  }

  Future<void> _save() async {
    if (_saving || !_isAdmin) return;
    // Only changed fields are sent, so an untouched record never triggers an
    // update (and never creates an audit event).
    final body = <String, dynamic>{
      if (_role != _savedRole) 'role': _role,
      if (_status != _savedStatus) 'account_status': _status,
    };
    if (body.isEmpty) return;

    setState(() {
      _saving = true;
      _notice = null;
      _noticeIsError = false;
    });

    try {
      final response = await WebAuth.request(
        '/api/v1/users/${Uri.encodeComponent(component.id.trim())}',
        method: 'PATCH',
        body: body,
      );
      if (!mounted) return;

      // Success is shown only when the server echoes back the values we asked
      // for. A 403/422 is thrown by the bridge; a partial or unexpected
      // response is treated as unconfirmed rather than as a save.
      final echoedRole = _canonicalRole(response['role'] as String?);
      final echoedStatus =
          (response['account_status'] as String?)?.toLowerCase().trim();
      final confirmed =
          (!body.containsKey('role') || echoedRole == _role) &&
          (!body.containsKey('account_status') || echoedStatus == _status);

      if (!confirmed) {
        setState(() {
          _saving = false;
          _noticeIsError = true;
          _notice = 'The server did not confirm these changes. Nothing was '
              'marked as saved.';
        });
        return;
      }

      setState(() {
        _savedRole = _role;
        _savedStatus = _status;
        _saving = false;
        _noticeIsError = false;
        _notice = 'Changes saved. The server recorded the role and account '
            'status change in its audit trail.';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _noticeIsError = true;
        _notice = 'Could not save changes. Check administrator permissions '
            'and MFA, then try again.';
      });
    }
  }

  void _setRole(String value) => setState(() {
    _role = value;
    _notice = null;
  });

  void _setStatus(String value) => setState(() {
    _status = value;
    _notice = null;
  });

  @override
  Component build(BuildContext context) {
    return AppLayout(
      role: AppRole.admin,
      currentRoute: '/admin/users',
      title: 'User Detail',
      eyebrow: 'Accounts',
      subtitle: 'View user information and manage role and account status.',
      child: div(classes: 'stack stack--md', [
        // The notice lives outside the FutureBuilder so it stays visible while
        // the record re-renders, and is never shown before server confirmation.
        if (_notice != null)
          div(
            classes: _noticeIsError
                ? 'notice notice-danger'
                : 'notice notice-info',
            attributes: {'role': _noticeIsError ? 'alert' : 'status'},
            [Component.text(_notice!)],
          ),
        FutureBuilder<_UserRecord?>(
          future: _future,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return _empty(
                'Unable to load user',
                'The account could not be read. Refresh the page and try again.',
              );
            }
            if (snapshot.connectionState != ConnectionState.done) {
              return const Skeleton(variant: 'row', count: 3);
            }
            final record = snapshot.data;
            if (record == null) {
              return _empty(
                'Record not found',
                'No user matches this ID. It may have been removed.',
              );
            }
            return _details(record);
          },
        ),
      ]),
    );
  }

  Component _details(_UserRecord record) {
    final user = record.user;
    final changed = _role != _savedRole || _status != _savedStatus;
    final canSave = _isAdmin && changed && !_saving;

    return div(classes: 'stack stack--md', [
      const Breadcrumbs(['Users', 'User detail']),

      // --- D. Page actions -------------------------------------------------
      div(
        classes: 'row row--md',
        styles: const Styles(raw: {
          'flex-wrap': 'wrap',
          'align-items': 'center',
          'justify-content': 'space-between',
        }),
        [
          const ActionLink(
            'Back to Users',
            href: '/admin/users',
            variant: 'secondary',
          ),
          button(
            attributes: {'type': 'button', if (!canSave) 'disabled': 'true'},
            classes: canSave
                ? 'btn btn--accent'
                : 'btn btn--accent is-disabled',
            onClick: canSave ? () => _save() : null,
            [Component.text(_saving ? 'Saving…' : 'Save Changes')],
          ),
        ],
      ),

      // --- A. User summary -------------------------------------------------
      div(classes: 'card stack stack--md', [
        div(classes: 'row row--md', [
          span(classes: 'avatar', [Component.text(_initials(user.name))]),
          div(classes: 'grow stack', [
            span(classes: 'title', [
              Component.text(_value(user.name, 'Unnamed user')),
            ]),
            span(classes: 'body', [
              Component.text(_value(user.email, 'Not provided')),
            ]),
          ]),
          Pill(_pretty(_savedStatus), tone: _statusTone(_savedStatus)),
        ]),
        div(classes: 'grid-2', [
          _row('Current role', _pretty(_savedRole)),
          _row('Account status', _pretty(_savedStatus)),
          _row('Registration date', _date(user.joinedAt)),
          _row('Last login', _dateTime(record.lastLogin)),
        ]),
      ]),

      // `.grid-2` collapses to one column at <= 640px in web/styles.css.
      div(classes: 'grid-2', [
        // --- B. User information -------------------------------------------
        div(classes: 'card stack', [
          span(classes: 'title', [Component.text('User Information')]),
          _row('User ID', _value(user.id, 'Not provided')),
          _row('Full name', _value(user.name, 'Not provided')),
          _row('Email', _value(user.email, 'Not provided')),
          _row('Phone number', record.phone ?? 'Not provided'),
          _row('Location', _value(user.location, 'Not provided')),
        ]),

        // --- C. Role & status ----------------------------------------------
        div(classes: 'card stack stack--md', [
          span(classes: 'title', [Component.text('Role & Status')]),
          _dropdown('Role', _role, _roles, _isAdmin ? _setRole : null),
          _dropdown(
            'Account Status',
            _status,
            _statuses,
            _isAdmin ? _setStatus : null,
          ),
          if (!_isAdmin)
            span(classes: 'small muted', [
              Component.text(
                'Only an authorized administrator can change role or account '
                'status. The backend independently verifies the session.',
              ),
            ])
          else if (!changed)
            span(classes: 'small muted', [
              Component.text(
                'Select a different role or status to enable Save Changes.',
              ),
            ]),
        ]),
      ]),
    ]);
  }

  Component _dropdown(
    String label,
    String value,
    List<(String, String)> values,
    void Function(String)? onChanged,
  ) {
    return Field(
      labelText: label,
      child: select(
        attributes: {
          'aria-label': label,
          if (onChanged == null) 'disabled': 'true',
        },
        events: events<List<String>>(onInput: (selected) {
          if (onChanged != null && selected.isNotEmpty) {
            onChanged(selected.first);
          }
        }),
        [
          // `entry`, not `option`: the local name must not shadow the DOM
          // `option()` builder imported from package:jaspr/dom.dart.
          for (final entry in values)
            option(
              value: entry.$1,
              attributes: entry.$1 == value ? const {'selected': ''} : null,
              [Component.text(entry.$2)],
            ),
        ],
      ),
    );
  }

  Component _row(String label, String value) => div(
    classes: 'row',
    styles: const Styles(raw: {
      'justify-content': 'space-between',
      'flex-wrap': 'wrap',
      'padding': '6px 0',
      'border-bottom': '1px solid var(--border)',
    }),
    [
      span(classes: 'small muted', [Component.text(label)]),
      span(classes: 'small', [Component.text(value)]),
    ],
  );

  Component _empty(String title, String body) => EmptyState(
    title: title,
    body: body,
    action: const ActionLink(
      'Back to Users',
      href: '/admin/users',
      variant: 'secondary',
    ),
  );
}

/// The domain record plus the two optional attributes that `SitewiseUser` does
/// not carry. Kept private to this page: no shared interface is changed.
class _UserRecord {
  final SitewiseUser user;
  final String? phone;
  final String? lastLogin;

  const _UserRecord({
    required this.user,
    this.phone,
    this.lastLogin,
  });
}

String _roleValue(AppRole role) => switch (role) {
  AppRole.admin => 'admin',
  AppRole.agent => 'agent',
  // `owner` is a legacy capability, not one of the three stored roles.
  _ => 'entrepreneur',
};

String _canonicalRole(String? raw) => switch ((raw ?? '').toLowerCase().trim()) {
  'admin' || 'administrator' => 'admin',
  'agent' => 'agent',
  'entrepreneur' || 'property_owner' || 'user' || 'owner' => 'entrepreneur',
  _ => (raw ?? '').toLowerCase().trim(),
};

String _statusValue(String raw) {
  final value = raw.toLowerCase().trim();
  return _statuses.any((entry) => entry.$1 == value) ? value : 'pending';
}

String _pretty(String value) => switch (value) {
  'entrepreneur' => 'Entrepreneur',
  'agent' => 'Agent',
  'admin' => 'Administrator',
  'pending' => 'Pending',
  'active' => 'Active',
  'suspended' => 'Suspended',
  _ => value,
};

String _statusTone(String status) => switch (status) {
  'active' => 'success',
  'pending' => 'warning',
  'suspended' => 'danger',
  _ => 'neutral',
};

String? _text(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

String _value(String? raw, String fallback) {
  final text = (raw ?? '').trim();
  return text.isEmpty ? fallback : text;
}

String _initials(String name) {
  final parts = name
      .trim()
      .split(RegExp(r'\s+'))
      .where((part) => part.isNotEmpty)
      .toList();
  if (parts.isEmpty) return '?';
  final first = parts.first[0];
  final last = parts.length > 1 ? parts.last[0] : '';
  return (first + last).toUpperCase();
}

String _date(DateTime value) {
  // ApiUserRepository uses the epoch when the server omits created_at.
  if (value.year <= 1970) return 'Not provided';
  return '${_two(value.day)}/${_two(value.month)}/${value.year}';
}

String _dateTime(String? iso) {
  if (iso == null) return 'Not provided';
  final parsed = DateTime.tryParse(iso);
  if (parsed == null) return 'Not provided';
  final local = parsed.toLocal();
  return '${_two(local.day)}/${_two(local.month)}/${local.year} '
      '${_two(local.hour)}:${_two(local.minute)}';
}

String _two(int value) => value.toString().padLeft(2, '0');
