import 'dart:async';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';

import 'package:sitewise_jaspr_web/shared/presentation/components/dashboard_kit.dart';
import 'package:sitewise_jaspr_web/shared/presentation/components/ui.dart';
import 'package:sitewise_jaspr_web/shared/presentation/layouts/app_layout.dart';
import 'package:universal_web/web.dart' as web;
import 'package:sitewise_jaspr_web/core/di/app_locator.dart';
import 'package:sitewise_jaspr_web/features/administration/data/admin_api.dart';

@client
class UsersPage extends StatefulComponent {
  const UsersPage({super.key});

  @override
  State<UsersPage> createState() => _UsersPageState();
}

class _UsersPageState extends State<UsersPage> {
  // SITEWISE_OWNER_INVITE_UI_V1
  bool _ownerInviteOpen = false;
  bool _ownerInviteBusy = false;
  String _ownerName = '';
  String _ownerEmail = '';
  String _ownerPhone = '';
  String? _ownerInviteError;
  String? _ownerInviteNotice;

  void _openOwnerInvite() {
    setState(() {
      _ownerName = '';
      _ownerEmail = '';
      _ownerPhone = '';
      _ownerInviteError = null;
      _ownerInviteNotice = null;
      _ownerInviteOpen = true;
    });
    Future<void>.delayed(const Duration(milliseconds: 30), () {
      if (!mounted || !_ownerInviteOpen) return;
      final target = web.document.querySelector('.owner-invite-dialog input');
      (target as web.HTMLElement?)?.focus();
    });
  }

  void _closeOwnerInvite() {
    if (_ownerInviteBusy) return;
    setState(() {
      _ownerInviteOpen = false;
      _ownerInviteError = null;
    });
    _restoreOwnerInviteFocus();
  }

  void _restoreOwnerInviteFocus() {
    Future<void>.delayed(const Duration(milliseconds: 30), () {
      if (!mounted || _ownerInviteOpen) return;
      final target = web.document.querySelector('.page-head__actions button');
      (target as web.HTMLElement?)?.focus();
    });
  }

