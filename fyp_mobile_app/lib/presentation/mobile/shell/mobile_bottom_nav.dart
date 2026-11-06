import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/routing/app_routes.dart';
import '../../../core/theme/sitewise_m3.dart';
import '../../../core/theme/sitewise_theme.dart';
import '../../shared/widgets/sitewise_icon.dart';
import 'mobile_navigation.dart';

/// Mobile bottom navigation. Highlights the parent section for detail routes
/// (e.g. property detail highlights Listing).
///
/// Two renderings:
///  * **classic** — `BottomNavigationBar`, kept for any shell that still wants
///    a full-bleed bar;
///  * **floating dock** — the entrepreneur workspace (`m3: true`): an inset,
///    rounded, shadow-stacked bar whose active tab is marked by a sliding pill
///    and a label that fades in only on that tab.
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
    // Roles without a mobile workspace get no bar at all — and both renderings
    // assume at least one destination (five slots, BottomNavigationBar's
    // two-item minimum).
    if (destinations.isEmpty) return const SizedBox.shrink();

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
              icon: Icon(d.icon, size: SitewiseIconIntent.nav.size),
              activeIcon: Icon(d.icon, size: SitewiseIconIntent.nav.size),
              label: d.label,
            ),
        ],
      ),
    );
  }
}

/// `.bottom` — floating dock: an inset, fully-rounded surface that hovers
/// clear of the system gesture area, using the style guide's nav-pill surface
/// and two-stage shadow.
///
/// The active destination is carried by a pill that *slides* between slots
/// (one widget, so the move is continuous), while the glyph lifts into it,
/// scales up a fraction and cross-fades to the active colour. Inactive labels
/// are held at opacity 0 — they keep their layout slot, so nothing jumps, and
/// [RenderOpacity] drops them from the semantics tree, so a screen reader
/// hears only the tab it is on.
class _M3Bar extends StatelessWidget {
  final List<MobileDestination> destinations;
  final int activeIndex;
  final ValueChanged<String> onGo;

  const _M3Bar(this.destinations, this.activeIndex, this.onGo);

  @override
  Widget build(BuildContext context) {
    final safeBottom = MediaQuery.paddingOf(context).bottom;

    return Padding(
      padding: EdgeInsets.only(
        left: SitewiseM3.dockSideInset,
        right: SitewiseM3.dockSideInset,
        bottom: SitewiseM3.dockBottomInset + safeBottom,
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final count = destinations.length;
          final slot = constraints.maxWidth / count;
          // Never let two pills touch on a narrow screen.
          final pillWidth = math.min(SitewiseM3.dockPillWidth, slot - 10);

          return Container(
            height: SitewiseM3.tabHeight,
            decoration: BoxDecoration(
              color: SitewiseM3.dockSurface,
              borderRadius: BorderRadius.circular(SitewiseM3.radiusPill),
              border: Border.all(color: SitewiseM3.dockBorder),
              boxShadow: SitewiseM3.dockShadows,
            ),
            // Transparent material so taps still splash *above* the surface,
            // clipped to the dock's own pill outline.
            child: Material(
              type: MaterialType.transparency,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(SitewiseM3.radiusPill),
              ),
              clipBehavior: Clip.antiAlias,
              child: Stack(
                children: [
                  AnimatedPositioned(
                    duration: SitewiseM3.dockMotion,
                    curve: Curves.easeOutCubic,
                    left: activeIndex * slot + (slot - pillWidth) / 2,
                    top: SitewiseM3.dockPillTop,
                    child: Container(
                      width: pillWidth,
                      height: SitewiseM3.dockPillHeight,
                      decoration: BoxDecoration(
                        color: SitewiseM3.quietStrong,
                        borderRadius: BorderRadius.circular(
                          SitewiseM3.radiusPill,
                        ),
                        border: Border.all(color: SitewiseM3.brandBorder),
                      ),
                    ),
                  ),
                  Positioned.fill(
                    child: Semantics(
                      container: true,
                      label: 'Primary navigation',
                      child: Row(
                        children: [
                          for (var i = 0; i < count; i++)
                            Expanded(
                              child: _DockTab(
                                destination: destinations[i],
                                index: i,
                                count: count,
                                active: i == activeIndex,
                                onTap: () => onGo(destinations[i].route),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// One dock slot. The slot is the tap target: five equal shares of the dock
/// inside a [SitewiseM3.tabHeight]-high row, which stays above 48x48 down to a
/// 320dp viewport (58 wide at the narrowest size we target).
class _DockTab extends StatelessWidget {
  final MobileDestination destination;
  final int index;
  final int count;
  final bool active;
  final VoidCallback onTap;

  const _DockTab({
    required this.destination,
    required this.index,
    required this.count,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: active,
      label: '${destination.label} tab',
      hint: 'Tab ${index + 1} of $count',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(SitewiseM3.radiusPill),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              height: SitewiseM3.dockPillHeight,
              child: AnimatedSlide(
                duration: SitewiseM3.dockMotion,
                curve: Curves.easeOutCubic,
                // Idle glyphs rest below the pill centre; the active one
                // rises into it.
                offset: active ? Offset.zero : const Offset(0, 0.12),
                child: AnimatedScale(
                  duration: SitewiseM3.dockMotion,
                  curve: Curves.easeOutBack,
                  scale: active ? 1.08 : 1,
                  child: TweenAnimationBuilder<Color?>(
                    duration: SitewiseM3.dockMotion,
                    curve: Curves.easeOut,
                    tween: ColorTween(
                      begin: SitewiseM3.navInactive,
                      end: active ? SitewiseM3.navActive : SitewiseM3.navInactive,
                    ),
                    builder: (context, color, child) => SitewiseIcon(
                      destination.icon,
                      intent: SitewiseIconIntent.nav,
                      color: color,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 2),
            ExcludeSemantics(
              child: AnimatedOpacity(
                duration: SitewiseM3.dockMotion,
                curve: Curves.easeOut,
                opacity: active ? 1 : 0,
                child: Text(
                  destination.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: 10,
                    height: 1.2,
                    fontWeight: active ? FontWeight.w800 : FontWeight.w600,
                    color: active
                        ? SitewiseM3.navActive
                        : SitewiseM3.navInactive,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
