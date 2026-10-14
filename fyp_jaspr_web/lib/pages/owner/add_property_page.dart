import 'dart:async';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/ui.dart';
import '../../data/app_locator.dart';
import '../../layouts/app_layout.dart';

/// Web add/edit property: multi-column desktop form.
///
/// Ported from `owner_add_property_web_page.dart` in the Flutter web tree.
/// The Flutter page keeps `TextEditingController`s and validates on save;
/// this version holds field values in local state and renders the same
/// required-field validation ('Required') inline under each input. The
/// Flutter `_save` only validated and popped — no service call — so to make
/// the web flow actually persist (and match the detail page's draft →
/// submit lifecycle) the save goes through
/// `PropertyService.create` / `PropertyService.update`.
///
/// `editingId` arrives as the `?id=` query param (nullable — the add route
/// omits it). When set, the existing property is loaded and the form is
/// prefilled, mirroring the Flutter edit flow's argument-driven prefill.
class AddPropertyPage extends StatefulComponent {
  final String? editingId;

  const AddPropertyPage({super.key, this.editingId});

  @override
  State<AddPropertyPage> createState() => _AddPropertyPageState();
}

class _AddPropertyPageState extends State<AddPropertyPage> {
  String _title = '';
  String _address = '';
  String _city = 'Subang Jaya';
  String _rental = '';
  String _size = '';

  /// Set once the edit-mode property has been loaded and fields prefilled.
  bool _prefilled = false;

  /// Set once a save succeeded — replaces the Flutter SnackBar + pop with an
  /// inline success card (the page stays put; the list route is a link).
  bool _saved = false;

  /// Whether the Flutter validator results should be shown. Flutter only ran
  /// validators on save, never per-keystroke.
  bool _showErrors = false;

  @override
  void initState() {
    super.initState();
    final editingId = component.editingId;
    if (editingId != null) unawaited(_loadExisting(editingId));
  }

  Future<void> _loadExisting(String editingId) async {
    final existing = await AppLocator.properties.detail(editingId);
    if (existing == null || !mounted) return;
    setState(() {
      _title = existing.title;
      _address = existing.address;
      _city = existing.city;
      _rental = existing.rentalRm.toStringAsFixed(0);
      _size = existing.sizeSqft.toStringAsFixed(0);
      _prefilled = true;
    });
  }

  bool get _titleMissing => _title.isEmpty;
  bool get _addressMissing => _address.isEmpty;
  bool get _rentalMissing => _rental.isEmpty;
  bool get _sizeMissing => _size.isEmpty;

  void _save() {
    setState(() => _showErrors = true);
    if (_titleMissing || _addressMissing || _rentalMissing || _sizeMissing) {
      return;
    }
    final editingId = component.editingId;
    unawaited(
      (editingId == null ? _create() : _updateExisting(editingId)).then((_) {
        if (mounted) setState(() => _saved = true);
      }),
    );
  }

  Future<void> _create() {
    return AppLocator.properties.create(
      CommercialProperty(
        id: 'prop-web-${DateTime.now().millisecondsSinceEpoch}',
        title: _title,
        address: _address,
        city: _city,
        state: 'Selangor',
        postcode: '',
        rentalRm: double.tryParse(_rental) ?? 0,
        sizeSqft: double.tryParse(_size) ?? 0,
        latitude: 3.0738,
        longitude: 101.5870,
        propertyType: 'Shop lot',
        verification: VerificationStatus.draft,
        suitabilityScore: 0,
        ownerId: DemoData.demoOwnerId,
        hasTour: false,
      ),
    );
  }

  Future<void> _updateExisting(String editingId) async {
    final existing = await AppLocator.properties.detail(editingId);
    if (existing == null) return;
    // `copyWith` does not cover address/city, so the record is rebuilt with
    // the edited basics layered onto the untouched fields.
    await AppLocator.properties.update(
      CommercialProperty(
        id: existing.id,
        title: _title,
        address: _address,
        city: _city,
        state: existing.state,
        postcode: existing.postcode,
        rentalRm: double.tryParse(_rental) ?? existing.rentalRm,
        rentalMaxRm: existing.rentalMaxRm,
        sizeSqft: double.tryParse(_size) ?? existing.sizeSqft,
        latitude: existing.latitude,
        longitude: existing.longitude,
        propertyType: existing.propertyType,
        verification: existing.verification,
        suitabilityScore: existing.suitabilityScore,
        ownerId: existing.ownerId,
        hasTour: existing.hasTour,
        requirements: existing.requirements,
        tags: existing.tags,
      ),
    );
  }

