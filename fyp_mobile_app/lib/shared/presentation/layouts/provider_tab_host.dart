import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';

import 'package:fyp/core/theme/sitewise_m3.dart';
import 'package:fyp/features/property_management/presentation/pages/sitewise_add_property_mobile_page.dart';
import 'package:fyp/shared/presentation/layouts/mobile_bottom_nav.dart';
import 'package:fyp/core/routing/mobile_navigation.dart';
import 'package:fyp/shared/presentation/layouts/mobile_topbar.dart';
import 'package:fyp/features/dashboard/presentation/pages/provider_dashboard_mobile_page.dart';
import 'package:fyp/features/listing/presentation/pages/provider_listings_mobile_page.dart';
import 'package:fyp/features/property_management/presentation/pages/provider_owner_requests_mobile_page.dart';
import 'package:fyp/features/dashboard/presentation/pages/provider_performance_mobile_page.dart';
import 'package:fyp/features/profile/presentation/provider_profile_mobile_page.dart';
import 'package:fyp/features/property_management/presentation/pages/provider_tasks_mobile_page.dart';
import 'package:fyp/shared/presentation/layouts/provider_tab_scope.dart';

/// Persistent shell for the Owner / Agent workspace.
///
/// It uses the **same** chrome as `EntrepreneurTabHost`: the Material 3
/// brand header (now carrying a role pill) and the floating, inset
/// pill-indicator dock (`MobileBottomNav(m3: true)`). Because the widgets are
/// shared, nav height, background, active indicator, icons, labels, spacing,
/// radius, elevation, safe-area inset, touch targets, reduced-motion
/// transitions and selected states are identical by construction rather than
/// by duplicated constants.
///
/// The dock differs by role, the stack does not: an owner sees
/// `Home | Properties | Add | Profile`, an agent sees
/// `Home | Listings | Tasks | Profile`. Under both docks lives the SAME
/// persistent stack — those pages plus the hidden Performance shortcut and the
/// shared Add Property form. `Add` and `Tasks` each live in the same
/// `IndexedStack` as the other pages, so reaching them is a tab change rather
/// than a second full-screen route: an unfinished form survives a switch to
/// Home, and the task list keeps its filters when the agent opens a property
/// and comes back.
///
/// Deep links to `/provider/add-property` still resolve to the same form
/// through the central route table; only in-workspace navigation uses the
/// persistent page. A `/provider/tasks` deep link opened by a non-agent lands
/// on the dashboard, because the task projection behind it is the agent's
/// assignment view — there is nothing honest for another role to render.
///
/// What differs between owner and agent DATA is decided server-side
/// (ownership vs assignment), never by a second UI.
class ProviderTabHost extends ConsumerStatefulWidget {
  const ProviderTabHost({super.key, required this.initialRoute});

  final String initialRoute;

  static const String tasksRoute = '/provider/tasks';
  static const String requestsRoute = '/provider/requests';
  static const String addRoute = '/provider/add-property';
  static const int homeIndex = 0;
  static const int listingsIndex = 1;
  static const int tasksIndex = 2;
  static const int performanceIndex = 3;
  static const int profileIndex = 4;
  static const int addTabIndex = 5;
  static const int requestsIndex = 6;

  /// The dock destinations for the SIGNED-IN role. Kept as a static so tests
  /// and deep-link helpers can resolve the same list the shell renders.
  static List<MobileDestination> destinationsFor(AppRole role) =>
      providerDestinationsFor(role);

  /// Index into the persistent page stack for a `/provider...` shell route.
  /// Unknown routes land on the dashboard rather than on an arbitrary tab.
  static int indexForRoute(String route) => switch (route) {
    '/provider/listings' => listingsIndex,
    tasksRoute => tasksIndex,
    requestsRoute => requestsIndex,
    '/provider/performance' => performanceIndex,
    '/provider/profile' => profileIndex,
    addRoute => addTabIndex,
    _ => homeIndex,
  };

  /// Reverse of [indexForRoute], used by the tests and by deep links.
  /// Performance remains a page in the stack (opened from Home) but is NOT a
  /// dock destination for either role. The Add Property page is the last
  /// stack page so its form state survives dock switches.
  static const List<String> tabRoutes = [
    '/provider',
    '/provider/listings',
    tasksRoute,
    '/provider/performance',
    '/provider/profile',
    addRoute,
    requestsRoute,
  ];

