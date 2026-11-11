import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

/// Reusable, controlled text field for the Add Property wizard.
class AddPropertyTextField extends StatelessComponent {
  const AddPropertyTextField({
    super.key,
    required this.id,
    required this.labelText,
    required this.value,
    required this.onChanged,
    this.placeholder = '',
    this.requiredField = false,
    this.full = false,
    this.numeric = false,
    this.hint,
  });

  final String id;
  final String labelText;
  final String value;
  final void Function(String) onChanged;
  final String placeholder;
  final bool requiredField;
  final bool full;
  final bool numeric;
  final String? hint;

  @override
  Component build(BuildContext context) => div(
    classes: 'swap-field${full ? ' is-full' : ''}',
    // Tighter label/input/hint rhythm; the parent form grid is styled in CSS.
    styles: Styles(raw: {'gap': '6px', 'margin': '0'}),
    [
      label(htmlFor: id, [
        Component.text(labelText),
        if (requiredField)
          span(classes: 'swap-required', [Component.text(' *')]),
      ]),
      input(
        type: numeric ? InputType.number : InputType.text,
        classes: 'swap-input',
        attributes: {
          'id': id,
          'name': id,
          'value': value,
          'placeholder': placeholder,
          if (numeric) 'min': '0',
          if (numeric) 'step': 'any',
          if (requiredField) 'required': '',
        },
        events: events<String>(onInput: onChanged),
      ),
      if (hint != null) div(classes: 'swap-hint', [Component.text(hint!)]),
    ],
  );
}

/// Shared note styling. No persistence or API behavior is implied.
Component addPropertyNotice(String message) => div(classes: 'swap-notice', [
  span(classes: 'swap-notice-icon', [Component.text('ⓘ')]),
  span([Component.text(message)]),
]);

Component addPropertyPair(String labelText, String value) => div([
  span(classes: 'swap-review-label', [Component.text(labelText)]),
  span(classes: 'swap-review-value', [Component.text(value)]),
]);
