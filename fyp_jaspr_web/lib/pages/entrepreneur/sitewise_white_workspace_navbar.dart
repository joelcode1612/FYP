import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

/// Navbar can also be reused inside the existing entrepreneur shell.
/// Do NOT render it alongside the existing shared navbar: replace that single
/// shared header manually after reviewing the repository's layout component.
class SitewiseWhiteWorkspaceNavbar extends StatelessComponent {
  const SitewiseWhiteWorkspaceNavbar({
    super.key,
    this.activePath = '/entrepreneur',
  });

  final String activePath;

  @override
  Component build(BuildContext context) =>
      div(classes: 'swap swap-navbar-only', [_navbarInner()]);

  Component _navbarInner() => div(classes: 'swap-header-wrap', [
    div(classes: 'swap-nav-shell', [
      a(href: '/entrepreneur', classes: 'swap-brand', [
        span(classes: 'swap-brand-mark', [Component.text('◈')]),
        div([
          div(classes: 'swap-brand-title', [Component.text('Sitewise')]),
          div(classes: 'swap-brand-sub', [
            Component.text('ENTREPRENEUR WORKSPACE'),
          ]),
        ]),
      ]),
      nav(
        classes: 'swap-links',
        attributes: {'aria-label': 'Workspace'},
        [
          _navLink('Home', '/entrepreneur'),
          _navLink('Explore', '/entrepreneur/explore'),
          _navLink('Map', '/entrepreneur/map'),
          _navLink('Recommendations', '/entrepreneur/recommendations'),
          _navLink('Compare', '/entrepreneur/compare'),
          _navLink('Saved', '/entrepreneur/saved'),
          _navLink('Profile', '/entrepreneur/profile'),
        ],
      ),
      div(classes: 'swap-actions', [
        span(
          classes: 'swap-nav-icon',
          attributes: {'aria-hidden': 'true', 'title': 'Search'},
          [_navIconSvg(true)],
        ),
        span(
          classes: 'swap-nav-icon',
          attributes: {'aria-hidden': 'true', 'title': 'Notifications'},
          [_navIconSvg(false)],
        ),
        a(href: '/entrepreneur/profile', classes: 'swap-avatar', [
          span(classes: 'swap-avatar-circle', [Component.text('SW')]),
          span(classes: 'swap-avatar-caret', [Component.text('⌄')]),
        ]),
        Component.element(
          tag: 'details',
          classes: 'swap-mobile-menu',
          children: [
            Component.element(
              tag: 'summary',
              attributes: {'aria-label': 'Open workspace navigation'},
              children: [Component.text('☰')],
            ),
            nav(
              classes: 'swap-mobile-items',
              attributes: {'aria-label': 'Mobile workspace'},
              [
                _navLink('Home', '/entrepreneur'),
                _navLink('Explore', '/entrepreneur/explore'),
                _navLink('Map', '/entrepreneur/map'),
                _navLink('Recommendations', '/entrepreneur/recommendations'),
                _navLink('Compare', '/entrepreneur/compare'),
                _navLink('Saved', '/entrepreneur/saved'),
                _navLink('Profile', '/entrepreneur/profile'),
                _navLink('My Properties', '/entrepreneur/my-properties'),
              ],
            ),
          ],
        ),
      ]),
    ]),
  ]);

  Component _navIconSvg(bool search) => Component.element(
    tag: 'svg',
    attributes: {
      'viewBox': '0 0 24 24',
      'width': '18',
      'height': '18',
      'fill': 'none',
      'stroke': 'currentColor',
      'stroke-width': '1.8',
      'stroke-linecap': 'round',
      'stroke-linejoin': 'round',
      'aria-hidden': 'true',
    },
    children: search
        ? [
            Component.element(
              tag: 'circle',
              attributes: {'cx': '10.8', 'cy': '10.8', 'r': '6.5'},
              children: [],
            ),
            Component.element(
              tag: 'path',
              attributes: {'d': 'm16 16 4.5 4.5'},
              children: [],
            ),
          ]
        : [
            Component.element(
              tag: 'path',
              attributes: {
                'd': 'M18 8a6 6 0 0 0-12 0c0 7-3 7-3 9h18c0-2-3-2-3-9Z',
              },
              children: [],
            ),
            Component.element(
              tag: 'path',
              attributes: {'d': 'M10 21h4'},
              children: [],
            ),
          ],
  );

  Component _navLink(String title, String href) => a(
    href: href,
    classes: 'swap-link',
    attributes: href == activePath ? {'aria-current': 'page'} : {},
    [Component.text(title)],
  );
}
