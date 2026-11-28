import 'package:sitewise_jaspr_web/shared/presentation/components/dashboard_kit.dart';
import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import 'package:sitewise_jaspr_web/shared/presentation/components/ui.dart';
import 'package:sitewise_jaspr_web/features/authentication/data/auth_service.dart';
import 'package:sitewise_jaspr_web/features/administration/data/user_detail_api.dart';
import 'package:sitewise_jaspr_web/shared/presentation/layouts/app_layout.dart';

@client
class UserDetailPage extends StatefulComponent {
  final String id;

  const UserDetailPage({super.key, required this.id});

  @override
  State<UserDetailPage> createState() => _UserDetailPageState();
}

/// Backend values are lowercase; the second element of each pair is the label.
/// This is exactly `rbac.ACCOUNT_STATUSES`.
const List<(String, String)> _statuses = [
  ('pending', 'Pending'),
  ('active', 'Active'),
  ('suspended', 'Blocked'),
];

class _UserDetailPageState extends State<UserDetailPage> {
  late Future<_UserRecord?> _future;

  /// Last server-confirmed status. The selected value is compared against
  /// this, never against a locally optimistic copy.
  String _savedStatus = 'pending';
  String? _confirmStatus;

  bool _saving = false;
  String? _notice;
  bool _noticeIsError = false;

  /// A change that applied but was not audited is neither a clean success nor
  /// a failure; it gets the warning tone.
  bool _noticeIsWarning = false;

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

    // One authoritative read of `/users/{id}`. The detailed variant keeps the
    // status code, so "not found", "not authorised" and "service unavailable"
    // are reported as what they are instead of all reading as a missing record.
    final result = await UserDetailApi.read(id);
    if (result['ok'] != true) {
      if (result['status'] == 404) return null;
      throw StateError(_failureMessage(result));
    }
    final row = result['body'];
    if (row is! Map<String, dynamic>) {
      throw StateError(
        'The account record returned by the service could not be read.',
      );
    }

    // Same mapper the directory uses, so the two screens cannot disagree about
    // a role or status. `phone_number` / `last_login` are read from this same
    // payload rather than a second request.
    final user = ApiUserRepository.fromJson(row);
    _savedStatus = _statusValue(user.status);