  @override
  Component build(BuildContext context) {
    final editingId = component.editingId;
    final body = _saved
        ? const _SavedCard()
        : (editingId != null && !_prefilled)
        ? const _Loading()
        : _FormBody(
            title: _title,
            address: _address,
            city: _city,
            rental: _rental,
            size: _size,
            saveLabel: editingId == null ? 'Save as draft' : 'Save changes',
            showErrors: _showErrors,
            titleMissing: _titleMissing,
            addressMissing: _addressMissing,
            rentalMissing: _rentalMissing,
            sizeMissing: _sizeMissing,
            onTitle: (v) => _title = v,
            onAddress: (v) => _address = v,
            onCity: (v) => _city = v,
            onRental: (v) => _rental = v,
            onSize: (v) => _size = v,
            onSave: _save,
          );
    return AppLayout(
      role: AppRole.owner,
      currentRoute: '/owner/add-property',
      title: editingId == null ? 'Add Property' : 'Edit Property',
      subtitle: AppRole.owner.label,
      child: body,
    );
  }
}

class _FormBody extends StatelessComponent {
  final String title;
  final String address;
  final String city;
  final String rental;
  final String size;
  final String saveLabel;

  final bool showErrors;
  final bool titleMissing;
  final bool addressMissing;
  final bool rentalMissing;
  final bool sizeMissing;

  final ValueChanged<String> onTitle;
  final ValueChanged<String> onAddress;
  final ValueChanged<String> onCity;
  final ValueChanged<String> onRental;
  final ValueChanged<String> onSize;
  final void Function() onSave;

  const _FormBody({
    required this.title,
    required this.address,
    required this.city,
    required this.rental,
    required this.size,
    required this.saveLabel,
    required this.showErrors,
    required this.titleMissing,
    required this.addressMissing,
    required this.rentalMissing,
    required this.sizeMissing,
    required this.onTitle,
    required this.onAddress,
    required this.onCity,
    required this.onRental,
    required this.onSize,
    required this.onSave,
  });

  @override
  Component build(BuildContext context) {
    return div(classes: 'stack', [
      div(classes: 'grid-2', [
        _Section('Basics', [
          _field(
            labelText: 'Listing title',
            field: input(
              type: InputType.text,
              classes: 'input',
              value: title,
              attributes: {'id': 'field-title'},
              events: events<String>(onInput: onTitle),
            ),
            error: showErrors && titleMissing ? 'Required' : null,
          ),
          _field(
            labelText: 'Street address',
            field: input(
              type: InputType.text,
              classes: 'input',
              value: address,
              attributes: {'id': 'field-address'},
              events: events<String>(onInput: onAddress),
            ),
            error: showErrors && addressMissing ? 'Required' : null,
          ),
          _field(
            labelText: 'City',
            field: input(
              type: InputType.text,
              classes: 'input',
              value: city,
              attributes: {'id': 'field-city'},
              events: events<String>(onInput: onCity),
            ),
          ),
        ]),
        _Section('Commercials', [
          _field(
            labelText: 'Monthly rental (RM)',
            field: input(
              // Flutter used `TextInputType.number`; jaspr's typed input
              // events deliver `num` (NaN when empty) for InputType.number,
              // so the numeric keyboard is requested via inputmode instead
              // and the raw text stays available for parsing.
              type: InputType.text,
              classes: 'input',
              value: rental,
              attributes: {'id': 'field-rental', 'inputmode': 'numeric'},
              events: events<String>(onInput: onRental),
            ),
            error: showErrors && rentalMissing ? 'Required' : null,
          ),
          _field(
            labelText: 'Floor area (sq ft)',
            field: input(
              type: InputType.text,
              classes: 'input',
              value: size,
              attributes: {'id': 'field-size', 'inputmode': 'numeric'},
              events: events<String>(onInput: onSize),
            ),
            error: showErrors && sizeMissing ? 'Required' : null,
          ),
        ]),
      ]),
      ActionButton(saveLabel, onClick: onSave, icon: 'save'),
    ]);
  }
}

class _Section extends StatelessComponent {
  final String heading;
  final List<Component> children;

  const _Section(this.heading, this.children);

  @override
  Component build(BuildContext context) {
    return div(classes: 'card stack', [
      h3(classes: 'title', [Component.text(heading)]),
      ...children,
    ]);
  }
}

Component _field({
  required String labelText,
  required Component field,
  String? error,
}) {
  return div(classes: 'stack', [
    span(classes: 'overline', [Component.text(labelText)]),
    field,
    if (error != null) p(classes: 'small text-danger', [Component.text(error)]),
  ]);
}

class _SavedCard extends StatelessComponent {
  const _SavedCard();

  @override
  Component build(BuildContext context) {
    return div(classes: 'card stack', [
      span(classes: 'overline', [Component.text('Saved')]),
      p(classes: 'body text-success', [
        Component.text(
          'Draft saved. Submit for verification from the detail page.',
        ),
      ]),
      const ActionLink(
        'Back to my properties',
        href: '/owner/properties',
        variant: 'secondary',
      ),
    ]);
  }
}

class _Loading extends StatelessComponent {
  const _Loading();

  @override
  Component build(BuildContext context) {
    return div(classes: 'card', [
      p(classes: 'body muted', [Component.text('Loading…')]),
    ]);
  }
}
