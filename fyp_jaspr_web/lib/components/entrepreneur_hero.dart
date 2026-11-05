import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import 'ui.dart';

/// Left-hand value-proposition column for the entrepreneur sign-in — the
/// marketing copy that sits over the photographic backdrop. Extracted from the
/// original [LoginPage] so the page can swap in a different hero for the staff
/// portal without touching the credential card.
class EntrepreneurHero extends StatelessComponent {
  const EntrepreneurHero({super.key});

  Component _feature(Component icon, String title, String body) => div(
    classes: 'lp-feature',
    [
      div(classes: 'lp-feat-icon', [icon]),
      div([
        h3([Component.text(title)]),
        p([Component.text(body)]),
      ]),
    ],
  );

  @override
  Component build(BuildContext context) => div(classes: 'lp-left', [
    p(classes: 'lp-eyebrow', [
      Component.text('Commercial F&B Location Intelligence'),
    ]),
    h1(classes: 'lp-hero', [
      Component.text('Welcome back to'),
      br(),
      span(classes: 'lp-accent', [Component.text('SiteWise.')]),
    ]),
    p(classes: 'lp-desc', [
      Component.text(
        'Sign in to continue exploring commercial F&B properties, '
        'save your favourite listings and get personalised location '
        'recommendations.',
      ),
    ]),
    div(classes: 'lp-features', [
      _feature(
        const Icon('map', filled: false),
        'Find Better Locations',
        'Explore high-potential areas for your F&B business.',
      ),
      _feature(
        const Icon('bookmark', filled: false),
        'Manage Your Shortlists',
        'Keep track of saved commercial properties.',
      ),
      _feature(
        const Icon('monitoring', filled: false),
        'Data-Driven Decisions',
        'Use location insights to compare opportunities.',
      ),
    ]),
  ]);
}
