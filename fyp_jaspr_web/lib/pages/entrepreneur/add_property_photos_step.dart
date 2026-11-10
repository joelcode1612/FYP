import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import 'add_property_fields.dart';

/// Step 3 — Photo gallery presentation only (no file upload).
class AddPropertyPhotosStep extends StatelessComponent {
  const AddPropertyPhotosStep({super.key});

  @override
  Component build(BuildContext context) => div([
    div(classes: 'swap-upload', [
      div(classes: 'swap-upload-symbol', [Component.text('▣')]),
      h3([Component.text('Property photo gallery')]),
      p([
        Component.text(
          'Drag/drop and upload should use the existing SiteWise image-storage '
          'component. This visual preview does not read or upload local files.',
        ),
      ]),
      span(classes: 'swap-draft-pill', [Component.text('Optional step')]),
    ]),
    div(classes: 'swap-photo-row', [
      for (final title in const [
        'Exterior photo',
        'Interior photo',
        'Floor layout',
      ])
        div(classes: 'swap-photo', [
          span(classes: 'swap-photo-symbol', [Component.text('▧')]),
          span([Component.text(title)]),
        ]),
    ]),
    addPropertyNotice(
      'Supported file types, maximum size and image uploads must '
      'be enforced by the existing media backend.',
    ),
  ]);
}
