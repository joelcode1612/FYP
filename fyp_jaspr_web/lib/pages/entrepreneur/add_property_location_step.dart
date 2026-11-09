import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import 'add_property_draft.dart';
import 'add_property_fields.dart';

/// Step 2 — Location. The map is illustrative; no geocoding is performed.
class AddPropertyLocationStep extends StatelessComponent {
  const AddPropertyLocationStep({
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
        id: 'sw-address',
        labelText: 'Street address',
        value: draft.address,
        onChanged: (v) => onChange((d) => d.address = v),
        full: true,
        requiredField: true,
        placeholder: 'Street, building and unit number',
      ),
      AddPropertyTextField(
        id: 'sw-state',
        labelText: 'State',
        value: draft.state,
        onChanged: (v) => onChange((d) => d.state = v),
        requiredField: true,
        placeholder: 'e.g. Selangor',
      ),
      AddPropertyTextField(
        id: 'sw-district',
        labelText: 'District',
        value: draft.district,
        onChanged: (v) => onChange((d) => d.district = v),
        requiredField: true,
        placeholder: 'e.g. Petaling',
      ),
      AddPropertyTextField(
        id: 'sw-postcode',
        labelText: 'Postcode',
        value: draft.postcode,
        onChanged: (v) => onChange((d) => d.postcode = v),
        placeholder: 'e.g. 47500',
      ),
      div([]),
      AddPropertyTextField(
        id: 'sw-lat',
        labelText: 'Latitude (optional)',
        value: draft.latitude,
        onChanged: (v) => onChange((d) => d.latitude = v),
        numeric: true,
        placeholder: 'e.g. 3.0750',
      ),
      AddPropertyTextField(
        id: 'sw-long',
        labelText: 'Longitude (optional)',
        value: draft.longitude,
        onChanged: (v) => onChange((d) => d.longitude = v),
        numeric: true,
        placeholder: 'e.g. 101.5900',
      ),
    ]),
    div(
      classes: 'swap-map',
      attributes: {
        'role': 'img',
        'aria-label':
            'Illustrative map pattern. Live geocoding uses your existing map integration.',
      },
      [
        div(classes: 'swap-map-caption', [
          Component.text(
            'Map illustration only — connect the existing geocoding/map component here.',
          ),
        ]),
      ],
    ),
  ]);
}