  /// Dock route to highlight for each stack index. Performance is a Dashboard
  /// shortcut, so Home stays selected while the report is open.
  static const List<String> highlightForStack = [
    '/provider',
    '/provider/listings',
    tasksRoute,
    '/provider',
    '/provider/profile',
    addRoute,
    requestsRoute,
  ];

  @override
  ConsumerState<ProviderTabHost> createState() => _ProviderTabHostState();
}

class _ProviderTabHostState extends ConsumerState<ProviderTabHost> {
  late int _pageIndex;

  /// Where Android Back goes while the Add form is open. It is the tab that
  /// was selected immediately before Add, so Back can never drop an unfinished
  /// form by popping the whole workspace.
  late int _previousPageIndex;

  /// A draft resumed from Home/Listings is still a drill-in: it carries an id
  /// that the persistent blank form must not adopt. One guard is enough to
  /// stop repeated taps stacking two editors for the same record.
  bool _draftPushInFlight = false;

  @override
  void initState() {
    super.initState();
    _pageIndex = _indexFor(widget.initialRoute, _roleNow());
    _previousPageIndex = _pageIndex == ProviderTabHost.addTabIndex
        ? ProviderTabHost.homeIndex
        : _pageIndex;
  }

  /// The signed-in role. The verified session is authoritative; the app
  /// notifier (kept in step at every entry point) covers a session that has
  /// not published its profile yet.
  AppRole _roleOf(WidgetRef ref) =>
      ref.watch(authNotifierProvider.select((s) => s.user?.role)) ??
      ref.watch(appNotifierProvider.select((s) => s.role));

  /// The same role for callbacks and `initState`, where `watch` is not legal.
  AppRole _roleNow() =>
      ref.read(authNotifierProvider.select((s) => s.user?.role)) ??
      ref.read(appNotifierProvider.select((s) => s.role));

  /// Stack index for [route] as [role]. The Tasks page is the agent's
  /// assignment view, so a non-agent deep link resolves to Home rather than
  /// rendering an agent screen over data that is not theirs.
  int _indexFor(String route, AppRole role) {
    final index = ProviderTabHost.indexForRoute(route);
    if (index == ProviderTabHost.tasksIndex && role != AppRole.agent) {
      return ProviderTabHost.homeIndex;
    }
    if (index == ProviderTabHost.addTabIndex && role != AppRole.owner) {
      return ProviderTabHost.homeIndex;
    }
    if (index == ProviderTabHost.requestsIndex && role != AppRole.owner) {
      return ProviderTabHost.homeIndex;
    }
    return index;
  }

  /// [rememberPrevious] is false only for Back handling: Back must move to the
  /// previous tab without turning the destination into the new "previous".
  void _selectTab(String route, {bool rememberPrevious = true}) {
    final next = _indexFor(route, _roleNow());
    if (next == _pageIndex) return;
    setState(() {
      if (rememberPrevious && _pageIndex != ProviderTabHost.addTabIndex) {
        _previousPageIndex = _pageIndex;
      }
      _pageIndex = next;
    });
  }

  /// Single entry point for dock taps and in-page shortcuts. Tab routes are
  /// handled by the existing `IndexedStack`; everything else stays a normal
  /// drill-in route.
  void _go(String route, {Object? arguments}) {
    if (!ProviderTabHost.tabRoutes.contains(route)) {
      Navigator.of(
        context,
      ).pushNamed(route, arguments: arguments).then(_handleRouteResult);
      return;
    }
    // Resuming a specific draft is deliberately a drill-in: the persistent
    // Add page keeps its own unfinished blank form untouched.
    if (route == ProviderTabHost.addRoute &&
        arguments is String &&
        arguments.isNotEmpty) {
      _openDraft(arguments);
      return;
    }
    // An agent has no Add destination. The create form is still a registered
    // route other features reach, so it stays a pushed page with its own
    // chrome instead of a stack page whose dock the agent never has.
    if (route == ProviderTabHost.addRoute && _roleNow() == AppRole.agent) {
      Navigator.of(context).pushNamed(route).then(_handleRouteResult);
      return;
    }
    _selectTab(route);
  }

  void _openDraft(String draftId) {
    if (_draftPushInFlight) return;
    _draftPushInFlight = true;
    Navigator.of(
      context,
    ).pushNamed(ProviderTabHost.addRoute, arguments: draftId).then((result) {
      _draftPushInFlight = false;
      _handleRouteResult(result);
    });
  }

