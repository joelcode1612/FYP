import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';
import 'package:flutter/material.dart';

import '../../../core/routing/mobile_role.dart';

/// Account menu shared by the mobile shell: the demo role switcher plus Log
/// out.
///
/// Logging out clears the session through the shared auth state machine and
/// returns to the mobile auth screen, so the route guard sees the same
/// sign-out the menu performed. Onboarding is never shown again (its
/// completion flag is separate).

class SitewiseRoleMenu extends ConsumerWidget {
  const SitewiseRoleMenu({super.key});

  /// Opens the same account menu that [SitewiseRoleMenu] renders, anchored to
  /// [anchor]. Used by the mobile Home header's menu button, so Home and the
  /// AppBar expose exactly one account surface instead of two.
  static Future<void> show(BuildContext context, {Rect? anchor}) async {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    final position = anchor == null || overlay == null
        ? null
        : RelativeRect.fromRect(anchor, Offset.zero & overlay.size);
    final value = await showMenu<String>(
      context: context,
      position: position ?? RelativeRect.fromLTRB(12, kToolbarHeight, 12, 0),
      items: _itemsFor(context),
    );
    if (value == null || !context.mounted) return;
    _handle(context, value);
  }

  static Future<void> _logOut(BuildContext context) async {
    // Through the shared auth state, so the guard and every screen lose the
    // session at the same moment instead of only the repository knowing.
    final container = ProviderScope.containerOf(context, listen: false);
    await container.read(authNotifierProvider.notifier).signOut();
    if (!context.mounted) return;
    Navigator.of(context).pushNamedAndRemoveUntil('/auth', (_) => false);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PopupMenuButton<String>(
      tooltip: 'Account',
      icon: const Icon(Icons.switch_account_outlined),
      onSelected: (value) => _handle(context, value),
      itemBuilder: (_) => _itemsFor(context),
    );
  }

  static List<PopupMenuEntry<String>> _itemsFor(BuildContext context) {
    final appState = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appNotifierProvider);
    return [
      // Only roles with a mobile workspace are offered — the rest belong to
      // fyp_jaspr_web and would route to a screen that no longer exists here.
      for (final role in mobileSupportedRoles)
        PopupMenuItem(
          value: role.name,
          child: Text('${role.label}${role == appState.role ? ' ✓' : ''}'),
        ),
      const PopupMenuDivider(),
      const PopupMenuItem(value: 'logout', child: Text('Log out')),
    ];
  }

  static void _handle(BuildContext context, String value) {
    if (value == 'logout') {
      _logOut(context);
      return;
    }
    final role = mobileSupportedRoles.firstWhere((r) => r.name == value);
    ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appNotifierProvider.notifier).setRole(role);
    Navigator.of(context).pushNamedAndRemoveUntil(role.homeRoute, (_) => false);
  }
}
