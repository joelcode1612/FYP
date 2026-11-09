import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import '../components/topbar_controls.dart';
import '../components/ui.dart';
import '../data/navigation.dart';
import '../data/site_content.dart';

/// Authenticated app chrome.
///
/// ## Structure — modelled on the uploaded dashboard mockup
///
/// ```text
/// ┌───────────────────────────────────────────────────────────┐
/// │  ● Sitewise   [ Home  Explore  Compare … ]   ⌕  🔔  👤   │  ← sticky pill
/// ├───────────────────────────────────────────────────────────┤
/// │                                                           │
/// │   Page title + description                                │
/// │   page content …                                          │
/// └───────────────────────────────────────────────────────────┘
/// ```
///
/// The mockup has **no left navigation rail**. Its navigation is a single
/// sticky pill at the top holding brand, links and account controls, with the
/// page's own headline living in the content area beneath it. That is the
/// structure used here.
///
/// ### Consequences worth knowing
///
/// * **The page title moved out of the top bar.** [`AppLayout`] renders it as a
///   [PageHead] in the content area, so every page gets the same header rather
///   than pages that opt in. Pages should *not* render their own `PageHead`.
/// * **`actions` belong to the page header**, not the nav pill — pass them to
///   [AppLayout] and they land on the right of the `PageHead`.
/// * **The sidebar survives only as a drawer.** Above 900px there is no rail at
///   all; below it, `.topbar__burger` opens the same destination list
///   off-canvas. The destination array is still built once, so there is no
///   second list to keep in sync.
///
/// The rail was not removed carelessly: the app has up to ten destinations per
/// role, and the mockup only ever shows three links, so a single pill row is
/// the honest way to express that hierarchy on a wide screen while the drawer
/// carries the full set on a narrow one.
class AppLayout extends StatefulComponent {
  final AppRole role;
  final String currentRoute;
  final String title;
  final String? subtitle;

  /// Small uppercase label above the page title.
  final String? eyebrow;

  /// Page-level CTAs. Rendered on the right of the page header.
  final List<Component> actions;

  /// Set to false when the page renders its own header.
  ///
  /// The source's entrepreneur dashboard has no page header at all — its first
  /// element is `.bento-head` (eyebrow + greeting + actions). Rendering both
  /// produced two competing titles ("Home" above "Hello there"), which the
  /// source does not have.
  final bool showPageHead;

  final Component child;

  const AppLayout({
    super.key,
    required this.role,
    required this.currentRoute,
    required this.title,
    this.subtitle,
    this.eyebrow,
    this.actions = const [],
    this.showPageHead = true,
    required this.child,
  });

  @override
  State<AppLayout> createState() => _AppLayoutState();
}

class _AppLayoutState extends State<AppLayout> {
  bool _navOpen = false;

  void _closeNav() {
    if (_navOpen) setState(() => _navOpen = false);
  }

  @override
  Component build(BuildContext context) {
    final destinations = webDestinationsFor(component.role);
    // Detail routes highlight their parent section, so drilling into a record
    // does not leave the nav with nothing selected.
    final selected = parentShellRoute(component.currentRoute);

    // Role-scoped theming hooks. The Administrator workspace carries its own
    // navy/charcoal "Blue Accent" theme (SiteWise_Admin_Blue_DESIGN.md) and the
    // Agent workspace the light landing-page palette (DESIGN.md §4). The extra
    // classes let the stylesheet retheme each shell without touching the other
    // roles or the public styling, which keep reading the shared `.app-shell`
    // tokens.
    return div(
      classes: switch (component.role) {
        AppRole.admin => 'app-shell app-shell--admin',
        AppRole.agent => 'app-shell app-shell--agent',
        _ => 'app-shell',
      },
      [
        if (_navOpen)
          // Scrim. `aria-hidden` because it is a dismissal surface, not content —
          // the equivalent content already exists in the drawer underneath.
          div(
            classes: 'scrim',
            attributes: const {'aria-hidden': 'true'},
            events: events(onClick: _closeNav),
            [],
          ),

        // Mobile drawer. Hidden above 900px by CSS; the pill nav is the desktop
        // and wide-tablet navigation.
        _Sidebar(
          role: component.role,
          currentRoute: component.currentRoute,
          open: _navOpen,
        ),

        div(classes: 'app-main', [
          // --- The pill nav -------------------------------------------------
          header(classes: 'app-pill', [
            // Burger — hidden above 900px by CSS, so wide screens get the inline
            // links instead.
            button(
              classes: 'topbar__burger',
              attributes: {
                'type': 'button',
                'aria-label': _navOpen ? 'Close navigation' : 'Open navigation',
                'aria-expanded': _navOpen ? 'true' : 'false',
                'aria-controls': 'app-sidebar',
              },
              events: events(
                onClick: () => setState(() => _navOpen = !_navOpen),
              ),
              [Icon(_navOpen ? 'close' : 'menu')],
            ),

            Brand(subtitle: workspaceLabelFor(component.role)),

            nav(classes: 'app-pill__nav', [
              for (final d in destinations)
                AppLink(
                  to: d.route,
                  // `aria-current="page"` is the standard way to tell assistive
                  // technology which entry is the current one; without it the
                  // active item is communicated by colour alone.
                  attributes: d.route == selected
                      ? const {'aria-current': 'page'}
                      : null,
                  classes: d.route == selected
                      ? 'app-pill__link app-pill__link--active'
                      : 'app-pill__link',
                  // The source's pill row carries labels only. Icons were removed
                  // because the scrollable row flex-shrank them to zero width, and
                  // because `threesixty` is not a Material Symbols ligature — it
                  // rendered the literal word.
                  children: [Component.text(d.label)],
                ),
            ]),

            div(classes: 'app-pill__right', [
              TopbarControls(role: component.role),
            ]),
          ]),

          // --- Page ----------------------------------------------------------
          div(classes: 'app-content', [
            div(classes: 'app-content__inner', [
              if (component.showPageHead)
                PageHead(
                  title: component.title,
                  description: component.subtitle,
                  eyebrow: component.eyebrow,
                  actions: component.actions,
                ),
              component.child,
            ]),
          ]),
        ]),
      ],
    );
  }
}

class _Sidebar extends StatelessComponent {
  final AppRole role;
  final String currentRoute;
  final bool open;

  const _Sidebar({
    required this.role,
    required this.currentRoute,
    required this.open,
  });

  @override
  Component build(BuildContext context) {
    final destinations = webDestinationsFor(role);
    final selected = parentShellRoute(currentRoute);

    return aside(
      classes: open ? 'sidebar sidebar--open' : 'sidebar',
      attributes: const {'id': 'app-sidebar'},
      [
        div(classes: 'sidebar__head', [
          Brand(subtitle: workspaceLabelFor(role)),
        ]),
        div(classes: 'sidebar__role', [Component.text(role.label)]),
        nav(classes: 'sidebar__nav', [
          for (final d in destinations)
            AppLink(
              to: d.route,
              attributes: d.route == selected
                  ? const {'aria-current': 'page'}
                  : null,
              classes: d.route == selected
                  ? 'nav-item nav-item--active'
                  : 'nav-item',
              children: [
                Icon(d.icon),
                span(classes: 'grow', [Component.text(d.label)]),
              ],
            ),
        ]),
        div(classes: 'sidebar__foot', [Component.text('v1.0 · prototype')]),
      ],
    );
  }
}
