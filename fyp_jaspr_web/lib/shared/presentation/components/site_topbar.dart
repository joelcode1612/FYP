import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import 'package:sitewise_jaspr_web/core/routing/landing_routes.dart';
import 'package:sitewise_jaspr_web/shared/presentation/components/ui.dart';

/// The site's primary navigation bar: brand mark + wordmark, section links,
/// and the Sign in / Sign up actions, plus the small-screen menu.
///
/// Extracted from the landing page so standalone pages (sign-up) can reuse the
/// real navbar rather than a bespoke top bar. The styling is the landing
/// page's global `.topbar` / `.nav` block, which requires the `--lnd-*`
/// variables — callers outside the landing tree wrap it in `div.lnd`.
///
/// Every section link is a canonical [LandingRoutes] path. The same links are
/// used by the desktop `.navlinks` and the small-screen `.mobile-nav`, and all
/// of them render the single continuous landing page; the active path decides
/// which section is scrolled into view after navigation.
class SiteTopbar extends StatefulComponent {
  const SiteTopbar({super.key});

  @override
  State<SiteTopbar> createState() => _SiteTopbarState();
}

class _SiteTopbarState extends State<SiteTopbar> {
  bool _navOpen = false;

  Component _link(String label, String path) => AppLink(
    to: path,
    classes: 'navlinks-a',
    children: [Component.text(label)],
  );

  @override
  Component build(BuildContext context) {
    return header(classes: 'topbar', [
      div(classes: 'wrap', [
        nav(
          classes: 'nav',
          attributes: const {'aria-label': 'Main navigation'},
          [
            AppLink(
              to: LandingRoutes.home,
              classes: 'brand',
              children: [
              span(classes: 'brand-icon', [
                Component.element(
                  tag: 'img',
                  classes: 'brand-icon-img',
                  attributes: const {
                    'src': '/assets/sitewise-mark-64.png',
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
              for (final section in LandingRoutes.sections)
                _link(section.$1, section.$2),
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
          for (final section in LandingRoutes.sections)
            _link(section.$1, section.$2),
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
