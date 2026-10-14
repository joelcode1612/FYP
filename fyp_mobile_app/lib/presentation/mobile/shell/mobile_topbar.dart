import 'package:shared_logic/shared_logic.dart';
import 'package:flutter/material.dart';

import '../../../core/theme/sitewise_theme.dart';
import '../../shared/widgets/sitewise_brand.dart';
import '../../shared/widgets/sitewise_role_menu.dart';

/// Compact mobile header: plain back chevron when the route can pop (otherwise
/// the Sitewise mark, as on root tabs), a bold title beside it, and utility
/// actions on the right. Mobile-only — web uses [WebTopBar].

class MobileTopBar extends StatelessWidget implements PreferredSizeWidget {
  final String title;
  final List<Widget>? actions;
  final AppCubit appState;

  /// Render the Sitewise wordmark instead of the text title (used on Home).
  final bool brandTitle;

  const MobileTopBar({
    super.key,
    required this.title,
    required this.actions,
    required this.appState,
    this.brandTitle = false,
  });

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    final canPop = Navigator.of(context).canPop();
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
