import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import 'ui.dart';

/// Unified branded shell for all post-password staff MFA screens.
/// Deliberately does not use SiteTopbar/AuthNavbar: no Sign in or Sign up.
class StaffSecurityShell extends StatelessComponent {
  final Component card;
  const StaffSecurityShell({super.key, required this.card});

  Component _benefit(String icon, String heading, String body) =>
      div(classes: 'smfa-benefit', [
        div(classes: 'smfa-benefit-icon', [Icon(icon)]),
        div([
          h3([Component.text(heading)]),
          p([Component.text(body)]),
        ]),
      ]);

  @override
  Component build(BuildContext context) => main_(
    classes: 'smfa-page',
    attributes: const {'aria-label': 'SiteWise staff identity verification'},
    [
      header(classes: 'smfa-header', [
        div(classes: 'smfa-header-inner', [
          a(href: '/', classes: 'smfa-brand', [
            img(src: '/assets/sitewise-mark-64.png',
                alt: 'SiteWise', width: 35, height: 35),
            span([
              strong([Component.text('SITEWISE')]),
              small([Component.text('F&B LOCATION INTELLIGENCE')]),
            ]),
          ]),
          nav(classes: 'smfa-nav', attributes: const {'aria-label': 'SiteWise public sections'}, [
            a(href: '/#how', [Component.text('Problem & solution')]),
            a(href: '/#geo', [Component.text('Explore')]),
            a(href: '/#assessment', [Component.text('Assessment')]),
            a(href: '/#recs', [Component.text('Recommendations')]),
          ]),
          div(classes: 'smfa-session-chip', [
            const Icon('verified_user', size: 'sm'),
            span([Component.text('SECURE STAFF VERIFICATION')]),
          ]),
        ]),
      ]),
      div(classes: 'smfa-bg', attributes: const {'aria-hidden': 'true'}, []),
      div(classes: 'smfa-scrim', attributes: const {'aria-hidden': 'true'}, []),
      div(classes: 'smfa-grid', [
        section(classes: 'smfa-hero', [
          p(classes: 'smfa-eyebrow', [Component.text('SECURE ACCESS')]),
          h1([
            Component.text('Secure access for'),
            br(),
            span([Component.text('Agent and')]),
            br(),
            span([Component.text('Administrator.')]),
          ]),
          p(classes: 'smfa-lead', [
            Component.text('Two-factor authentication helps keep SiteWise and your account secure.'),
          ]),
          div(classes: 'smfa-benefits', [
            _benefit('shield', 'Stronger security', 'Verify it is really you.'),
            _benefit('smartphone', 'Authenticator app', 'Use Google Authenticator, Microsoft Authenticator, or a similar app.'),
            _benefit('lock', 'Protected access', 'Access staff tools and data safely.'),
          ]),
        ]),
        section(classes: 'smfa-panel', [card]),
      ]),
    ],
  );
}
