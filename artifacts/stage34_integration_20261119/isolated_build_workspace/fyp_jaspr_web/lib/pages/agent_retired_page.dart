import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import '../components/ui.dart';

/// The retired Agent web workspace.
///
/// Property management moved to the Flutter Owner / Agent app. Every former
/// `/agent/*` path resolves here instead of the management pages, so an old
/// bookmark cannot reach a listing record, a draft or an assignment through
/// the browser. No private data is rendered: this page carries no query, no
/// listing id and no manager identity.
class AgentRetiredPage extends StatelessComponent {
  const AgentRetiredPage({super.key});

  @override
  Component build(BuildContext context) => main_(
    classes: 'shell shell--centered',
    [
      EmptyState(
        title: 'Property management has moved to mobile',
        body:
            'The SiteWise Owner / Agent workspace now runs in the SiteWise '
            'mobile application. Listing drafts, photographs, 360° capture, '
            'verification submissions and assigned-property management are '
            'all available there with the same account.',
        action: div(classes: 'empty__links', [
          const ActionLink('Go to SiteWise', href: '/'),
          const ActionLink(
            'Entrepreneur sign in',
            href: '/login',
            variant: 'ghost',
          ),
        ]),
      ),
    ],
  );
}
