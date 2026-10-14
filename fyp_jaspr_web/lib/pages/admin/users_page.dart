import 'dart:async';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/bloc.dart';
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
          title: 'Users',
          subtitle: AppRole.admin.label,
          child: div(classes: 'stack', [
            div(classes: 'row', [
              input(
                type: InputType.search,
                classes: 'input',
                attributes: {
                  'placeholder': 'Search users…',
                  'aria-label': 'Search users',
                },
                events: events<String>(
                  onInput: (value) => setState(() => query = value),
                ),
              ),
            ]),
            vm.loading
                ? div(classes: 'card', [
                    p(classes: 'body muted', [Component.text('Loading…')]),
                  ])
                : div(classes: 'card', [
                    div(classes: 'table-scroll', [
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
                              td([Component.text(u.status)]),
                            ]),
                        ]),
                      ]),
                    ]),
                  ]),
          ]),
        );
      },
    );
  }
}
