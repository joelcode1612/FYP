import 'package:shared_logic/shared_logic.dart';
import 'package:flutter/material.dart';

import '../../../../application/services/service_locator.dart';
import '../../../shared/widgets/sitewise_loading_state.dart';
import '../../shell/mobile_app_shell.dart';

/// Mobile user detail: single account card.

class AdminUserDetailMobilePage extends StatelessWidget {
  final AppCubit appState;
  final String userId;
  const AdminUserDetailMobilePage({
    super.key,
    required this.appState,
    required this.userId,
  });

  @override
  Widget build(BuildContext context) {
    return MobileAppShell(
      appState: appState,
      title: 'User detail',
      currentRoute: '/admin/users',
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: FutureBuilder<SitewiseUser?>(
          future: ServiceLocator.userRepo.getUserById(userId),
          builder: (ctx, snap) {
            if (!snap.hasData) return const SitewiseLoadingState();
            final user = snap.data!;
            return Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        CircleAvatar(
                          radius: 28,
                          child: Text(
                            user.name[0],
                            style: const TextStyle(fontSize: 22),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                user.name,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 18,
                                ),
                              ),
                              Text(user.email),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const Divider(height: 32),
                    _row('Role', user.role.label),
                    _row('Status', user.status),
                    _row('Location', user.location),
                    _row(
                      'Joined',
                      '${user.joinedAt.day}/${user.joinedAt.month}/${user.joinedAt.year}',
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _row(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      children: [
        SizedBox(
          width: 100,
          child: Text(label, style: const TextStyle(color: Colors.grey)),
        ),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
      ],
    ),
  );
}
