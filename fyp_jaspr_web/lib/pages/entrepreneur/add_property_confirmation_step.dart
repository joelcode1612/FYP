import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import 'add_property_draft.dart';
import 'add_property_fields.dart';

/// Step 5 — Presentation confirmation. No record has been created.
class AddPropertyConfirmationStep extends StatelessComponent {
  const AddPropertyConfirmationStep({
    super.key,
    required this.draft,
    required this.onRestart,
  });

  final AddPropertyDraft draft;
  final void Function() onRestart;

  @override
  Component build(BuildContext context) => div(classes: 'swap-confirm', [
    span(classes: 'swap-demo-tag', [Component.text('UI preview — not saved')]),
    div(classes: 'swap-confirm-badge', [Component.text('✓')]),
    h2([Component.text('Submission confirmation design')]),
    p([
      Component.text(
        'This is how a successful response could look after your existing '
        'FastAPI Add Property use case returns a verified property ID.',
      ),
    ]),
    div(classes: 'swap-success-box', [
      addPropertyPair(
        'Sample property',
        AddPropertyDraft.display(draft.propertyName),
      ),
      div(classes: 'swap-divider', []),
      addPropertyPair(
        'Property ID',
        'Assigned by backend after successful creation',
      ),
    ]),
    button(
      classes: 'swap-btn swap-btn-primary',
      attributes: {'type': 'button'},
      events: events(onClick: onRestart),
      [Component.text('Review the design again')],
    ),
    a(href: '/entrepreneur/my-properties', classes: 'swap-btn', [
      Component.text('Go to My Properties'),
    ]),
  ]);
}
