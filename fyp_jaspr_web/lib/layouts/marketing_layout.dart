import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import '../components/ui.dart';
import '../data/site_content.dart';

/// Public marketing chrome: sticky masthead + footer.
///
/// The Flutter tree renders these inside `LandingWebPage` as a `SliverAppBar`
/// and a footer widget. Splitting them into a layout means every public page
/// (landing, and any future marketing page) shares one header and footer
/// instead of each page rebuilding them.
class MarketingLayout extends StatelessComponent {
  final Component child;

  const MarketingLayout({super.key, required this.child});

  @override
  Component build(BuildContext context) {
    return div([const _Masthead(), child, const _SiteFooter()]);
  }
}

class _Masthead extends StatelessComponent {
  const _Masthead();

  @override
  Component build(BuildContext context) {
    return header(classes: 'masthead', [
      div(classes: 'masthead__inner', [
        const Brand(),
        nav(classes: 'masthead__nav', [
          for (final link in LandingContent.navLinks)
            // Plain `#anchor` links: the browser handles smooth scrolling via
            // `scroll-behavior` in CSS, so no JavaScript and no GlobalKeys.
            a(href: '#${link.$2}', classes: 'masthead__link', [
              Component.text(link.$1),
            ]),
        ]),
        div(classes: 'masthead__actions', [
          const ActionLink('Log In', href: '/login', variant: 'ghost'),
          const ActionLink('Get Started', href: '/entrepreneur'),
        ]),
      ]),
    ]);
  }
}

class _SiteFooter extends StatelessComponent {
  const _SiteFooter();

  @override
  Component build(BuildContext context) {
    return footer(classes: 'site-footer', [
      div(classes: 'container', [
        div(classes: 'footer-grid', [
          div(classes: 'stack', [
            const Brand(),
            p(classes: 'small', [
              Component.text(
                'Evidence-based location decisions for F&B commercial '
                'property. A prototype built for academic assessment.',
              ),
            ]),
          ]),
          div(classes: 'stack', [
            span(classes: 'overline', [Component.text('Explore')]),
            div(classes: 'footer-links', [
              for (final link in LandingContent.navLinks)
                a(href: '#${link.$2}', [Component.text(link.$1)]),
            ]),
          ]),
          div(classes: 'stack', [
            span(classes: 'overline', [Component.text('Get started')]),
            div(classes: 'footer-links', [
              a(href: '/entrepreneur', [Component.text('F&B Entrepreneur')]),
              a(href: '/owner', [Component.text('Property Owner')]),
              a(href: '/admin', [Component.text('Administrator')]),
            ]),
          ]),
        ]),
        hr(classes: 'divider'),
        p(classes: 'tiny', [
          Component.text('© 2026 Sitewise — prototype build'),
        ]),
      ]),
    ]);
  }
}
