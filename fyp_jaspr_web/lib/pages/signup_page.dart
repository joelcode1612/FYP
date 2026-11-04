import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import '../components/auth_navbar.dart';
import '../components/ui.dart';

/// Account-creation surface.
///
/// Keeps the shared [SignupPage] shell (`lp-*`): the [AuthNavbar] floated over
/// the full-bleed photographic backdrop and the value-proposition column on
/// the left. The credential card on the right is now the standalone
/// `auth-portal.html` design (dual portal switcher, Sign In / Create Account
/// tabs, entrepreneur and staff forms), embedded in a same-origin iframe.
///
/// Why an iframe: that design brings its own compiled Tailwind utility CSS,
/// including Tailwind's global preflight reset. Injecting it into the main
/// document would reset the entire Jaspr site's typography and layout. The
/// iframe isolates it while remaining same-origin, so the portal's forms can
/// call `window.parent.sitewiseAuth` (the real Supabase PKCE bridge from
/// `auth_bundle.js`) for sign-up, sign-in and Google OAuth.
///
/// `web/auth-portal-host.js` resizes the frame from the portal's measured
/// height, so switching between the four forms never clips content.
class SignupPage extends StatelessComponent {
  const SignupPage({super.key});

  Component _feature(Component icon, String title, String body) =>
      div(classes: 'lp-feature', [
        div(classes: 'lp-feat-icon', [icon]),
        div([
          h3([Component.text(title)]),
          p([Component.text(body)]),
        ]),
      ]);

  Component _hero() => div(classes: 'lp-left', [
    p(classes: 'lp-eyebrow', [
      Component.text('Commercial Property & Location Intelligence'),
    ]),
    h1(classes: 'lp-hero', [
      Component.text('Discover the right property.'),
      br(),
      span(classes: 'lp-accent', [
        Component.text('Assess its business potential.'),
      ]),
    ]),
    p(classes: 'lp-desc', [
      Component.text(
        'Find suitable commercial properties and evaluate locations through '
        'geospatial analysis, surrounding F&B demand, accessibility and '
        'AI-powered suitability insights.',
      ),
    ]),
    div(classes: 'lp-features', [
      _feature(
        const Icon('search', filled: false),
        'Discover commercial properties',
        'Search and filter properties based on location, property '
            'characteristics, rental details and business requirements.',
      ),
      _feature(
        const Icon('map', filled: false),
        'Evaluate location potential',
        'Analyse surrounding population, F&B competitors, accessibility, '
            'amenities and local market conditions.',
      ),
      _feature(
        const Icon('monitoring', filled: false),
        'Understand AI recommendations',
        'Compare property suitability scores, explore assessment results and '
            'understand the factors behind each recommendation.',
      ),
    ]),
  ]);

  /// The supplied standalone portal, rewired to the real auth bridge.
  Component _panel() => div(classes: 'lp-right su-portal-right', [
    iframe(
      [],
      src: 'auth-portal.html',
      id: 'suPortalFrame',
      classes: 'su-portal-frame',
      attributes: const {
        'title': 'Sitewise account portal',
        'loading': 'eager',
        'scrolling': 'no',
        'allow': 'publickey-credentials-get *',
      },
    ),
  ]);

  @override
  Component build(BuildContext context) {
    return main_(
      classes: 'login-page signup-page',
      attributes: const {'aria-label': 'Create a SiteWise account'},
      [
        div(classes: 'lp-bg', attributes: const {'aria-hidden': 'true'}, []),
        div(
          classes: 'lp-overlay',
          attributes: const {'aria-hidden': 'true'},
          [],
        ),
        const AuthNavbar(),
        div(classes: 'lp-content', [_hero(), _panel()]),
      ],
    );
  }
}