  Future<void> _sendOwnerInvite() async {
    if (_ownerInviteBusy || !_ownerInviteOpen) return;
    final name = _ownerName.trim();
    final email = _ownerEmail.trim().toLowerCase();
    final phone = _ownerPhone.trim();
    String? validation;
    if (name.length < 2 || name.length > 120) {
      validation = 'Enter a full name between 2 and 120 characters.';
    } else if (email.length > 254 ||
        !RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(email)) {
      validation = 'Enter a valid email address.';
    } else if (phone.isNotEmpty &&
        (phone.length > 20 ||
            !RegExp(r'^\+?[0-9 ()-]+$').hasMatch(phone) ||
            phone.replaceAll(RegExp(r'[^0-9]'), '').length < 7 ||
            phone.replaceAll(RegExp(r'[^0-9]'), '').length > 15)) {
      validation = 'Enter a valid phone number, or leave it blank.';
    }
    if (validation != null) {
      setState(() => _ownerInviteError = validation);
      return;
    }
    setState(() {
      _ownerInviteBusy = true;
      _ownerInviteError = null;
    });
    try {
      final result = await AppLocator.adminApi.invitePropertyOwner(
        fullName: name,
        email: email,
        phoneNumber: phone.isEmpty ? null : phone,
      );
      if (!mounted) return;
      final invitation = result['invitation'];
      final mirror = result['mirror'];
      final ownerUserId = '${result['owner_user_id'] ?? ''}';
      final invitationStatus = '${result['invitation_status'] ?? ''}'
          .trim()
          .toLowerCase();
      final nestedStatus = invitation is Map
          ? '${invitation['invitation_status'] ?? ''}'.trim().toLowerCase()
          : '';
      final confirmed =
          result['invited'] is bool &&
          result['email_sent'] is bool &&
          ownerUserId.isNotEmpty &&
          '${result['email'] ?? ''}'.trim().toLowerCase() == email &&
          result['role'] == 'owner' &&
          result['account_status'] == 'pending' &&
          (invitationStatus == 'sent' || invitationStatus == 'accepted') &&
          invitationStatus == nestedStatus &&
          invitation is Map &&
          '${invitation['invitation_id'] ?? ''}'.isNotEmpty &&
          '${invitation['invited_email'] ?? ''}'.trim().toLowerCase() ==
              email &&
          '${invitation['invited_role'] ?? ''}'.trim().toLowerCase() ==
              'owner' &&
          '${invitation['invited_user_id'] ?? ''}' == ownerUserId &&
          mirror is Map &&
          '${mirror['user_id'] ?? ''}' == ownerUserId &&
          '${mirror['email'] ?? ''}'.trim().toLowerCase() == email &&
          mirror['role'] == 'owner' &&
          mirror['account_status'] == 'pending';
      // A retry may reconcile an already-sent or already-accepted invitation.
      // Success still requires the exact Owner identity and pending mirror.
      if (!confirmed) {
        setState(() {
          _ownerInviteError =
              'The server did not confirm a pending Owner '
              'account with a matching invitation. Check the user directory '
              'before retrying.';
          _ownerInviteBusy = false;
        });
        return;
      }
      final emailSent = result['email_sent'] == true;
      final notice = emailSent
          ? 'Invitation email sent for $email. The Owner account is pending '
                'until email confirmation, MFA and onboarding are complete.'
          : invitationStatus == 'accepted'
          ? 'The accepted Owner invitation for $email was reconciled. No '
                'email was needed because the address is already confirmed; '
                'the account remains pending until onboarding completes.'
          : 'The existing Owner invitation for $email was reconciled. No '
                'second email was sent; the account remains pending until '
                'onboarding completes.';
      setState(() {
        _ownerInviteBusy = false;
        _ownerInviteOpen = false;
        _ownerInviteNotice = notice;
        _ownerName = '';
        _ownerEmail = '';
        _ownerPhone = '';
      });
      _restoreOwnerInviteFocus();
      // Keep the existing notifier and directory as the only user-list source.
      unawaited(context.read(adminNotifierProvider.notifier).loadUsers());
    } catch (error) {
      if (!mounted) return;
      final message = AdminApi.message(error);
      setState(() {
        _ownerInviteBusy = false;
        _ownerInviteError = 'Invitation could not be confirmed: $message';
      });
    }
  }

  Component _ownerInviteField({
    required String labelText,
    required String value,
    required String placeholder,
    required String autocomplete,
    required void Function(String) onInput,
    InputType type = InputType.text,
  }) => Field(
    labelText: labelText,
    child: input(
      type: type,
      attributes: {
        'value': value,
        'placeholder': placeholder,
        'autocomplete': autocomplete,
        'aria-label': labelText,
        if (_ownerInviteBusy) 'disabled': '',
      },
      events: events<String>(onInput: onInput),
    ),
  );

