import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import '../components/ui.dart';
import '../data/site_content.dart';
import '../layouts/marketing_layout.dart';

/// Standalone role picker at `/login`.
///
/// The Flutter web tree implements this as a dialog over the landing page
/// (`_enter(role, route)` = set role, navigate to the role's home route). Here
/// the role is derived from the destination URL itself (see `roleForPath`), so
/// "logging in" is simply navigating — and every card is a plain link that
/// works without JavaScript.
class LoginPage extends StatelessComponent {
  const LoginPage({super.key});

  @override
  Component build(BuildContext context) {
    return MarketingLayout(
      child: section(classes: 'section', [
        div(classes: 'container', [
          div(classes: 'stack', [
            const Eyebrow('Demo access'),
            h1(classes: 'title-xl', [Component.text('Choose a workspace')]),
            p(classes: 'lead', [
              Component.text(
                'This prototype has no password auth. Pick the role you want '
                'to explore — each workspace opens with its own demo data.',
              ),
            ]),
          ]),
          div(classes: 'grid-2', [
            for (final role in LandingContent.roles)
              div(classes: 'card stack', [
                span(classes: 'icon-tile', [Icon(role.icon, size: 'lg')]),
                h3(classes: 'title-lg', [Component.text(role.title)]),
                p(classes: 'body', [Component.text(role.body)]),
                ActionLink(
                  role.linkLabel,
                  href: role.route,
                  variant: 'secondary',
                ),
              ]),
          ]),
          div(classes: 'small muted', [
            a(href: '/', classes: 'text-action', [
              Component.text('← Back to the landing page'),
            ]),
          ]),
        ]),
      ]),
    );
  }
}
