import 'package:flutter/material.dart';

import '../../../core/routing/app_routes.dart';
import '../../../core/theme/sitewise_m3.dart';
import '../../../core/theme/sitewise_theme.dart';
import 'mobile_navigation.dart';

/// Mobile bottom navigation. Highlights the parent section for detail routes
/// (e.g. property detail highlights Listing).
///
/// Two renderings:
///  * **classic** — `BottomNavigationBar`, used by the admin / owner shells;
///  * **Material 3** — the reference's five-tab row with a 61×33 pill
///    indicator behind the active icon (`m3: true`). Used by the entrepreneur
///    post-sign-in workspace.
///
/// Both share the same [destinations] / [currentRoute] / [onGo] contract, so
/// the shell never needs to know which one it is showing.

class MobileBottomNav extends StatelessWidget {
  final List<MobileDestination> destinations;
  final String currentRoute;
  final ValueChanged<String> onGo;

  /// Opt into the Material 3 pill-indicator rendering.
  final bool m3;

  const MobileBottomNav({
    super.key,
    required this.destinations,
    required this.currentRoute,
    required this.onGo,
    this.m3 = false,
  });

  @override
  Widget build(BuildContext context) {
    var index = destinations.indexWhere(
      (d) => d.route == parentShellRoute(currentRoute),
    );
    if (index < 0) index = 0;

    if (m3) return _M3Bar(destinations, index, onGo);

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

/// `.bottom` — full-width white bar, hairline top border, five equal tabs.
/// The active tab draws a rounded `quietStrong` pill behind its icon.
class _M3Bar extends StatelessWidget {
  final List<MobileDestination> destinations;
  final int activeIndex;
  final ValueChanged<String> onGo;

  const _M3Bar(this.destinations, this.activeIndex, this.onGo);

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    return Container(
      decoration: const BoxDecoration(
        color: SitewiseM3.surface,
        border: Border(top: BorderSide(color: SitewiseM3.divider)),
        boxShadow: [
          BoxShadow(
            color: Color(0x0A2A548E),
            blurRadius: 25,
            offset: Offset(0, -8),
          ),
        ],
      ),
      padding: EdgeInsets.only(
        top: 9,
        bottom: bottomInset > 10 ? bottomInset : 10,
        left: 5,
        right: 5,
      ),
      child: Row(
        children: [
          for (var i = 0; i < destinations.length; i++)
            Expanded(child: _Tab(
              destination: destinations[i],
              active: i == activeIndex,
              onTap: () => onGo(destinations[i].route),
            )),
        ],
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  final MobileDestination destination;
  final bool active;
  final VoidCallback onTap;

  const _Tab({
    required this.destination,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: active,
      label: '${destination.label} tab',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(13),
        child: SizedBox(
          height: SitewiseM3.tabHeight,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.start,
            children: [
              Container(
                width: SitewiseM3.indicatorWidth,
                height: SitewiseM3.indicatorHeight,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: active ? SitewiseM3.quietStrong : Colors.transparent,
                  borderRadius: BorderRadius.circular(
                    SitewiseM3.radiusPill,
                  ),
                ),
                child: Icon(
                  destination.icon,
                  size: 22,
                  color: active ? const Color(0xFF1B4BB7) : const Color(0xFF64758E),
                ),
              ),
              const SizedBox(height: 3),
              Text(
                destination.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: 'Archivo',
                  fontSize: 10,
                  fontWeight: active ? FontWeight.w800 : FontWeight.w600,
                  color: active ? const Color(0xFF1B4BB7) : const Color(0xFF64758E),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