  Component _ownerInviteDialog() => SitewiseDialog(
    panelClass: 'dialog--owner-invite owner-invite-dialog',
    title: 'Invite Property Owner',
    ariaLabel: 'Invite Property Owner',
    onClose: _closeOwnerInvite,
    body: div(classes: 'stack', [
      p(classes: 'body', [
        Component.text(
          'Create an owner account and send a secure '
          'password-setup invitation.',
        ),
      ]),
      _ownerInviteField(
        labelText: 'Full name *',
        value: _ownerName,
        placeholder: 'Enter full name',
        autocomplete: 'name',
        onInput: (value) => setState(() => _ownerName = value),
      ),
      _ownerInviteField(
        labelText: 'Email address *',
        value: _ownerEmail,
        placeholder: 'name@example.com',
        autocomplete: 'email',
        type: InputType.email,
        onInput: (value) => setState(() => _ownerEmail = value),
      ),
      _ownerInviteField(
        labelText: 'Phone number (optional)',
        value: _ownerPhone,
        placeholder: '+60',
        autocomplete: 'tel',
        onInput: (value) => setState(() => _ownerPhone = value),
      ),
      Field(
        labelText: 'Account role',
        child: div(classes: 'panel', [Component.text('Property Owner')]),
      ),
      Callout(
        'The account remains pending until the recipient accepts the '
        'invitation and completes account setup.',
        tone: 'info',
        icon: 'info',
      ),
      if (_ownerInviteError != null)
        div(
          attributes: const {'role': 'alert'},
          [ActionNotice(_ownerInviteError!, tone: 'danger')],
        ),
      if (_ownerInviteBusy)
        div(
          attributes: const {'role': 'status'},
          [Component.text('Sending invitation…')],
        ),
    ]),
    actions: [
      ActionButton(
        'Cancel',
        variant: 'secondary',
        onClick: _ownerInviteBusy ? null : _closeOwnerInvite,
      ),
      ActionButton(
        _ownerInviteBusy ? 'Sending…' : 'Send Invitation',
        icon: 'send',
        onClick: _ownerInviteBusy ? null : () => unawaited(_sendOwnerInvite()),
      ),
    ],
  );

  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      if (!mounted) return;
      unawaited(context.read(adminNotifierProvider.notifier).loadUsers());
    });
  }

  @override
  Component build(BuildContext context) {
    return AppLayout(
      role: AppRole.admin,
      currentRoute: '/admin/users',
      title: 'User management',
      actions: [
        const ActionLink(
          'Invite agent',
          href: '/admin/agents?invite=1',
          icon: 'person_add',
        ),
        ActionButton(
          'Invite property owner',
          icon: 'person_add',
          variant: 'secondary',
          onClick: _openOwnerInvite,
        ),
      ],
      // The shells below re-render only on loading/error; the directory owns
      // its own subscription to the users slice, so the `AppLayout` chrome
      // (topbar, page head, footer) never rebuilds on a notification.
      child: div(classes: 'stack stack--sections', [
        if (_ownerInviteNotice != null)
          div(
            attributes: const {'role': 'status'},
            [ActionNotice(_ownerInviteNotice!)],
          ),
        const _Shells(),
        if (_ownerInviteOpen) _ownerInviteDialog(),
      ]),
    );
  }
}

class _Shells extends StatelessComponent {
  const _Shells();

  @override
  Component build(BuildContext context) {
    final slice = context.watch(
      adminNotifierProvider.select(
        (state) => (
          loading: state.loading,
          error: state.error,
          hasUsers: state.users.isNotEmpty,
        ),
      ),
    );
    if (slice.loading && !slice.hasUsers) {
      return SectionCard(
        title: 'Loading accounts…',
        flush: true,
        child: const Skeleton(variant: 'row', count: 6),
      );
    }
    if (slice.error != null && !slice.hasUsers) return _Error(slice.error!);
    // A refresh that failed must not discard records the server already
    // confirmed: keep them on screen and say the refresh did not complete.
    if (slice.error != null) {
      return div(classes: 'stack stack--sections', [
        Callout(
          'The account list could not be refreshed, so the records below are '
          'the last ones loaded. ${slice.error!}',
          tone: 'warning',
          icon: 'error',
        ),
        const _Directory(),
      ]);
    }
    return const _Directory();
  }
}

class _Error extends StatelessComponent {
  const _Error(this.message);

  final String message;

  @override
  Component build(BuildContext context) => EmptyState(
    title: 'Could not load accounts',
    body: message,
    action: ActionButton(
      'Try again',
      variant: 'primary',
      onClick: () =>
          unawaited(context.read(adminNotifierProvider.notifier).loadUsers()),
    ),
  );
}

/// Filter bar + directory table. Owns the local filter state, so a keystroke
/// or filter change rebuilds only this subtree — never the `AppLayout`
/// chrome — and watches only the users/listings slice, so unrelated
/// notifications do not re-render it either.
class _Directory extends StatefulComponent {
  const _Directory();

  @override
  State<_Directory> createState() => _DirectoryState();
}

class _DirectoryState extends State<_Directory> {
  static const _pageSize = 20;
  int _page = 0;
  bool _newestFirst = true;
  String query = '';
  String statusFilter = 'all';

  /// The selected `<option>` value, not its display label — comparing a label
  /// against option values silently reset the selection on every rebuild.
  String roleFilter = 'all';