    return _UserRecord(
      user: user,
      phone: _text(row['phone_number']),
      lastLogin: _text(row['last_login']),
    );
  }

  void _retry() => setState(() => _future = _load());

  Future<void> _save() async {
    final target = _confirmStatus;
    if (_saving ||
        !_isAdmin ||
        target == null ||
        WebAuth.profile?['user_id']?.toString() == component.id) {
      return;
    }
    // Roles are never sent: they are provisioning-only, and `UserDetailApi`
    // exposes no signature for them. Only a changed status is written, so an
    // untouched record never triggers an update (and never creates an audit
    // event).
    if (target == _savedStatus) return;

    setState(() {
      _saving = true;
      _confirmStatus = null;
      _notice = null;
      _noticeIsError = false;
      _noticeIsWarning = false;
    });

    try {
      final result = await UserDetailApi.updateStatus(component.id, target);
      if (!mounted) return;

      if (result['ok'] != true) {
        // The backend distinguishes "nothing applied" (identity rejected),
        // "partially applied" (identity updated, local mirror not) and a
        // permission/MFA denial. Its own wording is the accurate one, so it is
        // shown verbatim instead of a generic failure line.
        setState(() {
          _saving = false;
          _noticeIsError = true;
          _notice = _failureMessage(result);
        });
        return;
      }

      final response = result['body'];
      if (response is! Map<String, dynamic>) {
        setState(() {
          _saving = false;
          _noticeIsError = true;
          _notice =
              'The server returned a response this page cannot read, so '
              'nothing was marked as saved. Reload the account to check its '
              'current status.';
        });
        return;
      }

      // Success is shown only when the server echoes back the value we asked
      // for. A partial or unexpected response is treated as unconfirmed.
      final echoedStatus = (response['account_status'] as String?)
          ?.toLowerCase()
          .trim();
      final confirmed = echoedStatus == target;

      if (!confirmed) {
        setState(() {
          _saving = false;
          _noticeIsError = true;
          _notice =
              'The server did not confirm this change. Nothing was '
              'marked as saved.';
        });
        return;
      }

      setState(() {
        _savedStatus = target;
        _saving = false;
        _noticeIsError = false;
        _noticeIsWarning = response['audit_recorded'] == false;
        _notice = _noticeIsWarning
            ? 'Account status changed, but the change could not be recorded in account history.'
            : 'Account status updated.';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _noticeIsError = true;
        _notice = 'Could not save changes: $error';
      });
    }
  }

  @override
  Component build(BuildContext context) {
    return AppLayout(
      role: AppRole.admin,
      currentRoute: '/admin/user-detail',
      title: 'User details',
      actions: const [
        ActionLink('Back to users', href: '/admin/users', variant: 'secondary'),
      ],
      child: div(classes: 'admin-user-detail stack stack--sections', [
        // The notice lives outside the FutureBuilder so it stays visible while
        // the record re-renders, and is never shown before server confirmation.
        if (_notice != null)
          div(
            classes: _noticeIsError
                ? 'notice notice-danger'
                : _noticeIsWarning
                ? 'notice notice-warn'
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
                '${snapshot.error}',
                action: ActionButton(
                  'Try again',
                  variant: 'primary',
                  onClick: _retry,
                ),
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
    final isSelf = WebAuth.profile?['user_id']?.toString() == user.id;
    final knownStatus = _savedStatus.isNotEmpty;

    return div(classes: 'stack stack--sections', [
      div(classes: 'card stack stack--md', [
        div(classes: 'row admin-user-detail__identity', [
          span(classes: 'avatar', [Component.text(_initials(user.name))]),
          div(classes: 'grow stack', [
            span(classes: 'title', [
              Component.text(_value(user.name, 'Unnamed account')),
            ]),
            span(classes: 'body', [
              Component.text(_value(user.email, 'Email not provided')),
            ]),
          ]),
          Pill(_pretty(_savedStatus), tone: _statusTone(_savedStatus)),
        ]),
        div(classes: 'grid-2', [
          _row('Account role', _pretty(_roleValue(user.role))),
          _row('Registration date', _date(user.joinedAt)),
          if (record.phone != null) _row('Phone number', record.phone!),
          _row('Last sign-in', _dateTime(record.lastLogin)),
        ]),
      ]),
      div(classes: 'card stack stack--md', [
        h2(classes: 'title', [const Component.text('Account access')]),
        if (isSelf)
          p(classes: 'body', [
            const Component.text(
              'You cannot disable your own administrator account.',
            ),
          ])
        else if (_isAdmin && knownStatus)
          div(classes: 'row', [
            if (user.role == AppRole.owner && _savedStatus == 'pending')
              p(classes: 'body', [
                const Component.text(
                  'The owner needs to complete account setup to activate their account.',
                ),
              ]),
            for (final (status, _) in _statuses)
              if (status != _savedStatus &&
                  !(user.role == AppRole.owner &&
                      _savedStatus == 'pending' &&
                      status == 'active'))
                ActionButton(
                  _actionLabel(status),
                  variant: status == 'suspended'
                      ? 'danger-outline'
                      : 'secondary',
                  onClick: _saving
                      ? null
                      : () => setState(() => _confirmStatus = status),
                ),
            if (_saving)
              span(
                attributes: {'role': 'status'},
                [const Component.text('Updating account…')],
              ),
          ]),
      ]),
      if (_confirmStatus case final String target) _confirmation(user, target),
    ]);
  }

  String _actionLabel(String status) => switch (status) {
    'suspended' => 'Block account',
    'active' when _savedStatus == 'suspended' => 'Unblock account',
    'active' => 'Activate account',
    _ => 'Set account to pending',
  };

  Component _confirmation(SitewiseUser user, String target) {
    final action = _actionLabel(target);
    final account = _value(user.email, _value(user.name, 'This account'));
    final effect = switch (target) {
      'suspended' =>
        'Blocking prevents $account from accessing SiteWise until the account is unblocked. Existing account records and its role will be kept.',
      'active' =>
        '$account will have active access with the same role and sign-in requirements.',
      _ =>
        '$account will be marked pending and access may be limited until activation.',
    };
    void cancel() => setState(() => _confirmStatus = null);
    return SitewiseDialog(
      title: '$action?',
      ariaLabel: action,
      onClose: cancel,
      body: p(classes: 'body', [Component.text(effect)]),
      actions: [
        ActionButton('Cancel', variant: 'secondary', onClick: cancel),
        ActionButton(
          action,
          variant: target == 'suspended' ? 'danger-outline' : 'primary',
          onClick: _save,
        ),
      ],
    );
  }

  Component _row(String label, String value) =>
      div(classes: 'admin-user-detail__field', [
        span(classes: 'small muted', [Component.text(label)]),
        span(classes: 'small', [Component.text(value)]),
      ]);

  Component _empty(String title, String body, {Component? action}) =>
      EmptyState(
        title: title,
        body: body,
        action:
            action ??
            const ActionLink(
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

  const _UserRecord({required this.user, this.phone, this.lastLogin});
}

/// The stored role id, matching `rbac.ALL_ROLES` — display and echo only.
/// `owner` IS a stored role now, so it maps to itself: a Property Owner must
/// never be labelled or echoed as an Entrepreneur.
String _roleValue(AppRole role) => switch (role) {
  AppRole.admin => 'admin',
  AppRole.owner => 'owner',
  AppRole.agent => 'agent',
  AppRole.entrepreneur => 'entrepreneur',
};

String _failureMessage(Map<String, dynamic> result) {
  final message = (result['message'] as String?)?.trim();
  if (result['code'] == 'staff_mfa_required') {
    return 'This change needs an administrator session with completed MFA. '
        'Verify your second factor, then try again.';
  }
  if (result['code'] == 'role_change_not_supported') {
    return 'Roles cannot be changed through user management. A role is '
        'assigned by the authorised registration, invitation and onboarding '
        'workflows only.';
  }
  if (message != null && message.isNotEmpty) return message;
  return switch (result['status']) {
    403 => 'You are not authorised to change this account.',
    404 => 'This account no longer exists.',
    422 => 'The selected account status was rejected as invalid.',
    _ => 'Could not save changes. Nothing was marked as saved.',
  };
}

String _statusValue(String raw) {
  final value = raw.toLowerCase().trim();
  return _statuses.any((entry) => entry.$1 == value) ? value : '';
}

String _pretty(String value) => switch (value) {
  'admin' => 'Administrator',
  'owner' => 'Property Owner',
  'agent' => 'Agent',
  'entrepreneur' => 'Entrepreneur',
  'pending' => 'Pending',
  'active' => 'Active',
  'suspended' => 'Blocked',
  '' => 'Status unavailable',
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
