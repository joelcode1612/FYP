import 'package:shared_logic/shared_logic.dart';
import 'package:flutter/material.dart';

import '../../../core/theme/sitewise_m3.dart';
import '../../../core/theme/sitewise_theme.dart';
import '../../../presentation/mobile/widgets/m3_kit.dart';
import '../../shared/widgets/sitewise_brand.dart';
import '../../shared/widgets/sitewise_role_menu.dart';

/// Compact mobile header.
///
/// `m3: true` renders the Material 3 reference `.app-head`: paper background,
/// the real Sitewise brand lockup, rounded utility buttons and a hairline
/// bottom border. Back navigation, caller [actions] and the demo role menu are
/// preserved so detail pages keep every affordance they had.
///
/// Admin / owner keep the classic [AppBar] treatment (`m3: false`).

class MobileTopBar extends StatelessWidget implements PreferredSizeWidget {
  final String title;
  final List<Widget>? actions;
  final AppCubit appState;

  /// Render the Sitewise wordmark instead of the text title (used on Home).
  final bool brandTitle;

  /// Opt into the Material 3 post-sign-in chrome.
  final bool m3;

  const MobileTopBar({
    super.key,
    required this.title,
    required this.actions,
    required this.appState,
    this.brandTitle = false,
    this.m3 = false,
  });

  @override
  Size get preferredSize => Size.fromHeight(m3 ? 62 : kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    final canPop = Navigator.of(context).canPop();
    if (!m3) return _classic(context, canPop);
    return _m3(context, canPop);
  }

  // ── Classic (admin / owner) ────────────────────────────────────────────────
  Widget _classic(BuildContext context, bool canPop) {
    return AppBar(
      backgroundColor: SitewiseColors.surface,
      foregroundColor: SitewiseColors.ink,
      surfaceTintColor: SitewiseColors.surface,
      elevation: 0,
      scrolledUnderElevation: 0,
      shape: const Border(bottom: BorderSide(color: SitewiseColors.border)),
      automaticallyImplyLeading: false,
      centerTitle: false,
      titleSpacing: 0,
      leadingWidth: 48,
      leading: _leading(context, canPop),
      title: brandTitle
          ? const SitewiseBrand(fontSize: 17)
          : Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: SitewiseColors.ink,
              ),
            ),
      actions: [
        ...?actions,
        if (appState.role == AppRole.entrepreneur)
          InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: () =>
                Navigator.of(context).pushNamed('/entrepreneur/profile'),
            child: const Padding(
              padding: EdgeInsets.all(8),
              child: CircleAvatar(
                radius: 16,
                backgroundColor: SitewiseColors.geoWash,
                child: Text(
                  'S',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: SitewiseColors.action,
                  ),
                ),
              ),
            ),
          ),
        SitewiseRoleMenu(appState: appState),
        const SizedBox(width: 4),
      ],
    );
  }

  // ── Material 3 (entrepreneur post-sign-in) ────────────────────────────────
  Widget _m3(BuildContext context, bool canPop) {
    void notify() => ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('You have no new notifications.'),
        behavior: SnackBarBehavior.floating,
      ),
    );

    return AppBar(
      automaticallyImplyLeading: false,
      backgroundColor: SitewiseM3.paper,
      surfaceTintColor: SitewiseM3.paper,
      foregroundColor: SitewiseM3.ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      toolbarHeight: 62,
      titleSpacing: 10,
      leadingWidth: canPop ? 46 : 16,
      leading: canPop
          ? Padding(
              padding: const EdgeInsets.only(left: 8),
              child: IconButton(
                tooltip: 'Back',
                onPressed: () => Navigator.of(context).maybePop(),
                icon: const Icon(
                  Icons.arrow_back_rounded,
                  size: 22,
                  color: SitewiseM3.circleBtnIcon,
                ),
              ),
            )
          : const SizedBox.shrink(),
      shape: const Border(
        bottom: BorderSide(color: SitewiseM3.divider, width: 1),
      ),
      title: const M3BrandLockup(),
      actions: [
        ...?actions,
        M3CircleButton(
          icon: Icons.notifications_none_rounded,
          tooltip: 'Notifications',
          onTap: notify,
        ),
        M3CircleButton(
          icon: Icons.person_outline_rounded,
          tooltip: 'Profile',
          onTap: () =>
              Navigator.of(context).pushNamed('/entrepreneur/profile'),
        ),
        // Only two utility buttons — Notifications and Profile — matching the
        // reference `.app-head .right`. The mobile build is entrepreneur-only,
        // so the demo role switcher is intentionally NOT exposed here. The
        // classic (admin / owner) header below keeps its own account menu.
        const SizedBox(width: 6),
      ],
    );
  }

  Widget _leading(BuildContext context, bool canPop) {
    if (canPop) {
      return IconButton(
        tooltip: 'Back',
        icon: const Icon(Icons.arrow_back),
        onPressed: () => Navigator.of(context).maybePop(),
      );
    }
    return const Padding(
      padding: EdgeInsets.only(left: 12),
      child: Icon(Icons.location_on, size: 24, color: SitewiseColors.action),
    );
  }
}
