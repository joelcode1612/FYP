import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';
import 'package:flutter/material.dart';

import '../../../core/theme/sitewise_m3.dart';
import 'mobile_bottom_nav.dart';
import 'mobile_navigation.dart';
import 'mobile_topbar.dart';

/// Mobile application shell: top bar + content + bottom navigation.
/// Renders Mobile pages only — web uses [WebAppShell].
/// Pages own their scrolling/padding so full-bleed layouts (maps, viewers)
/// are possible.
///
/// The **entrepreneur** workspace opts into the Material 3 reference chrome
/// (paper canvas, brand-lockup header, five-tab pill-indicator bar). Admin and
/// owner keep their original shell, so this refresh cannot regress their
/// screens. Detail routes under `/entrepreneur/*` inherit the same chrome and
/// keep their back affordance via [MobileTopBar].
///
/// Set [embeddedHeader] when a page supplies its own Home-style header (the
/// older pattern's compact menu / brand / utility row that scrolls with the
/// content). Ignored for the Material 3 shell, which always renders its header.

class MobileAppShell extends ConsumerWidget {
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

  /// Force / override the Material 3 chrome. When null (default) it is enabled
  /// automatically for the entrepreneur role.
  final bool? m3;

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
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Only the role is observed: the shell must not repaint when a property is
    // saved or compared.
    final role = ref.watch(appNotifierProvider.select((s) => s.role));
    final destinations = mobileDestinationsFor(role);
    final useM3 = m3 ?? (role == AppRole.entrepreneur);

    void go(String route) {
      if (route == currentRoute) return;
      Navigator.of(context).pushReplacementNamed(route);
    }

    final showTopBar = useM3 || !embeddedHeader;

    return Scaffold(
      backgroundColor: useM3 ? SitewiseM3.paper : null,
      appBar: showTopBar
          ? MobileTopBar(
              title: title,
              actions: actions,
              brandTitle: brandTitle,
              m3: useM3,
            )
          : null,
      body: !showTopBar ? SafeArea(bottom: false, child: body) : body,
      floatingActionButton: floatingActionButton,
      bottomNavigationBar: MobileBottomNav(
        destinations: destinations,
        currentRoute: currentRoute,
        onGo: go,
        m3: useM3,
      ),
    );
  }
}
