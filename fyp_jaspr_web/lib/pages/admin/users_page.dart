import 'dart:async';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/bloc.dart';
import '../../components/ui.dart';
import '../../data/app_locator.dart';
import '../../layouts/app_layout.dart';

/// Web user management, ported to the source `admin/users.html` structure: a
/// `.filters` bar (Search + Status + Role, in a `.grid-3`) above an
/// `.audit-table` whose Account cell uses `.who`/`.sub` and whose Status cell
/// uses `.st`.
///
/// The source's Suspend/Reactivate action is intentionally omitted: the data
/// layer exposes no `setUserStatus`, so the table is read-only here. The
/// Listings column is derived from `vm.listings` (the entity has no count of
/// its own), and Joined is the user's `joinedAt`.
@client
class UsersPage extends StatefulComponent {
  const UsersPage({super.key});

  @override
  State<UsersPage> createState() => _UsersPageState();
}

class _UsersPageState extends State<UsersPage> {
  late final AdminCubit vm;
  String query = '';
  String statusFilter = 'all';
  AppRole? roleFilter;

  @override
  void initState() {
    super.initState();
    vm = AppLocator.newAdminCubit();
    unawaited(vm.loadUsers());
  }

  @override
  void dispose() {
    unawaited(vm.close());
    super.dispose();
  }

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
    return CubitBuilder<AdminCubit, AdminState>(
      cubit: vm,
      builder: (context, _) {
        final users = _filtered;

        return AppLayout(
          role: AppRole.admin,
          currentRoute: '/admin/users',
          // The page header is rendered by `AppLayout`; a page must not render
          // its own `PageHead` or the title appears twice.
          title: 'Users',
          eyebrow: 'Accounts',
          subtitle:
              'Account status only. Roles are not editable from this screen — '
              'changing a role requires a separate permission path that this '
              'build does not implement.',
          child: div(classes: 'stack stack--sections', [
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

            if (vm.loading)
              const Skeleton(variant: 'row', count: 6)
            else if (users.isEmpty)
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
                            span(classes: 'who', [Component.text(user.name)]),
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
                            if (user.role == AppRole.admin)
                              span(classes: 'stat-note', [
                                Component.text('Admin accounts are protected'),
                              ])
                            else
                              const Component.text(''),
                          ]),
                        ]),
                    ]),
                  ]),
                ]),
              ),
            p(classes: 'stat-note', [
              Component.text(
                'Only the fields needed to administer an account are shown. '
                'Passwords and other private credentials are never exposed.',
              ),
            ]),
          ]),
        );
      },
    );
  }
}
