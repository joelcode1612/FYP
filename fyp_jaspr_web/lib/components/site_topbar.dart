import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import 'ui.dart';

/// The site's primary navigation bar: brand mark + wordmark, section links,
/// and the Sign in / Sign up actions, plus the small-screen menu.
///
/// Extracted from the landing page so standalone pages (sign-up) can reuse the
/// real navbar rather than a bespoke top bar. The styling is the landing
/// page's global `.topbar` / `.nav` block, which requires the `--lnd-*`
/// variables — callers outside the landing tree wrap it in `div.lnd`.
///
/// [linkPrefix] is prepended to the section anchors: the landing page keeps the
/// default (empty) so links scroll in place, while other pages pass `'/'` so
/// the links navigate back to the landing sections instead of dead-ending.
class SiteTopbar extends StatefulComponent {
  final String linkPrefix;

  const SiteTopbar({super.key, this.linkPrefix = ''});

  @override
  State<SiteTopbar> createState() => _SiteTopbarState();
}

class _SiteTopbarState extends State<SiteTopbar> {
  bool _navOpen = false;

  /// Label + anchor pairs, in the landing page's order.
  static const _links = <(String, String)>[
    ('Problem & solution', 'problem'),
    ('Explore', 'explore'),
    ('Assessment', 'assessment'),
    ('Recommendations', 'recommendations'),
  ];

  Component _link(String label, String anchor) => a(
    classes: 'navlinks-a',
    href: '${component.linkPrefix}#$anchor',
    [Component.text(label)],
  );

  @override
  Component build(BuildContext context) {
    return header(classes: 'topbar', [
      div(classes: 'wrap', [
        nav(
          classes: 'nav',
          attributes: const {'aria-label': 'Main navigation'},
          [
            a(classes: 'brand', href: '${component.linkPrefix}#top', [
              span(classes: 'brand-icon', [
                Component.element(
                  tag: 'img',
                  classes: 'brand-icon-img',
                  attributes: const {
                    'src': 'assets/sitewise-mark-64.png',
                    'alt': 'Sitewise',
                    'width': '26',
                    'height': '26',
                  },
                  children: [],
                ),
              ]),
              span([
                Component.text('SITEWISE'),
                br(),
                small([Component.text('F&B LOCATION INTELLIGENCE')]),
              ]),
            ]),
            div(classes: 'navlinks', [
              for (final link in _links) _link(link.$1, link.$2),
            ]),
            div(classes: 'nav-actions', [
              AppLink(
                to: '/login',
                classes: 'nav-btn signin',
                children: [Component.text('Sign in')],
              ),
              AppLink(
                to: '/signup',
                classes: 'nav-btn signup',
                children: [Component.text('Sign up ↗')],
              ),
            ]),
            button(
              classes: 'menu-btn',
              attributes: {
                'aria-label': 'Toggle navigation',
                'aria-expanded': _navOpen ? 'true' : 'false',
              },
              events: events(
                onClick: () => setState(() => _navOpen = !_navOpen),
              ),
              [Component.text('☰')],
            ),
          ],
        ),
        div(classes: 'mobile-nav${_navOpen ? ' open' : ''}', [
          for (final link in _links) _link(link.$1, link.$2),
          AppLink(
            to: '/signup',
            classes: 'mobile-signup',
            children: [Component.text('Sign up ↗')],
          ),
        ]),
      ]),
    ]);
  }
}
