import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../../../core/theme/sitewise_m3.dart';
import '../../shell/mobile_bottom_nav.dart';
import '../../shell/mobile_navigation.dart';
import '../../shell/mobile_topbar.dart';
import '../pages/provider_dashboard_controller.dart';
import '../pages/provider_dashboard_mobile_page.dart';
import '../pages/provider_enquiries_mobile_page.dart';
import '../pages/provider_listings_mobile_page.dart';
import '../pages/provider_performance_mobile_page.dart';
import '../pages/provider_profile_mobile_page.dart';
import '../pages/provider_schedule_mobile_page.dart';

/// Persistent shell for the Owner / Agent workspace.
///
/// It uses the **same** chrome as `EntrepreneurTabHost`: the Material 3
/// brand header (now carrying a role pill and a REAL unread badge on the
/// bell) and the floating, inset pill-indicator dock (`MobileBottomNav(m3:
/// true)`). Because the widgets are shared, nav height, background, active
/// indicator, icons, labels, spacing, radius, elevation, safe-area inset,
/// touch targets, reduced-motion transitions and selected states are
/// identical by construction rather than by duplicated constants.
///
/// The dock is **role-scoped** — one workspace, two viewpoints:
///
/// * **Property Owner** — `Home | Properties | Add | Messages | Profile`.
///   `Add` is an action, not a page: the form is pushed as a drill-in, so the
///   current tab stays alive behind it.
/// * **Agent** — `Home | Listings | Enquiries | Schedule | Profile`. The dock
///   has no Add slot, so an agent opens the SAME form from the `Add Property`
///   action on the shared listing screen.
///
/// Saving from either entry point returns to the shared `/provider/listings`
/// page, which is the same screen for both roles.
///
/// Both names point at the same shared pages (`/provider/listings`,
/// `/provider/enquiries`); nothing is duplicated per role. `Performance`
/// remains a registered route inside the stack for either role, opened from
/// the Dashboard's quick actions.
///
/// What differs between owner and agent DATA is decided server-side
/// (ownership vs assignment), never by a second UI.
class ProviderTabHost extends ConsumerStatefulWidget {
  const ProviderTabHost({super.key, required this.initialRoute});

  final String initialRoute;

  /// The dock destinations for the SIGNED-IN role. Kept as a static so tests
  /// and deep-link helpers can resolve the same list the shell renders.
  static List<MobileDestination> destinationsFor(AppRole role) =>
      providerDestinationsFor(role);

  /// Index into the persistent page stack for a `/provider...` shell route.
  /// Unknown routes land on the dashboard rather than on an arbitrary tab.
  static int indexForRoute(String route) => switch (route) {
    '/provider/listings' => 1,
    '/provider/enquiries' => 2,
    '/provider/performance' => 3,
    '/provider/profile' => 4,
    '/provider/schedule' => 5,
    _ => 0,
  };

  /// Reverse of [indexForRoute], used by the tests and by deep links.
  /// Performance remains a page in the stack (opened from Home) but is NOT a
  /// dock destination for either role.
  static const List<String> tabRoutes = [
    '/provider',
    '/provider/listings',
    '/provider/enquiries',
    '/provider/performance',
    '/provider/profile',
    '/provider/schedule',
  ];

  /// Dock route to highlight for each stack index. Performance is a Dashboard
  /// shortcut, so Home stays selected while the report is open.
  static const List<String> highlightForStack = [
    '/provider',
    '/provider/listings',
    '/provider/enquiries',
    '/provider',
    '/provider/profile',
    '/provider/schedule',
  ];

  @override
  ConsumerState<ProviderTabHost> createState() => _ProviderTabHostState();
}

class _ProviderTabHostState extends ConsumerState<ProviderTabHost> {
  late int _pageIndex = ProviderTabHost.indexForRoute(widget.initialRoute);

  /// Bumped when the Add Property form returns. Re-keying the listing-backed
  /// tabs makes a newly created draft visible immediately.
  int _revision = 0;

  /// The signed-in role. The verified session is authoritative; the app
  /// notifier (kept in step at every entry point) covers a session that has
  /// not published its profile yet.
  AppRole _roleOf(WidgetRef ref) =>
      ref.watch(authNotifierProvider.select((s) => s.user?.role)) ??
      ref.watch(appNotifierProvider.select((s) => s.role));

  void _selectTab(String route) {
    if (route == '/provider/add-property') {
      _addProperty();
      return;
    }
    final next = ProviderTabHost.indexForRoute(route);
    if (next == _pageIndex) return;
    setState(() {
      _pageIndex = next;
    });
  }

  /// The Add Property form is a drill-in, not a tab, so it is pushed and the
  /// current tab stays selected behind it.
  ///
  /// Saving hands back [addPropertyDoneResult], which lands BOTH roles on the
  /// shared `/provider/listings` page they came from; a plain cancel returns to
  /// the tab that was open before. Either way the listing-backed pages are
  /// re-keyed so a new or edited draft shows immediately.
  Future<void> _addProperty() async {
    final result = await Navigator.of(context).pushNamed(
      '/provider/add-property',
    );
    if (!mounted) return;
    setState(() {
      if (result == addPropertyDoneResult) {
        _pageIndex = ProviderTabHost.indexForRoute('/provider/listings');
      }
      _revision++;
    });
    // A new draft (or an edited one) changes every dashboard figure.
    ref.invalidate(providerDashboardProvider);
  }

  @override
  Widget build(BuildContext context) {
    final role = _roleOf(ref);
    final highlight = ProviderTabHost.highlightForStack[_pageIndex];
    // Real unread signal for the bell: new enquiries in this account's own
    // inbox, straight from the dashboard bundle. No session data -> no dot.
    final unread =
        ref.watch(providerDashboardProvider).value?.newEnquiryCount;
    // Android back from a non-Home tab returns to Home, matching the
    // entrepreneur workspace. Detail routes are unaffected: they are pushed
    // above this shell and keep their own back affordance.
    return PopScope<Object?>(
      canPop: _pageIndex == 0,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _pageIndex != 0) _selectTab('/provider');
      },
      child: Scaffold(
        backgroundColor: SitewiseM3.paper,
        appBar: MobileTopBar(
          title: 'Provider workspace',
          actions: const [],
          m3: true,
          // Root workspace: the dock destinations are top-level, so the header
          // must never offer a back arrow that pops the whole workspace.
          showBack: false,
          roleBadge: role == AppRole.agent ? 'Agent' : 'Property Owner',
          unreadNotifications: unread,
          onNotifications: () => _selectTab('/provider/enquiries'),
        ),
        body: IndexedStack(
          index: _pageIndex,
          children: [
            for (var i = 0; i < ProviderTabHost.tabRoutes.length; i++)
              _pageFor(i, _revision),
          ],
        ),
        bottomNavigationBar: MobileBottomNav(
          destinations: ProviderTabHost.destinationsFor(role),
          currentRoute: highlight,
          onGo: _selectTab,
          m3: true,
        ),
      ),
    );
  }

  Widget _pageFor(int index, int revision) {
    final key = ValueKey('provider-${ProviderTabHost.tabRoutes[index]}-$revision');
    return switch (index) {
      0 => ProviderDashboardMobilePage(key: key),
      1 => ProviderListingsMobilePage(key: key),
      2 => ProviderEnquiriesMobilePage(key: key),
      3 => ProviderPerformanceMobilePage(key: key),
      4 => ProviderProfileMobilePage(key: key),
      5 => ProviderScheduleMobilePage(key: key),
      _ => const SizedBox.shrink(),
    };
  }
}
