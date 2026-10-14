import 'package:flutter/material.dart';

import '../../../core/theme/sitewise_theme.dart';
import '../../shared/widgets/sitewise_brand.dart';

/// Mobile Home header — the reference pattern: a menu control on the left, the
/// Sitewise wordmark centred, and a single utility action on the right.
///
/// This is *page-level* chrome that scrolls with Home, not a Material [AppBar].
/// Detail/tab pages keep using [MobileTopBar]. Home deliberately shows no
/// Web/Mobile switch, no preview toggle, no role switcher and no device switch
/// — it has to read as a shipping application.
///
/// [onMenu] opens the account/role menu (the existing [SitewiseRoleMenu]
/// surface, supplied by the caller so this widget stays free of app state).
/// [actionIcon]/[onAction] carry the one role-relevant utility (notifications
/// for admin/owner, profile/saved for the entrepreneur); omit them and the
/// right slot collapses so the brand stays optically centred.

class MobileHomeHeader extends StatelessWidget {
  final VoidCallback onMenu;
  final IconData? actionIcon;
  final VoidCallback? onAction;
  final String actionTooltip;
  final int badgeCount;

  const MobileHomeHeader({
    super.key,
    required this.onMenu,
    this.actionIcon,
    this.onAction,
    this.actionTooltip = 'Notifications',
    this.badgeCount = 0,
  });

  @override
  Widget build(BuildContext context) {
    // Asymmetric 44/44 leading and trailing slots keep the brand centred
    // whether or not the optional action is present.
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
      child: Row(
        children: [
          _HeaderIconButton(
            icon: Icons.menu_rounded,
            tooltip: 'Menu',
            onTap: onMenu,
          ),
          Expanded(
            child: Center(
              child: ExcludeSemantics(child: SitewiseBrand(fontSize: 18)),
            ),
          ),
          if (actionIcon != null && onAction != null)
            _HeaderIconButton(
              icon: actionIcon!,
              tooltip: actionTooltip,
              onTap: onAction!,
              badgeCount: badgeCount,
            )
          else
            const SizedBox(width: 44),
        ],
      ),
    );
  }
}

class _HeaderIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final int badgeCount;

  const _HeaderIconButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.badgeCount = 0,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 44,
      height: 44,
      child: Stack(
        alignment: Alignment.center,
        children: [
          IconButton(
            tooltip: tooltip,
            onPressed: onTap,
            iconSize: 22,
            splashRadius: 22,
            color: SitewiseColors.ink,
            icon: Icon(icon),
          ),
          if (badgeCount > 0)
            Positioned(
              top: 6,
              right: 6,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                constraints: const BoxConstraints(minWidth: 17),
                decoration: BoxDecoration(
                  color: SitewiseColors.action,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: SitewiseColors.surface, width: 1.5),
                ),
                child: Text(
                  badgeCount > 9 ? '9+' : '$badgeCount',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 9.5,
                    fontWeight: FontWeight.w800,
                    height: 1.2,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
