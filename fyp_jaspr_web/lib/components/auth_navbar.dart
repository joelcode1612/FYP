import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import 'site_topbar.dart';

/// The site navbar floated over an auth page's full-bleed hero.
///
/// It reuses [SiteTopbar] verbatim, wrapped in `.lnd` because that component's
/// styling lives in the landing-scoped block and reads the `--lnd-*` tokens.
/// The wrapper gives up `.lnd`'s paper background so the bar reads as the same
/// solid white block the landing page uses — the hero is a photograph, so a
/// transparent bar over it made the wordmark and links fight the sky.
///
/// `.lp-nav` is absolutely positioned, so [SiteTopbar] costs the page no
/// vertical band; `.lp-content` reserves `--lp-nav-h` of top padding instead.
class AuthNavbar extends StatelessComponent {
  const AuthNavbar({super.key});

  @override
  Component build(BuildContext context) {
    return div(classes: 'lp-nav lnd', [const SiteTopbar(linkPrefix: '/')]);
  }
}
