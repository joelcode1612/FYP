import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import '../components/topbar_controls.dart';
import '../components/ui.dart';
import '../data/navigation.dart';
import '../data/site_content.dart';

/// Authenticated app chrome: sidebar + topbar + content.
///
/// Ported from `lib/presentation/web/shell/` in the Flutter tree, where this is
/// spread across `web_app_shell.dart`, `web_sidebar.dart` and `web_topbar.dart`.
///
/// Two structural changes from the Flutter version:
///
/// * **One component instead of three nested shells.** The Flutter code builds
///   `WebAppShell` -> `WebSidebar` + `WebTopBar` per page, and every page passes
///   `appState` down. Here the layout is composed once and pages supply only
///   their title, subtitle and body.
/// * **Navigation is anchors.** The Flutter sidebar calls
///   `Navigator.pushReplacementNamed`; here each entry is an `<a href>`, so the
///   sidebar works without JavaScript, supports middle-click, and is crawlable.
class AppLayout extends StatelessComponent {
  final AppRole role;
  final String currentRoute;
  final String title;
  final String? subtitle;

  /// Optional top-right actions (page-level CTAs).
  final List<Component> actions;

  final Component child;

  const AppLayout({
    super.key,
    required this.role,
    required this.currentRoute,
    required this.title,
    this.subtitle,
    this.actions = const [],
    required this.child,
  });

  @override
  Component build(BuildContext context) {
    return div(classes: 'app-shell', [
      _Sidebar(role: role, currentRoute: currentRoute),
      div(classes: 'app-main', [
        header(classes: 'topbar', [
          div(classes: 'topbar__titles grow', [
            div(classes: 'topbar__title', [Component.text(title)]),
            if (subtitle != null)
              div(classes: 'topbar__subtitle', [Component.text(subtitle!)]),
          ]),
          if (actions.isNotEmpty) div(classes: 'topbar__actions', actions),
          TopbarControls(role: role),
        ]),
        div(classes: 'app-content', [
          div(classes: 'app-content__inner', [child]),
        ]),
      ]),
    ]);
  }
}

class _Sidebar extends StatelessComponent {
  final AppRole role;
  final String currentRoute;

  const _Sidebar({required this.role, required this.currentRoute});

  @override
  Component build(BuildContext context) {
    final destinations = webDestinationsFor(role);
    // Detail routes highlight their parent section, so drilling into a record
    // does not leave the sidebar with nothing selected.
    final selected = parentShellRoute(currentRoute);

    return aside(classes: 'sidebar', [
      div(classes: 'sidebar__head', [const Brand()]),
      div(classes: 'sidebar__role', [Component.text(role.label)]),
      nav(classes: 'sidebar__nav', [
        for (final d in destinations)
          a(
            href: d.route,
            classes: d.route == selected
                ? 'nav-item nav-item--active'
                : 'nav-item',
            [
              Icon(d.icon),
              span(classes: 'grow', [Component.text(d.label)]),
            ],
          ),
      ]),
      div(classes: 'sidebar__foot', [Component.text('v1.0 · prototype')]),
    ]);
  }
}
