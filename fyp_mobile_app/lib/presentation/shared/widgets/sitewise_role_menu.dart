import 'package:shared_logic/shared_logic.dart';
import 'package:flutter/material.dart';

import '../../../application/services/service_locator.dart';

/// Account menu shared by the mobile shell: the demo role switcher plus Log
/// out.
///
/// Logging out clears the session through the auth application layer and
/// returns to the mobile auth screen. Onboarding is never shown again (its
/// completion flag is separate).

class SitewiseRoleMenu extends StatelessWidget {
  final AppCubit appState;

  const SitewiseRoleMenu({super.key, required this.appState});

  /// Opens the same account menu that [SitewiseRoleMenu] renders, anchored to
  /// [anchor]. Used by the mobile Home header's menu button, so Home and the
  /// AppBar expose exactly one account surface instead of two.
  static Future<void> show(
    BuildContext context,
    AppCubit appState, {
    Rect? anchor,
  }) async {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    final position = anchor == null || overlay == null
        ? null
        : RelativeRect.fromRect(anchor, Offset.zero & overlay.size);
    final value = await showMenu<String>(
      context: context,
      position: position ?? RelativeRect.fromLTRB(12, kToolbarHeight, 12, 0),
      items: _itemsFor(appState),
    );
    if (value == null || !context.mounted) return;
    _handle(context, appState, value);
  }

  Future<void> _logOut(BuildContext context) async {
    await ServiceLocator.auth.signOut();
    if (!context.mounted) return;
    Navigator.of(context).pushNamedAndRemoveUntil('/auth', (_) => false);
  }

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: 'Account',
      icon: const Icon(Icons.switch_account_outlined),
      onSelected: (value) => _handle(context, appState, value),
      itemBuilder: (_) => _itemsFor(appState),
    );
  }

  static List<PopupMenuEntry<String>> _itemsFor(AppCubit appState) => [
    for (final role in AppRole.values)
      PopupMenuItem(
        value: role.name,
        child: Text('${role.label}${role == appState.role ? ' ✓' : ''}'),
      ),
    const PopupMenuDivider(),
    const PopupMenuItem(value: 'logout', child: Text('Log out')),
  ];

  static void _handle(BuildContext context, AppCubit appState, String value) {
    if (value == 'logout') {
      SitewiseRoleMenu(appState: appState)._logOut(context);
      return;
    }
    final role = AppRole.values.firstWhere((r) => r.name == value);
    appState.setRole(role);
    Navigator.of(context).pushNamedAndRemoveUntil(role.homeRoute, (_) => false);
  }
}
