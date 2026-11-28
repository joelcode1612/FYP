import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import 'package:sitewise_jaspr_web/shared/presentation/components/ui.dart';
import 'package:sitewise_jaspr_web/core/config/site_content.dart';

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
    return div([const Masthead(), child, const _SiteFooter()]);
  }
}

/// The public site header: brand mark + section links + Log In / Get Started.
///
/// Extracted from the marketing layout so standalone pages (e.g. sign-up) can
/// reuse the real navbar instead of a bespoke top bar.
///
/// Section links are canonical landing-page paths. They navigate to the single
/// continuous landing page, which then scrolls the matching section without a
/// URL fragment; the same links work from any marketing surface.
class Masthead extends StatelessComponent {
  const Masthead({super.key});

  @override
  Component build(BuildContext context) {
    return header(classes: 'masthead', [
      div(classes: 'masthead__inner', [
        const Brand(),
        nav(classes: 'masthead__nav', [
          for (final link in LandingContent.navLinks)
            AppLink(
              to: link.$2,
              classes: 'masthead__link',
              children: [Component.text(link.$1)],
            ),
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
                AppLink(to: link.$2, children: [Component.text(link.$1)]),
            ]),
          ]),
          div(classes: 'stack', [
            span(classes: 'overline', [Component.text('Get started')]),
            div(classes: 'footer-links', [
              AppLink(
                to: '/entrepreneur',
                children: [Component.text('F&B Entrepreneur')],
              ),
              AppLink(
                to: '/owner',
                children: [Component.text('Property Owner')],
              ),
              AppLink(
                to: '/admin',
                children: [Component.text('Administrator')],
              ),
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
