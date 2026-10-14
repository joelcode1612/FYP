import 'package:flutter/material.dart';

import '../../../core/routing/app_routes.dart';
import '../../../core/theme/sitewise_theme.dart';
import 'mobile_navigation.dart';

/// Mobile bottom navigation. Highlights the parent section for detail routes
/// (e.g. property detail highlights Explore). Mobile-only.
///
/// Uses [BottomNavigationBar] (which applies the bottom safe-area inset itself)
/// inside a hairline-bordered surface so the bar reads as part of the app
/// chrome rather than a floating element.

class MobileBottomNav extends StatelessWidget {
  final List<MobileDestination> destinations;
  final String currentRoute;
  final ValueChanged<String> onGo;

  const MobileBottomNav({
    super.key,
    required this.destinations,
    required this.currentRoute,
    required this.onGo,
  });

  @override
  Widget build(BuildContext context) {
    var index = destinations.indexWhere(
      (d) => d.route == parentShellRoute(currentRoute),
    );
    if (index < 0) index = 0;

    return DecoratedBox(
      decoration: const BoxDecoration(
        color: SitewiseColors.surface,
        border: Border(top: BorderSide(color: SitewiseColors.border)),
      ),
      child: BottomNavigationBar(
        currentIndex: index,
        onTap: (i) => onGo(destinations[i].route),
        type: BottomNavigationBarType.fixed,
        backgroundColor: SitewiseColors.surface,
        elevation: 0,
        selectedItemColor: SitewiseColors.action,
        unselectedItemColor: SitewiseColors.muted,
        showUnselectedLabels: true,
        selectedFontSize: 11,
        unselectedFontSize: 11,
        selectedLabelStyle: const TextStyle(fontWeight: FontWeight.w700),
        unselectedLabelStyle: const TextStyle(fontWeight: FontWeight.w500),
        items: [
          for (final d in destinations)
            BottomNavigationBarItem(
              icon: Icon(d.icon, size: 23),
              activeIcon: Icon(d.icon, size: 23),
              label: d.label,
            ),
        ],
      ),
    );
  }
}