  /// Exactly `rbac.ALL_ROLES`. `owner` is a stored role now, so it is both
  /// assignable and filterable — leaving it out would hide every Property Owner
  /// from the administrator's user list.
  static const List<(String, String)> _roleOptions = [
    ('All roles', 'all'),
    ('Administrator', 'admin'),
    ('Property Owner', 'owner'),
    ('Agent', 'agent'),
    ('Entrepreneur', 'entrepreneur'),
  ];

  /// Exactly `rbac.ACCOUNT_STATUSES`.
  static const List<(String, String)> _statusOptions = [
    ('All statuses', 'all'),
    ('Pending', 'pending'),
    ('Active', 'active'),
    ('Blocked', 'suspended'),
  ];

  List<SitewiseUser> _filtered(List<SitewiseUser> users) {
    final q = query.trim().toLowerCase();
    return users.where((user) {
      final matchesQ =
          q.isEmpty || '${user.name} ${user.email}'.toLowerCase().contains(q);
      final matchesStatus =
          statusFilter == 'all' ||
          user.status.toLowerCase() == statusFilter.toLowerCase();
      final matchesRole =
          roleFilter == 'all' || _roleValue(user.role) == roleFilter;
      return matchesQ && matchesStatus && matchesRole;
    }).toList()..sort((first, second) {
      final date = _newestFirst
          ? second.joinedAt.compareTo(first.joinedAt)
          : first.joinedAt.compareTo(second.joinedAt);
      return date != 0 ? date : first.id.compareTo(second.id);
    });
  }

  String _joined(SitewiseUser user) {
    if (user.joinedAt.year <= 1970) return 'Not provided';
    final m = user.joinedAt.month.toString().padLeft(2, '0');
    final d = user.joinedAt.day.toString().padLeft(2, '0');
    return '${user.joinedAt.year}-$m-$d';
  }

  Component _selectField({
    required String labelText,
    required String value,
    required List<(String, String)> options,
    required void Function(String) onChanged,
  }) => Field(
    labelText: labelText,
    // A select's onInput delivers the selected values as a LIST (the same
    // shape the User Detail page's status dropdown consumes). The earlier
    // `events<String>` signature never matched that delivery, so the Status
    // and Role filters silently never fired.
    child: select(
      attributes: {'aria-label': labelText},
      events: events<List<String>>(
        onInput: (selected) {
          if (selected.isNotEmpty) onChanged(selected.first);
        },
      ),
      [
        for (final opt in options)
          option(
            value: opt.$2,
            attributes: {if (opt.$2 == value) 'selected': ''},
            [Component.text(opt.$1)],
          ),
      ],
    ),
  );

