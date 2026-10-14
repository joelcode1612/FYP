import 'package:shared_logic/shared_logic.dart';
import 'package:flutter/material.dart';

import 'mobile_bottom_nav.dart';
import 'mobile_navigation.dart';
import 'mobile_topbar.dart';

/// Mobile application shell: top bar + content + bottom navigation.
/// Renders Mobile pages only — web uses [WebAppShell].
/// Pages own their scrolling/padding so full-bleed layouts (maps, viewers)
/// are possible.
///
/// Set [embeddedHeader] when the page supplies its own Home-style header (the
/// reference pattern's compact menu / brand / utility row that scrolls with the
/// content). The shell then drops the [AppBar] entirely and lets the body start
/// at the top of the safe area — no duplicate bar, no double padding.

class MobileAppShell extends StatelessWidget {
  final AppCubit appState;
  final String title;
  final String currentRoute;
  final Widget body;
  final List<Widget>? actions;
  final Widget? floatingActionButton;

  /// Show the Sitewise wordmark instead of the text title (Home).
  final bool brandTitle;

  /// When true, the page renders its own header inside [body]; the shell omits
  /// the [AppBar] and does not wrap the body in a top [SafeArea].
  final bool embeddedHeader;

  const MobileAppShell({
    super.key,
    required this.appState,
    required this.title,
    required this.currentRoute,
    required this.body,
    this.actions,
    this.floatingActionButton,
    this.brandTitle = false,
    this.embeddedHeader = false,
  });

  @override
  Widget build(BuildContext context) {
    final destinations = mobileDestinationsFor(appState.role);

    void go(String route) {
      if (route == currentRoute) return;
      Navigator.of(context).pushReplacementNamed(route);
    }

    return Scaffold(
      appBar: embeddedHeader
          ? null
          : MobileTopBar(
              title: title,
              actions: actions,
              appState: appState,
              brandTitle: brandTitle,
            ),
      body: embeddedHeader ? SafeArea(bottom: false, child: body) : body,
      floatingActionButton: floatingActionButton,
      bottomNavigationBar: MobileBottomNav(
        destinations: destinations,
        currentRoute: currentRoute,
        onGo: go,
      ),
    );
  }
}
