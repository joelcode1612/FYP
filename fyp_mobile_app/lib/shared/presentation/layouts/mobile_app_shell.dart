import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';

import 'package:fyp/core/theme/sitewise_m3.dart';
import 'package:fyp/shared/presentation/layouts/entrepreneur_tab_scope.dart';
import 'package:fyp/shared/presentation/layouts/mobile_bottom_nav.dart';
import 'package:fyp/core/routing/mobile_navigation.dart';
import 'package:fyp/shared/presentation/layouts/mobile_topbar.dart';

/// Shared mobile shell for top bar, body, and bottom navigation.
class MobileAppShell extends ConsumerWidget {
  final String title;
  final String currentRoute;
  final Widget body;
  final List<Widget>? actions;
  final Widget? floatingActionButton;

  final bool brandTitle;
  final bool embeddedHeader;
  final bool? m3;
  final List<MobileDestination>? destinations;
  final bool? showBack;

  /// Use a plain title-only header for pushed settings/detail pages.
  final bool simpleTopBar;

  /// Hide bottom navigation while the keyboard is open.
  /// Defaults to false so existing pages are unchanged.
  final bool hideBottomNavOnKeyboard;

  /// Optional command sink for pages that live inside a navigation scope
  /// (currently the provider Add Property page). When supplied, dock taps are
  /// delegated instead of replacing the current route.
  final ValueChanged<String>? onNavigate;

  const MobileAppShell({
    super.key,
    required this.title,
    required this.currentRoute,
    required this.body,
    this.actions,
    this.floatingActionButton,
    this.brandTitle = false,
    this.embeddedHeader = false,
    this.m3,
    this.destinations,
    this.showBack,
    this.simpleTopBar = false,
    this.hideBottomNavOnKeyboard = false,
    this.onNavigate,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tabScope = EntrepreneurTabScope.maybeOf(context);

    if (tabScope != null && EntrepreneurTabScope.isTabRoute(currentRoute)) {
      return body;
    }

    final role = ref.watch(appNotifierProvider.select((s) => s.role));

    final navDestinations = destinations ?? mobileDestinationsFor(role);

    final useM3 =
        m3 ??
        (role == AppRole.entrepreneur ||
            role == AppRole.owner ||
            role == AppRole.agent);

    void go(String route) {
      if (route == currentRoute) return;
      final navigate = onNavigate;
      if (navigate != null) {
        navigate(route);
        return;
      }
      Navigator.of(context).pushReplacementNamed(route);
    }

    final showTopBar = useM3 || !embeddedHeader;

    // Detect the software keyboard.
    final keyboardIsVisible =
        hideBottomNavOnKeyboard && MediaQuery.viewInsetsOf(context).bottom > 0;

    return Scaffold(
      backgroundColor: useM3 ? SitewiseM3.paper : null,

      // Allow the form to resize above the keyboard.
      resizeToAvoidBottomInset: true,

      appBar: showTopBar
          ? MobileTopBar(
              title: title,
              actions: actions,
              brandTitle: brandTitle,
              m3: useM3,
              showBack: showBack,
              plainTitle: simpleTopBar,
            )
          : null,

      body: !showTopBar ? SafeArea(bottom: false, child: body) : body,

      floatingActionButton: floatingActionButton,

      // Hide bottom navigation when the keyboard is open,
      // only on pages that explicitly enable this behavior.
      bottomNavigationBar: keyboardIsVisible
          ? null
          : MobileBottomNav(
              destinations: navDestinations,
              currentRoute: currentRoute,
              onGo: go,
              m3: useM3,
            ),
    );
  }
}
