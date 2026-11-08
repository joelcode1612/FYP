import 'dart:async';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_provider_compat/jaspr_provider_compat.dart' as provider;
import 'package:shared_logic/shared_logic.dart';

import '../../components/ui.dart';
import '../../data/app_locator.dart';
import '../../layouts/app_layout.dart';
import '../../state/admin_view_model.dart';

/// Web user management, ported to the source `admin/users.html` structure: a
/// `.filters` bar (Search + Status + Role, in a `.grid-3`) above an
/// `.audit-table` whose Account cell uses `.who`/`.sub` and whose Status cell
/// uses `.st`.
///
/// Records are live: the user repository reads the authenticated FastAPI
/// `/users` API (administrator + aal2 enforced server-side), not demo data.
/// The screen is deliberately read-only status visibility — the backend
/// supports role/status mutations, but this build does not expose them, so no
/// change is ever simulated as persisted. A failed load surfaces an error
/// state rather than an empty directory. The Listings column is derived from
/// `vm.listings`, and Joined is the user's `joinedAt`.
@client
class UsersPage extends StatefulComponent {
  const UsersPage({super.key});

  @override
  State<UsersPage> createState() => _UsersPageState();
}

class _UsersPageState extends State<UsersPage> {
  late final AdminViewModel vm;

  @override
  void initState() {
    super.initState();
    vm = AppLocator.newAdminViewModel();
    unawaited(vm.loadUsers());
  }

  @override
  void dispose() {
    vm.dispose();
    super.dispose();
  }

  Component _error(String message) => EmptyState(
    title: 'Could not load accounts',
    body: message,
    action: ActionButton(
      'Try again',
      variant: 'primary',
      onClick: () => unawaited(vm.loadUsers()),
    ),
  );

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
      // The outer selector re-renders only the loading/error shells; the
      // directory below owns its own subscription to the users slice, so the
      // `AppLayout` chrome (topbar, page head, footer) never rebuilds on a
      // notification.
      child: provider.ChangeNotifierProvider<AdminViewModel>.value(
        value: vm,
        child:
            provider.Selector<AdminViewModel, ({bool loading, String? error})>(
              selector: (context, vm) => (loading: vm.loading, error: vm.error),
              builder: (context, slice, child) {
                if (slice.loading) {
                  return SectionCard(
                    title: 'Loading accounts…',
                    flush: true,
                    child: const Skeleton(variant: 'row', count: 6),
                  );
                }
                if (slice.error != null) return _error(slice.error!);
                return _Directory(vm: vm);
              },
            ),
      ),
    );
  }
}

/// Filter bar + directory table. Owns the local filter state, so a keystroke
/// or filter change rebuilds only this subtree — never the `AppLayout`
/// chrome — and the table region selects the users/listings slice, so
/// unrelated notifications do not re-render it either.
class _Directory extends StatefulComponent {
  final AdminViewModel vm;

  const _Directory({required this.vm});

  @override
  State<_Directory> createState() => _DirectoryState();
}

class _DirectoryState extends State<_Directory> {
  String query = '';
  String statusFilter = 'all';
  AppRole? roleFilter;

  AdminViewModel get vm => component.vm;

  List<SitewiseUser> get _filtered {
    final q = query.trim().toLowerCase();
    return vm.users.where((user) {
      final matchesQ =
          q.isEmpty || '${user.name} ${user.email}'.toLowerCase().contains(q);
      final matchesStatus =
          statusFilter == 'all' ||
          user.status.toLowerCase() == statusFilter.toLowerCase();
      final matchesRole = roleFilter == null || user.role == roleFilter;
      return matchesQ && matchesStatus && matchesRole;
    }).toList();
  }

  String _joined(SitewiseUser user) {
    final m = user.joinedAt.month.toString().padLeft(2, '0');
    final d = user.joinedAt.day.toString().padLeft(2, '0');
    return '${user.joinedAt.year}-$m-$d';
  }

