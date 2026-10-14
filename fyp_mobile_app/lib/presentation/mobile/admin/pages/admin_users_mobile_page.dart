import '../../../../application/services/service_locator.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:shared_logic/shared_logic.dart';
import 'package:flutter/material.dart';

import '../../../../core/theme/sitewise_theme.dart';
import '../../../shared/widgets/sitewise_loading_state.dart';
import '../../../shared/widgets/sitewise_search_bar.dart';
import '../../shell/mobile_app_shell.dart';

/// Mobile user management: user cards instead of a wide table.

class AdminUsersMobilePage extends StatefulWidget {
  final AppCubit appState;
  const AdminUsersMobilePage({super.key, required this.appState});

  @override
  State<AdminUsersMobilePage> createState() => _AdminUsersMobilePageState();
}

class _AdminUsersMobilePageState extends State<AdminUsersMobilePage> {
  final vm = ServiceLocator.newAdminCubit();
  String query = '';

  @override
  void initState() {
    super.initState();
    vm.loadUsers();
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<AppCubit, AppState>(
      bloc: widget.appState,
      builder: (ctx, _) => BlocBuilder<AdminCubit, AdminState>(
        bloc: vm,
        builder: (ctx, _) {
        final users = vm.users
            .where(
              (u) =>
                  query.isEmpty ||
                  '${u.name} ${u.email}'.toLowerCase().contains(
                    query.toLowerCase(),
                  ),
            )
            .toList();
        return MobileAppShell(
          appState: widget.appState,
          title: 'Users',
          currentRoute: '/admin/users',
          body: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: SitewiseSearchBar(
                  hint: 'Search users…',
                  onChanged: (v) => setState(() => query = v),
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: vm.loading
                    ? const SitewiseLoadingState()
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                        itemCount: users.length,
                        itemBuilder: (c, i) {
                          final u = users[i];
                          return Card(
                            child: ListTile(
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 4,
                              ),
                              leading: CircleAvatar(child: Text(u.name[0])),
                              title: Text(
                                u.name,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              subtitle: Text(
                                '${u.role.label} · ${u.email}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 4,
                                    ),
                                    decoration: BoxDecoration(
                                      color: SitewiseColors.geoWash,
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: Text(
                                      u.status,
                                      style: const TextStyle(fontSize: 11),
                                    ),
                                  ),
                                  const Icon(
                                    Icons.chevron_right,
                                    color: SitewiseColors.muted,
                                  ),
                                ],
                              ),
                              onTap: () => Navigator.of(context).pushNamed(
                                '/admin/user-detail',
                                arguments: u.id,
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
      ),
    );
  }
}
