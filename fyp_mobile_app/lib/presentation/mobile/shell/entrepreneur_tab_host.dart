import 'package:flutter/material.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../../core/theme/sitewise_m3.dart';
import '../entrepreneur/pages/entrepreneur_assess_mobile_page.dart';
import '../entrepreneur/pages/entrepreneur_dashboard_mobile_page.dart';
import '../entrepreneur/pages/entrepreneur_explore_mobile_page.dart';
import '../entrepreneur/pages/entrepreneur_profile_mobile_page.dart';
import '../entrepreneur/pages/entrepreneur_spaces_mobile_page.dart';
import 'entrepreneur_tab_scope.dart';
import 'mobile_bottom_nav.dart';
import 'mobile_navigation.dart';
import 'mobile_topbar.dart';

/// One persistent Scaffold for the five primary mobile tabs.
///
/// The page widgets remain unchanged: their MobileAppShell detects the
/// [EntrepreneurTabScope] and renders only their body while inside this host.
/// Other routes (property detail, preferences, assessments, capture, etc.)
/// continue using the existing Navigator and AuthGuard.
class EntrepreneurTabHost extends StatefulWidget {
  const EntrepreneurTabHost({
    super.key,
    required this.initialRoute,
    this.initialArguments,
  });

  final String initialRoute;
  final Object? initialArguments;

  @override
  State<EntrepreneurTabHost> createState() => _EntrepreneurTabHostState();
}

class _EntrepreneurTabHostState extends State<EntrepreneurTabHost> {
  late final List<MobileDestination> _tabs = mobileDestinationsFor(
    AppRole.entrepreneur,
  );
  late final List<bool> _hasVisited;
  late int _selectedIndex;

  @override
  void initState() {
    super.initState();
    final startingIndex = _tabs.indexWhere(
          (tab) => tab.route == widget.initialRoute,
    );
    _selectedIndex = startingIndex < 0 ? 0 : startingIndex;
    _hasVisited = List<bool>.filled(_tabs.length, false);
    _hasVisited[_selectedIndex] = true;
  }

  void _selectTab(String route) {
    final next = _tabs.indexWhere((tab) => tab.route == route);
    if (next < 0 || next == _selectedIndex) return;
    setState(() {
      _selectedIndex = next;
      _hasVisited[next] = true; // Instantiate this page on first visit only.
    });
  }

  Widget _pageFor(String route) => switch (route) {
    '/entrepreneur' => const EntrepreneurDashboardMobilePage(),
    '/entrepreneur/explore' => EntrepreneurExploreMobilePage(
      startInMap:
      widget.initialRoute == '/entrepreneur/explore' &&
          widget.initialArguments == 'map',
    ),
    '/entrepreneur/assess' => const EntrepreneurAssessMobilePage(),
    '/entrepreneur/spaces' => const EntrepreneurSpacesMobilePage(),
    '/entrepreneur/profile' => const EntrepreneurProfileMobilePage(),
    _ => const SizedBox.shrink(),
  };

  @override
  Widget build(BuildContext context) {
    final current = _tabs[_selectedIndex];
    // Android back from a non-Home tab returns to Home; pop from Home retains
    // normal Navigator/platform behaviour. This does not affect detail routes.
    return PopScope<Object?>(
      canPop: _selectedIndex == 0,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _selectedIndex != 0) {
          _selectTab(_tabs.first.route);
        }
      },
      child: Scaffold(
        backgroundColor: SitewiseM3.paper,
        appBar: MobileTopBar(
          title: current.label,
          actions: const [],
          brandTitle: _selectedIndex == 0,
          m3: true,
        ),
        body: IndexedStack(
          index: _selectedIndex,
          children: [
            for (var i = 0; i < _tabs.length; i++)
              TickerMode(
                enabled: i == _selectedIndex,
                child: _hasVisited[i]
                    ? EntrepreneurTabScope(
                  onTabSelected: _selectTab,
                  child: _pageFor(_tabs[i].route),
                )
                    : const SizedBox.shrink(),
              ),
          ],
        ),
        bottomNavigationBar: MobileBottomNav(
          destinations: _tabs,
          currentRoute: current.route,
          onGo: _selectTab,
          m3: true,
        ),
      ),
    );
  }
}
