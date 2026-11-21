import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import '../components/ui.dart';

/// The retired Property Owner web workspace.
///
/// Property Owners never had a workspace of their own in the final model — they
/// share the Provider workspace with agents, inside the SiteWise mobile app.
/// The former `/owner/*` pages were a second, divergent management UI, and,
/// worse, an owner-scoped route was reachable by any signed-in entrepreneur
/// through the legacy redirect. Every former `/owner/*` path resolves here
/// instead: no listing record, draft, tour or enquiry can be reached through the
/// browser, and the page reads no query parameter at all.
class OwnerRetiredPage extends StatelessComponent {
  const OwnerRetiredPage({super.key});

  @override
  Component build(BuildContext context) => main_(
    classes: 'shell shell--centered',
    [
      EmptyState(
        title: 'Your workspace is in the SiteWise app',
        body:
            'Property Owners and Agents share one workspace in the SiteWise '
            'mobile application — listings, photographs, 360° capture, '
            'enquiries, performance and verification all live there under the '
            'same account.',
        action: div(classes: 'empty__links', [
          const ActionLink('Go to SiteWise', href: '/'),
          const ActionLink(
            'Sign in',
            href: '/login',
            variant: 'ghost',
          ),
        ]),
      ),
    ],
  );
}