  @override
  Component build(BuildContext context) {
    // One watch for the whole directory: the filters bar is cheap to re-render
    // and the layout chrome above it stays out of every rebuild.
    final all = context.watch(
      adminNotifierProvider.select((state) => state.users),
    );
    final users = _filtered(all);
    final pageCount = (users.length / _pageSize).ceil();
    final page = pageCount == 0 ? 0 : _page.clamp(0, pageCount - 1);
    final start = page * _pageSize;
    final visible = users.skip(start).take(_pageSize);
    return div(classes: 'auu-directory stack', [
      div(classes: 'auu-stats', [
        _stat('Registered', all.length),
        for (final (label, status) in _statusOptions.skip(1))
          _stat(
            label,
            all.where((user) => user.status.toLowerCase() == status).length,
          ),
      ]),
      div(classes: 'filters auu-toolbar', [
        SearchInput(
          label: 'Search',
          placeholder: 'Name or email',
          ariaLabel: 'Search users by name or email',
          onInput: (value) => setState(() {
            query = value;
            _page = 0;
          }),
        ),
        _selectField(
          labelText: 'Status',
          value: statusFilter,
          options: _statusOptions,
          onChanged: (v) => setState(() {
            statusFilter = v;
            _page = 0;
          }),
        ),
        _selectField(
          labelText: 'Role',
          value: roleFilter,
          options: _roleOptions,
          onChanged: (v) => setState(() {
            roleFilter = v;
            _page = 0;
          }),
        ),
        _selectField(
          labelText: 'Registration order',
          value: _newestFirst ? 'newest' : 'oldest',
          options: const [
            ('Newest first', 'newest'),
            ('Oldest first', 'oldest'),
          ],
          onChanged: (value) => setState(() {
            _newestFirst = value == 'newest';
            _page = 0;
          }),
        ),
      ]),

      if (users.isEmpty)
        EmptyState(
          title: 'No accounts match',
          body: 'Try a different search or filter.',
        )
      else
        SectionCard(
          title:
              '${users.length} '
              '${users.length == 1 ? 'account' : 'accounts'}',
          flush: true,
          child: TableScroll(
            label: 'User directory',
            children: [
              table(classes: 'audit-table auu-table', [
                thead([
                  tr([
                    th([Component.text('User')]),
                    th([Component.text('Account role')]),
                    th([Component.text('Account status')]),
                    th(classes: 'auu-registration', [
                      Component.text('Registered'),
                    ]),
                    th([Component.text('Action')]),
                  ]),
                ]),
                tbody([
                  for (final user in visible)
                    tr([
                      td([
                        div(classes: 'auu-person', [
                          span(
                            classes: 'auu-avatar',
                            attributes: const {'aria-hidden': 'true'},
                            [
                              Component.text(
                                user.name.trim().isEmpty
                                    ? 'U'
                                    : user.name
                                          .trim()
                                          .substring(0, 1)
                                          .toUpperCase(),
                              ),
                            ],
                          ),
                          div(classes: 'auu-person__info', [
                            AppLink(
                              to: '/admin/user-detail?id=${Uri.encodeComponent(user.id)}',
                              classes: 'auu-person__name',
                              children: [
                                Component.text(
                                  user.name.trim().isEmpty
                                      ? 'Unnamed account'
                                      : user.name,
                                ),
                              ],
                            ),
                            span(classes: 'auu-person__email', [
                              Component.text(user.email),
                            ]),
                          ]),
                        ]),
                      ]),
                      td([
                        span(classes: 'auu-role auu-role--${user.role.name}', [
                          Component.text(_roleLabel(user.role)),
                        ]),
                      ]),
                      td([StatusBadge.forText(user.status)]),
                      td(classes: 'auu-registration', [
                        span(classes: 'auu-date', [
                          Component.text(_joined(user)),
                        ]),
                      ]),
                      td([
                        div(classes: 'auu-actions', [
                          AppLink(
                            to: '/admin/user-detail?id=${Uri.encodeComponent(user.id)}',
                            classes: 'auu-manage',
                            children: [Component.text('View details')],
                          ),
                        ]),
                      ]),
                    ]),
                ]),
              ]),
            ],
          ),
        ),
      p(classes: 'stat-note', [
        Component.text(
          'Listings counts operational properties owned by the account, '
          'counted by the backend. A dash means the count was not supplied. '
          'Passwords and other private credentials are never exposed.',
        ),
      ]),
      if (pageCount > 1)
        div(classes: 'row auu-pager', [
          span(classes: 'small muted grow', [
            Component.text(
              'Showing ${start + 1}–${start + visible.length} of ${users.length}',
            ),
          ]),
          ActionButton(
            'Previous',
            variant: 'secondary',
            onClick: page > 0 ? () => setState(() => _page = page - 1) : null,
          ),
          ActionButton(
            'Next',
            variant: 'secondary',
            onClick: page + 1 < pageCount
                ? () => setState(() => _page = page + 1)
                : null,
          ),
        ]),
    ]);
  }

  Component _stat(String label, int count) => div(classes: 'auu-stat', [
    span(classes: 'small muted', [Component.text(label)]),
    strong([Component.text('$count')]),
  ]);
}

/// The stored role id, matching `rbac.ALL_ROLES` and the filter option values.
/// `owner` IS a stored role now, so it maps to itself: filtering by
/// "Property Owner" must match Property Owner rows, never Entrepreneurs.
String _roleValue(AppRole role) => switch (role) {
  AppRole.admin => 'admin',
  AppRole.owner => 'owner',
  AppRole.agent => 'agent',
  AppRole.entrepreneur => 'entrepreneur',
};

String _roleLabel(AppRole role) => switch (role) {
  AppRole.admin => 'Administrator',
  AppRole.agent => 'Agent',
  AppRole.owner => 'Property Owner',
  AppRole.entrepreneur => 'Entrepreneur',
};
