import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';
import 'package:flutter/material.dart';

import '../../../core/theme/sitewise_m3.dart';
import 'entrepreneur_tab_scope.dart';
import 'mobile_bottom_nav.dart';
import 'mobile_navigation.dart';
import 'mobile_topbar.dart';

/// Mobile application shell: top bar + content + bottom navigation.
/// Renders Mobile pages only — web uses [WebAppShell].
/// Pages own their scrolling/padding so full-bleed layouts (maps, viewers)
/// are possible.
///
/// The **entrepreneur** and the shared **Owner / Agent provider** workspaces
/// opt into the Material 3 reference chrome (paper canvas, brand-lockup
/// header, floating pill-indicator dock). Admin keeps the original classic
/// shell. Detail routes inherit the same chrome as their workspace and keep
/// their back affordance via [MobileTopBar].
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
  /// automatically for the entrepreneur and provider roles.
  final bool? m3;

  /// Explicit dock destinations. When null, they are resolved from the role.
  /// A page that belongs to a specific workspace (e.g. the Provider Add form)
  /// passes its own list so a stale role in the app notifier can never show
  /// the other workspace's tabs.
  final List<MobileDestination>? destinations;

  /// Force the header's back affordance on or off. When null (default) the
  /// arrow follows [Navigator.canPop]. Screens that are reached from the
  /// persistent tab dock (and therefore must not pop the workspace away)
  /// pass `false`.
  final bool? showBack;

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
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Top-level tabs share one persistent Scaffold in EntrepreneurTabHost.
    // Only their content is rendered here; detail pages still get a full
    // MobileAppShell (and keep their existing back affordance).
    final tabScope = EntrepreneurTabScope.maybeOf(context);
    if (tabScope != null && EntrepreneurTabScope.isTabRoute(currentRoute)) {
      return body;
    }

    // Only the role is observed: the shell must not repaint when a property is
    // saved or compared.
    final role = ref.watch(appNotifierProvider.select((s) => s.role));
    final navDestinations = destinations ?? mobileDestinationsFor(role);
    // Owner and Agent share the Provider mobile workspace now, so their
    // drill-in pages use the same Material 3 chrome and dock as the
    // entrepreneur workspace. Admin keeps the classic shell.
    final useM3 = m3 ??
        (role == AppRole.entrepreneur ||
            role == AppRole.owner ||
            role == AppRole.agent);

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
              showBack: showBack,
            )
          : null,
      body: !showTopBar ? SafeArea(bottom: false, child: body) : body,
      floatingActionButton: floatingActionButton,
      bottomNavigationBar: MobileBottomNav(
        destinations: navDestinations,
        currentRoute: currentRoute,
        onGo: go,
        m3: useM3,
      ),
    );
  }
}