  void _handleRouteResult(Object? result) {
    if (!mounted) return;
    if (result == addPropertyDoneResult) {
      _selectTab('/provider/listings');
      return;
    }
    final tabRoute = providerTabFromResult(result);
    if (tabRoute != null && ProviderTabHost.tabRoutes.contains(tabRoute)) {
      _selectTab(tabRoute);
    }
  }

  void _handleBack() {
    if (_pageIndex == ProviderTabHost.addTabIndex) {
      _selectTab(
        ProviderTabHost.tabRoutes[_previousPageIndex],
        rememberPrevious: false,
      );
      return;
    }
    // Non-Add tabs keep the existing workspace rule: Back returns to Home,
    // and only Home lets the system leave the app.
    if (_pageIndex != 0) _selectTab('/provider', rememberPrevious: false);
  }

  @override
  Widget build(BuildContext context) {
    final role = _roleOf(ref);
    final highlight = ProviderTabHost.highlightForStack[_pageIndex];
    // The shared Add Property page brings its own MobileAppShell chrome. Hide
    // the host chrome while it is selected so there is exactly one top bar and
    // one dock on screen, matching the form's previous pushed-route appearance.
    final addPageSelected = _pageIndex == ProviderTabHost.addTabIndex;
    return ProviderTabScope(
      handles: (route) => ProviderTabHost.tabRoutes.contains(route),
      go: _go,
      child: PopScope<Object?>(
        canPop: _pageIndex == 0,
        onPopInvokedWithResult: (didPop, result) {
          if (!didPop) _handleBack();
        },
        child: Scaffold(
          backgroundColor: SitewiseM3.paper,
          appBar: addPageSelected
              ? null
              : MobileTopBar(
                  title: 'Provider workspace',
                  actions: const [],
                  m3: true,
                  // Root workspace: the dock destinations are top-level, so
                  // the header must never pop the whole workspace.
                  showBack: false,
                  roleBadge: role == AppRole.agent ? 'Agent' : 'Property Owner',
                ),
          body: IndexedStack(
            index: _pageIndex,
            children: [
              for (var i = 0; i < ProviderTabHost.tabRoutes.length; i++)
                _LazyTabPage(
                  active: i == _pageIndex,
                  builder: () => _pageFor(i),
                ),
            ],
          ),
          bottomNavigationBar: addPageSelected
              ? null
              : MobileBottomNav(
                  destinations: ProviderTabHost.destinationsFor(role),
                  currentRoute: highlight,
                  onGo: _selectTab,
                  m3: true,
                ),
        ),
      ),
    );
  }

  Widget _pageFor(int index) {
    final key = ValueKey('provider-${ProviderTabHost.tabRoutes[index]}');
    return switch (index) {
      ProviderTabHost.homeIndex => ProviderDashboardMobilePage(key: key),
      ProviderTabHost.listingsIndex => ProviderListingsMobilePage(key: key),
      ProviderTabHost.tasksIndex => ProviderTasksMobilePage(key: key),
      ProviderTabHost.performanceIndex => ProviderPerformanceMobilePage(
        key: key,
      ),
      ProviderTabHost.profileIndex => ProviderProfileMobilePage(key: key),
      ProviderTabHost.addTabIndex => SitewiseAddPropertyMobilePage(key: key),
      ProviderTabHost.requestsIndex => ProviderOwnerRequestsMobilePage(key: key),
      _ => const SizedBox.shrink(),
    };
  }
}

/// Builds a tab page the first time it is selected, then keeps that page alive
/// for the lifetime of the shell.
///
/// `IndexedStack` keeps children mounted, but it also builds every child on
/// the first frame. Profile used to fire three network requests while Home was
/// still loading; the Add form allocated its whole wizard offstage. Lazy
/// construction removes that startup contention without a second navigation
/// framework and without disposing state on tab changes.
class _LazyTabPage extends StatefulWidget {
  const _LazyTabPage({required this.active, required this.builder});

  final bool active;
  final Widget Function() builder;

  @override
  State<_LazyTabPage> createState() => _LazyTabPageState();
}

class _LazyTabPageState extends State<_LazyTabPage> {
  Widget? _child;

  @override
  void initState() {
    super.initState();
    if (widget.active) _child = widget.builder();
  }

  @override
  void didUpdateWidget(covariant _LazyTabPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && _child == null) {
      setState(() => _child = widget.builder());
    }
  }

  @override
  Widget build(BuildContext context) => _child ?? const SizedBox.shrink();
}