  int _listingCount(SitewiseUser user) =>
      vm.listings.where((prop) => prop.ownerId == user.id).length;

  Component _selectField({
    required String labelText,
    required String value,
    required List<(String, String)> options,
    required void Function(String) onChanged,
  }) => Field(
    labelText: labelText,
    child: select(events: events<String>(onInput: (raw) => onChanged(raw)), [
      for (final opt in options)
        option(
          value: opt.$2,
          attributes: {if (opt.$2 == value) 'selected': ''},
          [Component.text(opt.$1)],
        ),
    ]),
  );

  @override
  Component build(BuildContext context) {
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
            options: const [
              ('All statuses', 'all'),
              ('Active', 'active'),
              ('Suspended', 'suspended'),
            ],
            onChanged: (v) => setState(() => statusFilter = v),
          ),
          _selectField(
            labelText: 'Role',
            value: roleFilter?.label ?? 'all',
            options: const [
              ('All roles', 'all'),
              ('Entrepreneur', 'entrepreneur'),
              ('Owner', 'owner'),
              ('Agent', 'agent'),
              ('Administrator', 'admin'),
            ],
            onChanged: (v) => setState(() {
              roleFilter = switch (v) {
                'entrepreneur' => AppRole.entrepreneur,
                'owner' => AppRole.owner,
                'agent' => AppRole.agent,
                'admin' => AppRole.admin,
                _ => null,
              };
            }),
          ),
        ]),
      ]),

      provider.Selector<
        AdminViewModel,
        ({List<SitewiseUser> users, List<CommercialProperty> listings})
      >(
        selector: (context, vm) => (users: vm.users, listings: vm.listings),
        builder: (context, data, child) {
          final users = _filtered;
          if (users.isEmpty) {
            return EmptyState(
              title: 'No accounts match',
              body: 'Try a different search or filter.',
            );
          }
          return SectionCard(
            title:
                '${users.length} '
                '${users.length == 1 ? 'account' : 'accounts'}',
            flush: true,
            child: div(classes: 'table-scroll', [
              table(classes: 'audit-table', [
                thead([
                  tr([
                    th([Component.text('Account')]),
                    th([Component.text('Role')]),
                    th([Component.text('Status')]),
                    th([Component.text('Listings')]),
                    th([Component.text('Joined')]),
                    th([Component.text('')]),
                  ]),
                ]),
                tbody([
                  for (final user in users)
                    tr([
                      td([
                        // The account itself links into the detail route so
                        // the directory row is the entry point to account
                        // management — not a dead end.
                        AppLink(
                          to: '/admin/user-detail?id=${Uri.encodeComponent(user.id)}',
                          classes: 'who text-action',
                          children: [Component.text(user.name)],
                        ),
                        span(classes: 'sub', [Component.text(user.email)]),
                      ]),
                      td([
                        user.role == AppRole.admin
                            ? span(classes: 'badge badge-info', [
                                Component.text('Administrator'),
                              ])
                            : span(classes: 'badge badge-muted', [
                                Component.text('User'),
                              ]),
                      ]),
                      td([StatusBadge.forText(user.status)]),
                      td([Component.text('${_listingCount(user)}')]),
                      td([Component.text(_joined(user))]),
                      td([
                        div(classes: 'stack stack--xs', [
                          AppLink(
                            to: '/admin/user-detail?id=${Uri.encodeComponent(user.id)}',
                            classes: 'text-action',
                            children: [Component.text('Manage')],
                          ),
                          if (user.role == AppRole.admin)
                            span(classes: 'stat-note', [
                              Component.text('Protected account'),
                            ]),
                        ]),
                      ]),
                    ]),
                ]),
              ]),
            ]),
          );
        },
      ),
      p(classes: 'stat-note', [
        Component.text(
          'Only the fields needed to administer an account are shown. '
          'Passwords and other private credentials are never exposed.',
        ),
      ]),
    ]);
  }
}
