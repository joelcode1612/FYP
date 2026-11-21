import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import 'add_property_draft.dart';
import 'add_property_fields.dart';

/// Step 4 — Review and edit previously entered sections.
class AddPropertyReviewStep extends StatelessComponent {
  const AddPropertyReviewStep({
    super.key,
    required this.draft,
    required this.onEditStep,
  });

  final AddPropertyDraft draft;
  final void Function(int) onEditStep;

  @override
  Component build(BuildContext context) => div([
    _section('Property details', 1, [
      addPropertyPair(
        'Property name',
        AddPropertyDraft.display(draft.propertyName),
      ),
      addPropertyPair('Property type', draft.propertyType),
      addPropertyPair(
        'Monthly rent',
        draft.monthlyRent.isEmpty ? '—' : 'RM ${draft.monthlyRent}',
      ),
      addPropertyPair(
        'Built-up area',
        draft.builtUpArea.isEmpty ? '—' : '${draft.builtUpArea} sq ft',
      ),
    ]),
    _section('Location & address', 2, [
      addPropertyPair('Address', AddPropertyDraft.display(draft.address)),
      addPropertyPair('State', AddPropertyDraft.display(draft.state)),
      addPropertyPair('District', AddPropertyDraft.display(draft.district)),
      addPropertyPair('Postcode', AddPropertyDraft.display(draft.postcode)),
      addPropertyPair(
        'Coordinates',
        draft.latitude.trim().isEmpty
            ? 'Not provided'
            : '${draft.latitude}, ${draft.longitude}',
      ),
    ]),
    _section('Photos', 3, [
      addPropertyPair(
        'Upload status',
        'Not connected in this presentation preview',
      ),
    ]),
    addPropertyNotice(
      'Preview confirmation does not send an API request or create a '
      'property. Wire your existing use case after review.',
    ),
  ]);

  Component _section(String heading, int step, List<Component> entries) =>
      div(classes: 'swap-review-section', [
        div(classes: 'swap-review-head', [
          h3([Component.text(heading)]),
          button(
            classes: 'swap-edit',
            attributes: {'type': 'button'},
            events: events(onClick: () => onEditStep(step)),
            [Component.text('Edit')],
          ),
        ]),
        div(classes: 'swap-review-grid', entries),
      ]);
}
