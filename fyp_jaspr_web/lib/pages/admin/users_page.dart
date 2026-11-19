import 'dart:async';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/dashboard_kit.dart';
import '../../components/ui.dart';
import '../../layouts/app_layout.dart';

/// Web user management, ported to the source `admin/users.html` structure: a
/// `.filters` bar (Search + Status + Role, in a `.grid-3`) above an
/// `.audit-table` whose Account cell uses `.who`/`.sub` and whose Status cell
/// uses `.st`.
///
/// Records are live: the user repository reads the authenticated FastAPI
/// `/users` API (administrator + aal2 enforced server-side), not demo data.
/// The screen is deliberately read-only: roles are assigned by the
/// authorised registration / invitation / onboarding workflows and are shown
/// for information only — never editable from user management. Account
/// status is managed on the User Detail page, so no change is ever
/// simulated here. A failed load surfaces an error state rather than an
/// empty directory. The Listings column is the backend's per-owner count of
/// operational listings; Joined is the user's `joinedAt`.
@client
class UsersPage extends StatefulComponent {
  const UsersPage({super.key});

  @override
  State<UsersPage> createState() => _UsersPageState();
}

class _UsersPageState extends State<UsersPage> {
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
      // The page header is rendered by `AppLayout`; a page must not render
      // its own `PageHead` or the title appears twice.
      title: 'Users',
      eyebrow: 'Accounts',
      subtitle:
          'Live account records from the authenticated backend '
          '(administrator sign-in with MFA required). Read-only: role and '
          'status are shown here but not changed on this screen.',
      // The shells below re-render only on loading/error; the directory owns
      // its own subscription to the users slice, so the `AppLayout` chrome
      // (topbar, page head, footer) never rebuilds on a notification.
      child: const _Shells(),
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
      onClick: () => unawaited(
        context.read(adminNotifierProvider.notifier).loadUsers(),
      ),
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
    ('Suspended', 'suspended'),
  ];

  List<SitewiseUser> _filtered(List<SitewiseUser> users) {
    final q = query.trim().toLowerCase();
    return users.where((user) {
      final matchesQ =
          q.isEmpty || '${user.name} ${user.email}'.toLowerCase().contains(q);
      final matchesStatus =
          statusFilter == 'all' ||
          user.status.toLowerCase() == statusFilter.toLowerCase();
      final matchesRole = roleFilter == 'all' || _roleValue(user.role) == roleFilter;
      return matchesQ && matchesStatus && matchesRole;
    }).toList();
  }

  String _joined(SitewiseUser user) {
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
    final users = _filtered(
      context.watch(adminNotifierProvider.select((state) => state.users)),
    );
    return div(classes: 'stack stack--sections', [
      div(classes: 'filters', [
        div(classes: 'grid-3', [
          SearchInput(
            label: 'Search',
            placeholder: 'Name or email',
            ariaLabel: 'Search users by name or email',
            onInput: (value) => setState(() => query = value),
          ),
          _selectField(
            labelText: 'Status',
            value: statusFilter,
            options: _statusOptions,
            onChanged: (v) => setState(() => statusFilter = v),
          ),
          _selectField(
            labelText: 'Role',
            value: roleFilter,
            options: _roleOptions,
            onChanged: (v) => setState(() => roleFilter = v),
          ),
        ]),
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
          child: div(classes: 'table-scroll', [
            table(classes: 'audit-table auu-table', [
              thead([
                tr([
                  th([Component.text('User')]),
                  th([Component.text('Role')]),
                  th([Component.text('Account status')]),
                  th([Component.text('Listings')]),
                  th([Component.text('Joined')]),
                  th([Component.text('Action')]),
                ]),
              ]),
              tbody([
                for (final user in users)
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
                                  : user.name.trim().substring(0, 1).toUpperCase(),
                            ),
                          ],
                        ),
                        div(classes: 'auu-person__info', [
                          AppLink(
                            to: '/admin/user-detail?id=${Uri.encodeComponent(user.id)}',
                            classes: 'auu-person__name',
                            children: [
                              Component.text(
                                user.name.trim().isEmpty ? 'Unnamed account' : user.name,
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
                    td([
                      StatusBadge.forText(user.status),
                    ]),
                    td([
                      span(classes: 'auu-count', [
                        Component.text(
                          user.listingCount == null ? '—' : '${user.listingCount}',
                        ),
                      ]),
                    ]),
                    td([
                      span(classes: 'auu-date', [Component.text(_joined(user))]),
                    ]),
                    td([
                      div(classes: 'auu-actions', [
                        AppLink(
                          to: '/admin/user-detail?id=${Uri.encodeComponent(user.id)}',
                          classes: 'auu-manage',
                          children: [
                            Component.text('Manage'),
                            Icon('arrow_forward', size: 'sm'),
                          ],
                        ),
                        if (user.role == AppRole.admin)
                          span(classes: 'auu-protected', [
                            Icon('lock', size: 'sm'),
                            Component.text('Protected'),
                          ]),
                      ]),
                    ]),
                  ]),
              ]),
            ]),
          ]),
        ),
      p(classes: 'stat-note', [
        Component.text(
          'Listings counts operational properties owned by the account, '
          'counted by the backend. A dash means the count was not supplied. '
          'Passwords and other private credentials are never exposed.',
        ),
      ]),
    ]);
  }
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
