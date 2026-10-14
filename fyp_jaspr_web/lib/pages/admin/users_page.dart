import 'dart:async';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/bloc.dart';
import '../../components/ui.dart';
import '../../data/app_locator.dart';
import '../../layouts/app_layout.dart';

/// Web user management: desktop table with role/status columns.
///
/// Ported from `admin_users_web_page.dart`. The Flutter page keeps a local
/// `query` field filtered over `name`/`email` (not the cubit's `query`, which
/// searches more fields); this version does the same so the search scope
/// matches one-for-one. Row taps become name-cell links to the detail route.
class UsersPage extends StatefulComponent {
  const UsersPage({super.key});

  @override
  State<UsersPage> createState() => _UsersPageState();
}

class _UsersPageState extends State<UsersPage> {
  late final AdminCubit vm;
  String query = '';

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

  /// Clears the search box, which is also the way out of the "no matches"
  /// empty state — the state names its own escape hatch.
  void _clearQuery() => setState(() => query = '');

  @override
  Component build(BuildContext context) {
    return CubitBuilder<AdminCubit, AdminState>(
      cubit: vm,
      builder: (context, _) {
        final users = vm.users
            .where(
              (user) =>
                  query.isEmpty ||
                  '${user.name} ${user.email}'.toLowerCase().contains(
                    query.toLowerCase(),
                  ),
            )
            .toList();

        return AppLayout(
          role: AppRole.admin,
          currentRoute: '/admin/users',
          // The page header is rendered by `AppLayout`; a page must not render
          // its own `PageHead` or the title appears twice.
          title: 'Users',
          subtitle:
              'Every account on the platform across all three roles. '
              'Search by name or email, then open a record to review its '
              'activity and access.',
          child: div(classes: 'stack stack--sections', [
            SearchInput(
              label: 'Search users',
              placeholder: 'Search by name or email…',
              ariaLabel: 'Search users by name or email',
              onInput: (value) => setState(() => query = value),
            ),

            if (vm.loading)
              const Skeleton(variant: 'row', count: 6)
            else if (users.isEmpty)
              EmptyState(
                icon: query.isEmpty ? 'group' : 'search_off',
                title: query.isEmpty
                    ? 'No accounts yet'
                    : 'No users match that search',
                body: query.isEmpty
                    ? 'When accounts are created they will appear here with '
                          'their role and status.'
                    : 'Nothing matched "$query". Try a different name or '
                          'email, or clear the search to see all accounts.',
                action: query.isEmpty
                    ? null
                    : ActionButton(
                        'Clear search',
                        icon: 'close',
                        variant: 'secondary',
                        onClick: _clearQuery,
                      ),
              )
            else
              SectionCard(
                title:
                    '${users.length} '
                    '${users.length == 1 ? 'account' : 'accounts'}',
                flush: true,
                child: div(classes: 'table-scroll', [
                  table(classes: 'table', [
                    thead([
                      tr([
                        th([Component.text('Name')]),
                        th([Component.text('Role')]),
                        th([Component.text('Email')]),
                        th([Component.text('Status')]),
                      ]),
                    ]),
                    tbody([
                      for (final u in users)
                        tr([
                          td([
                            a(
                              href: '/admin/user-detail?id=${u.id}',
                              classes: 'text-action',
                              [Component.text(u.name)],
                            ),
                          ]),
                          td([Component.text(u.role.label)]),
                          td([Component.text(u.email)]),
                          // Status is a free-text field on the User entity,
                          // so the tone is derived by keyword rather than
                          // pretending there is an enum behind it.
                          td([StatusBadge.forText(u.status)]),
                        ]),
                    ]),
                  ]),
                ]),
              ),
          ]),
        );
      },
    );
  }
}
