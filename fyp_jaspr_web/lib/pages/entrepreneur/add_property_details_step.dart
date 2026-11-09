import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import 'add_property_draft.dart';
import 'add_property_fields.dart';

/// Step 1 — Property Details. Only mutates draft through parent's callback.
class AddPropertyDetailsStep extends StatelessComponent {
  const AddPropertyDetailsStep({
    super.key,
    required this.draft,
    required this.onChange,
  });

  final AddPropertyDraft draft;
  final void Function(void Function(AddPropertyDraft)) onChange;

  @override
  Component build(BuildContext context) => div([
    div(classes: 'swap-form-grid', [
      AddPropertyTextField(
        id: 'sw-name',
        labelText: 'Property name',
        value: draft.propertyName,
        onChanged: (v) => onChange((d) => d.propertyName = v),
        full: true,
        requiredField: true,
        placeholder: 'e.g. SS15 Corner Retail',
      ),
      AddPropertyTextField(
        id: 'sw-rent',
        labelText: 'Monthly rental (MYR)',
        value: draft.monthlyRent,
        onChanged: (v) => onChange((d) => d.monthlyRent = v),
        requiredField: true,
        numeric: true,
        placeholder: 'e.g. 7800',
      ),
      AddPropertyTextField(
        id: 'sw-area',
        labelText: 'Built-up area (sq ft)',
        value: draft.builtUpArea,
        onChanged: (v) => onChange((d) => d.builtUpArea = v),
        requiredField: true,
        numeric: true,
        placeholder: 'e.g. 1680',
      ),
    ]),
    div(classes: 'swap-divider', []),
    div(classes: 'swap-field', [
      span(classes: 'swap-field-legend', [Component.text('Property type *')]),
      div(classes: 'swap-choice-grid', [
        for (final type in const [
          'Shoplot',
          'Retail space',
          'Office',
          'Industrial',
          'Other',
        ])
          button(
            classes: 'swap-choice',
            attributes: {
              'type': 'button',
              'aria-pressed': '${draft.propertyType == type}',
            },
            events: events(
              onClick: () => onChange((d) => d.propertyType = type),
            ),
            [Component.text(type)],
          ),
      ]),
      div(classes: 'swap-hint', [
        Component.text(
          'Select the category used in your existing property listings.',
        ),
      ]),
    ]),
    addPropertyNotice(
      'Rental and floor area are validated in the UI preview only. '
      'The backend must validate them again.',
    ),
  ]);
}
