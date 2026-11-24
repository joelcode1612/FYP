import 'dart:async';
import 'dart:math';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';
import 'package:sitewise_jaspr_web/core/di/app_locator.dart';
import 'package:sitewise_jaspr_web/shared/presentation/layouts/app_layout.dart';

/// Live owner listing wizard. All values use the shared form vocabulary and
/// are persisted through the authenticated owner-listing repository.
@client
class AddPropertyPage extends StatefulComponent {
  final String? editingId;
  const AddPropertyPage({super.key, this.editingId});
  @override
  State<AddPropertyPage> createState() => _AddPropertyPageState();
}

class _AddPropertyPageState extends State<AddPropertyPage> {
  final Map<String, String> _v = <String, String>{'property_type': 'Shoplot'};
  final Map<String, String> _fieldErrors = <String, String>{};
  late final String _requestId = _uuid();
  int _step = 0;
  bool _loading = false;
  bool _loadedExisting = false;
  bool _saving = false;
  bool _saved = false;
  bool _draftSaved = false;
  bool _locked = false;
  bool _checkingAddress = false;
  String? _error;
  String? _savedId;
  String? _status;
  String? _addressStatus;

  static String _uuid() {
    final r = Random.secure();
    final b = List<int>.generate(16, (_) => r.nextInt(256));
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    final h = b.map((e) => e.toRadixString(16).padLeft(2, '0')).join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
  }

  @override
  void initState() {
    super.initState();
    final id = component.editingId;
    if (id != null) unawaited(_load(id));
  }

  Future<void> _load(String id) async {
    setState(() => _loading = true);
    try {
      final p = await AppLocator.ownerListings.getListing(id);
      if (!mounted) return;
      setState(() {
        _v.addAll({
          'name': p.name,
          'property_type': p.propertyType ?? '',
          'description': p.description ?? '',
          'address': p.address ?? '',
          'city': p.city ?? '',
          'state': p.state ?? '',
          'postcode': p.postcode ?? '',
          'rental_price': _num(p.rentalPrice),
          'size_sqft': _num(p.sizeSqft),
          'floor_level': p.floorLevel?.toString() ?? '',
          'floor_description': p.floorDescription ?? '',
          'unit_position': p.unitPosition ?? '',
          'frontage_ft': _num(p.frontageFt),
          'furnishing': p.furnishing ?? '',
          'has_parking': p.hasParking == null
              ? ''
              : (p.hasParking! ? 'Available' : 'Not available'),
          'availability': _availabilityLabel(p.availability),
          'lease_duration_months': p.leaseDurationMonths?.toString() ?? '',
          'rental_deposit_myr': _num(p.rentalDepositMyr),
          'available_from': p.availableFrom ?? '',
          'lease_duration_negotiable': p.leaseDurationNegotiable == true
              ? 'yes'
              : 'no',
          'landlord_fnb_permission': p.landlordFnbPermission ?? '',
          'tenure': p.tenure ?? '',
          'title_type': p.titleType ?? '',
        });
        _savedId = id;
        _loadedExisting = true;
        _locked = !p.locallyEditable;
        _status = p.verificationStatus;
        _loading = false;
      });
    } on Object {
      if (mounted) {
        setState(() {
          _error = 'Could not load this listing. Please retry.';
          _loading = false;
        });
      }
    }
  }

  static String _num(num? n) => n == null ? '' : n.toString();
  static String _availabilityLabel(String? v) => switch (v) {
    'Available now' || 'Ready to move in' => 'Ready to move in',
    'Available from a specific date' => 'Available from a specific date',
    'By arrangement' => 'By arrangement',
    _ => v ?? '',
  };

  void _set(String key, String value) => setState(() {
    _v[key] = value;
    _fieldErrors.remove(key);
    _error = null;
    _draftSaved = false;
  });
  String? _validateStep(int step) {
    _fieldErrors.clear();
    if (step == 0) {
      _putError('name', PropertyFormRules.titleError(_v['name']));
      _putError(
        'property_type',
        PropertyFormRules.propertyTypeError(_v['property_type']),
      );
      _putError('size_sqft', PropertyFormRules.areaError(_v['size_sqft']));
      _putError(
        'floor_description',
        PropertyFormRules.optionError(
          _v['floor_description'],
          propertyFloorOptions,
          'floor level',
        ),
      );
      _putError(
        'floor_level',
        PropertyFormRules.floorNumberError(
          _v['floor_description'],
          _v['floor_level'],
        ),
      );
      _putError(
        'furnishing',
        PropertyFormRules.optionError(
          _v['furnishing'],
          propertyFurnishingOptions,
          'furnishing',
        ),
      );
    }
    if (step == 1) {
      _putError(
        'rental_price',
        PropertyFormRules.rentError(_v['rental_price']),
      );
      _putError(
        'availability',
        PropertyFormRules.optionError(
          _v['availability'],
          propertyAvailabilityOptions,
          'availability',
        ),
      );
      _putError(
        'available_from',
        PropertyFormRules.availableDateError(
          _v['availability'],
          _v['available_from'],
        ),
      );
      _putError(
        'lease_choice',
        PropertyFormRules.leaseDurationError(
          _leaseChoice,
          _v['lease_duration_months'],
        ),
      );
      _putError(
        'landlord_fnb_permission',
        PropertyFormRules.optionError(
          _v['landlord_fnb_permission'],
          landlordFnbPermissionOptions,
          'landlord permission',
        ),
      );
      _putError(
        'tenure',
        PropertyFormRules.optionError(
          _v['tenure'],
          propertyTenureOptions,
          'land tenure',
          required: false,
        ),
      );
      _putError(
        'title_type',
        PropertyFormRules.optionError(
          _v['title_type'],
          propertyTitleTypeOptions,
          'title type',
          required: false,
        ),
      );
    }
    if (step == 2) {
      final cityOk = MalaysiaLocations.citiesFor(
        _v['state'],
      ).contains(_v['city']);
      final postcodeOk = MalaysiaLocations.postcodesFor(
        _v['state'],
        _v['city'],
      ).contains(_v['postcode']);
      if ((_v['address'] ?? '').trim().isEmpty ||
          !MalaysiaLocations.stateNames.contains(_v['state']) ||
          !cityOk ||
          !postcodeOk) {
        const message =
            'Enter a street address and select a valid Malaysian state, city and postcode.';
        if ((_v['address'] ?? '').trim().isEmpty) {
          _fieldErrors['address'] = 'Enter the street address.';
        }
        if (!MalaysiaLocations.stateNames.contains(_v['state'])) {
          _fieldErrors['state'] = 'Select a valid state.';
        }
        if (!cityOk) {
          _fieldErrors['city'] = 'Select a city for the chosen state.';
        }
        if (!postcodeOk) {
          _fieldErrors['postcode'] = 'Select a postcode for the chosen city.';
        }
        return message;
      }
    }
    return _fieldErrors.isEmpty ? null : _fieldErrors.values.first;
  }

  void _putError(String key, String? error) {
    if (error != null) _fieldErrors[key] = error;
  }

  String? get _leaseChoice {
    final selected = _v['lease_choice'];
    if (propertyLeaseOptions.contains(selected)) return selected;
    if (_v['lease_duration_negotiable'] == 'yes') return 'Negotiable';
    final m = int.tryParse(_v['lease_duration_months'] ?? '');
    return switch (m) {
      6 => '6 months',
      12 => '1 year',
      24 => '2 years',
      36 => '3 years',
      null => null,
      _ => 'Other duration',
    };
  }

  void _continue() {
    final error = _validateStep(_step);
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    setState(() {
      _error = null;
      _draftSaved = false;
      if (_step < 4) _step++;
    });
  }

  Future<void> _save({bool partial = false}) async {
    if (partial) {
      final titleError = PropertyFormRules.titleError(_v['name']);
      if (titleError != null) {
        setState(() {
          _fieldErrors['name'] = titleError;
          _error = 'Enter a property title before saving this draft.';
        });
        return;
      }
    } else {
      for (var i = 0; i < 3; i++) {
        final error = _validateStep(i);
        if (error != null) {
          setState(() {
            _step = i;
            _error = error;
          });
          return;
        }
      }
    }
    setState(() {
      _saving = true;
      _error = null;
      _draftSaved = false;
    });
    final lease = _v['lease_duration_negotiable'] == 'yes'
        ? null
        : int.tryParse(_v['lease_duration_months'] ?? '');
    final payload = <String, dynamic>{
      'draft_request_id': _requestId,
      'name': (_v['name'] ?? '').trim(), 'property_type': _v['property_type'],
      'description': _v['description'], 'address': (_v['address'] ?? '').trim(),
      'city': _v['city'], 'state': _v['state'], 'postcode': _v['postcode'],
      'rental_price': double.tryParse(_v['rental_price'] ?? ''),
      'size_sqft': double.tryParse(_v['size_sqft'] ?? ''),
      // Coordinates remain server-owned and are deliberately omitted.
      'floor_level':
          double.tryParse(_v['floor_level'] ?? '') ??
          switch (_v['floor_description']) {
            'Basement' => -1.0,
            'Ground floor' => 0.0,
            'First floor' => 1.0,
            'Second floor' => 2.0,
            _ => null,
          },
      'floor_description': _v['floor_description'],
      'unit_position': _v['unit_position'],
      'frontage_ft': double.tryParse(_v['frontage_ft'] ?? ''),
      'furnishing': _v['furnishing'],
      'has_parking': switch (_v['has_parking']) {
        'Available' => true,
        'Not available' => false,
        _ => null,
      },
      'availability': _availabilityWire(_v['availability']),
      'available_from': _v['availability'] == 'Available from a specific date'
          ? _v['available_from']
          : null,
      'lease_duration_months': lease,
      'lease_duration_negotiable': _v['lease_duration_negotiable'] == 'yes',
      'rental_deposit_myr': double.tryParse(_v['rental_deposit_myr'] ?? ''),
      'landlord_fnb_permission': _v['landlord_fnb_permission'],
      'tenure': _v['tenure'], 'title_type': _v['title_type'],
    };
    try {
      final editingId = component.editingId ?? _savedId;
      final result = editingId == null
          ? await AppLocator.ownerListings.createDraft(payload)
          : await AppLocator.ownerListings.updateDraft(editingId, payload);
      if (!mounted) return;
      setState(() {
        _savedId = result.id;
        _loadedExisting = true;
        _draftSaved = partial;
        _saved = !partial;
        _saving = false;
        _status = result.verificationStatus;
      });
    } on Object {
      if (mounted) {
        setState(() {
          _saving = false;
          _error =
              'The draft could not be saved. Your entries are still here; try again.';
        });
      }
    }
  }

  Future<void> _validateAddress() async {
    final id = _savedId;
    if (id == null || _checkingAddress) return;
    setState(() {
      _checkingAddress = true;
      _error = null;
    });
    try {
      final status = await AppLocator.ownerListings.validateSavedAddress(id);
      if (mounted) {
        setState(() {
          _addressStatus = status;
          _checkingAddress = false;
        });
      }
    } on Object {
      if (mounted) {
        setState(() {
          _error =
              'Address validation could not be completed. Your saved draft is unchanged.';
          _checkingAddress = false;
        });
      }
    }
  }

  static String? _availabilityWire(String? v) => switch (v) {
    'Ready to move in' => 'Ready to move in',
    'Available from a specific date' => 'Available from a specific date',
    'By arrangement' => 'By arrangement',
    _ => null,
  };

  @override
  Component build(BuildContext context) => AppLayout(
    role: AppRole.owner,
    currentRoute: '/owner/add-property',
    title: component.editingId == null ? 'Add Property' : 'Edit Property',
    eyebrow: 'Owner listing',
    subtitle:
        'Property details are saved as a private draft until the existing verification process is completed.',
    child: _loading
        ? div(classes: 'loading', [
            span(classes: 'spinner', []),
            Component.text('Loading property…'),
          ])
        : (component.editingId != null && !_loadedExisting && !_locked)
        ? div(classes: 'card stack', [
            p([
              Component.text(_error ?? 'Property details could not be loaded.'),
            ]),
            button(
              classes: 'btn btn--secondary',
              events: events(
                onClick: () => unawaited(_load(component.editingId!)),
              ),
              [Component.text('Retry')],
            ),
          ])
        : _saved
        ? _confirmation()
        : _locked
        ? _readOnly()
        : _wizard(),
  );

  Component _wizard() => div(classes: 'stack stack--md', [
    div(classes: 'sw-reg-stepper', [
      for (var i = 0; i < 5; i++)
        div(
          classes:
              'sw-reg-step ${i == _step
                  ? 'is-active'
                  : i < _step
                  ? 'is-done'
                  : ''}',
          [
            Component.text(
              '${i + 1}. ${const ['Property details', 'Rental & location', 'Agent verification', 'Review information', 'Confirmation'][i]}',
            ),
          ],
        ),
    ]),
    if (_error != null)
      div(classes: 'alert alert--error', [Component.text(_error!)]),
    if (_draftSaved)
      div(classes: 'alert alert--success', [
        Component.text(
          'Draft saved. Reference: ${_savedId ?? '—'}. Your entries remain open for editing.',
        ),
      ]),
    if (_status != null && _error != null)
      div(classes: 'alert', [
        Component.text('Current property status: $_status'),
      ]),
    if (_step == 0) _detailsStep(),
    if (_step == 1) _rentalStep(),
    if (_step == 2) _agentStep(),
    if (_step == 3) _reviewStep(),
    if (_step == 4) _confirmStep(),
    div(classes: 'row row--between', [
      button(
        classes: 'btn btn--secondary',
        disabled: _saving,
        events: events(onClick: () => _save(partial: true)),
        [Component.text(_saving ? 'Saving…' : 'Save progress')],
      ),
      button(
        classes: 'btn btn--secondary',
        disabled: _step == 0 || _saving,
        events: events(onClick: () => setState(() => _step--)),
        [Component.text('Back')],
      ),
      button(
        classes: 'btn btn--primary',
        disabled: _saving,
        events: events(onClick: _step == 4 ? _save : _continue),
        [
          Component.text(
            _saving
                ? 'Saving…'
                : _step == 3
                ? 'Continue to confirmation'
                : _step == 4
                ? 'Save as draft'
                : 'Continue',
          ),
        ],
      ),
    ]),
  ]);

  Component _detailsStep() => _section('Tell us about your property', [
    _field('name', 'Property title', required: true),
    _typeCards(),
    _field(
      'size_sqft',
      'Built-up area (sq ft)',
      type: 'number',
      required: true,
    ),
    _select(
      'floor_description',
      'Floor level',
      propertyFloorOptions,
      required: true,
      onChanged: (v) => setState(() {
        _v['floor_description'] = v;
        _draftSaved = false;
        _v['floor_level'] = switch (v) {
          'Basement' => '-1',
          'Ground floor' => '0',
          'First floor' => '1',
          'Second floor' => '2',
          _ => '',
        };
      }),
    ),
    if (_v['floor_description'] == 'Third floor or above')
      _field(
        'floor_level',
        'Specific floor number',
        type: 'number',
        required: true,
      ),
    _select(
      'unit_position',
      'Unit position',
      propertyUnitPositions,
      required: false,
    ),
    _field('frontage_ft', 'Shop frontage (ft)', type: 'number'),
    _select(
      'furnishing',
      'Furnishing condition',
      propertyFurnishingOptions,
      required: true,
    ),
    _select(
      'has_parking',
      'Owner-declared parking',
      propertyParkingOptions,
      required: false,
    ),
    _field(
      'description',
      'Description',
      textareaField: true,
      hint:
          'Describe the property condition, layout, facilities and other relevant information.',
    ),
  ]);

  Component _rentalStep() => _section('Rental terms and location', [
    _field(
      'rental_price',
      'Monthly rental (RM)',
      type: 'number',
      required: true,
    ),
    _select(
      'lease_choice',
      'Minimum rental period',
      propertyLeaseOptions,
      required: true,
      value: _leaseChoice ?? '',
      onChanged: (v) => setState(() {
        _draftSaved = false;
        _v['lease_choice'] = v;
        _v['lease_duration_negotiable'] = v == 'Negotiable' ? 'yes' : 'no';
        _v['lease_duration_months'] = switch (v) {
          '6 months' => '6',
          '1 year' => '12',
          '2 years' => '24',
          '3 years' => '36',
          _ => _v['lease_duration_months'] ?? '',
        };
      }),
    ),
    if (_leaseChoice == 'Other duration')
      _field(
        'lease_duration_months',
        'Minimum rental period (months)',
        type: 'number',
        required: true,
      ),
    _select(
      'availability',
      'Availability',
      propertyAvailabilityOptions,
      required: true,
    ),
    if (_v['availability'] == 'Available from a specific date')
      _field(
        'available_from',
        'Available-from date',
        type: 'date',
        required: true,
      ),
    _field('rental_deposit_myr', 'Rental deposit (RM)', type: 'number'),
    _select(
      'landlord_fnb_permission',
      'Landlord permission for F&B use',
      landlordFnbPermissionOptions,
      required: true,
    ),
    _pair('Rental per square foot', _psfLabel),
    _select(
      'tenure',
      'Land tenure (optional)',
      propertyTenureOptions,
      required: false,
    ),
    _select(
      'title_type',
      'Property title type (optional)',
      propertyTitleTypeOptions,
      required: false,
    ),
    _field('address', 'Street address', required: true),
    _select(
      'state',
      'State / federal territory',
      MalaysiaLocations.stateNames,
      required: true,
      onChanged: (value) => setState(() {
        _draftSaved = false;
        _v['state'] = value;
        _v['city'] = '';
        _v['postcode'] = '';
        _fieldErrors.remove('state');
        _fieldErrors.remove('city');
        _fieldErrors.remove('postcode');
      }),
    ),
    _select(
      'city',
      'City / township',
      MalaysiaLocations.citiesFor(_v['state']),
      required: true,
      onChanged: (value) => setState(() {
        _draftSaved = false;
        _v['city'] = value;
        _v['postcode'] = '';
        _fieldErrors.remove('city');
        _fieldErrors.remove('postcode');
      }),
    ),
    _select(
      'postcode',
      'Postcode',
      MalaysiaLocations.postcodesFor(_v['state'], _v['city']),
      required: true,
    ),
  ]);

  Component _agentStep() => _section('Agent verification', [
    _pair(
      'Property owner',
      'Provides property information, ownership or authorization proof, and requests an authorized agent inspection.',
    ),
    _pair(
      'Assigned agent',
      'Reviews the information, inspects observable facts, completes the existing 38-target 360° capture, previews the generated panorama and submits the inspection.',
    ),
    _pair(
      'Administrator',
      'Reviews the property, ownership evidence, agent inspection and panorama, then makes the final verification decision.',
    ),
  ]);

  Component _reviewStep() => _section('Review information', [
    _pair(
      'Property characteristics',
      '${_v['name'] ?? 'Not provided'} · ${_v['property_type'] ?? 'Not provided'} · ${_v['size_sqft'] ?? 'Not provided'} sq ft · ${_v['floor_description'] ?? 'Not provided'} · ${_v['unit_position'] ?? 'Not provided'} · frontage ${_v['frontage_ft']?.isNotEmpty == true ? '${_v['frontage_ft']} ft' : 'Not provided'} · ${_v['furnishing'] ?? 'Not provided'} · parking ${_v['has_parking'] ?? 'Not sure'} · ${_v['description']?.isNotEmpty == true ? _v['description'] : 'Not provided'}',
    ),
    _pair(
      'Rental terms',
      'RM ${_v['rental_price'] ?? '—'} / month · ${_v['size_sqft'] ?? '—'} sq ft · $_psfLabel · ${_leaseChoice ?? 'Not provided'} · ${_v['availability'] ?? 'Not provided'} · available from ${_v['available_from']?.isNotEmpty == true ? _v['available_from'] : 'Not applicable'} · deposit RM ${_v['rental_deposit_myr']?.isNotEmpty == true ? _v['rental_deposit_myr'] : 'Not provided'} · F&B permission ${_v['landlord_fnb_permission'] ?? 'Not provided'}',
    ),
    _pair(
      'Ownership information',
      '${_v['tenure'] ?? 'Not provided'} · ${_v['title_type'] ?? 'Not provided'} (owner declaration; legal ownership is verified from submitted evidence)',
    ),
    _pair(
      'Address',
      '${_v['address'] ?? 'Not provided'}, ${_v['city'] ?? 'Not provided'}, ${_v['state'] ?? 'Not provided'} ${_v['postcode'] ?? ''}',
    ),
    _pair(
      'Agent verification',
      'An assigned agent completes the physical inspection and panorama. This form does not submit or publish the listing.',
    ),
  ]);

  Component _confirmStep() => _section('Save your property draft', [
    _pair(
      'Next step',
      'Saving creates or updates the property draft. Ownership proof and agent requests continue through the existing Owner workflow in the SiteWise mobile app.',
    ),
    _pair(
      'Rental summary',
      'RM ${_v['rental_price'] ?? '—'} monthly · ${_v['size_sqft'] ?? '—'} sq ft · $_psfLabel',
    ),
  ]);

  String get _psfLabel {
    final rent = double.tryParse(_v['rental_price'] ?? '');
    final area = double.tryParse(_v['size_sqft'] ?? '');
    return rent != null && area != null && area > 0
        ? 'RM ${(rent / area).toStringAsFixed(2)} / sq ft'
        : 'Not available';
  }

  Component _section(String title, List<Component> children) =>
      div(classes: 'card stack stack--md', [
        h2([Component.text(title)]),
        div(classes: 'grid grid--2', children),
      ]);
  Component _field(
    String key,
    String labelText, {
    bool required = false,
    String type = 'text',
    bool textareaField = false,
    String? hint,
  }) {
    final val = _v[key] ?? '';
    final event = events<String>(onInput: (v) => _set(key, v));
    final control = textareaField
        ? textarea(
            attributes: {'id': key, 'rows': '4', 'placeholder': hint ?? ''},
            events: event,
            [Component.text(val)],
          )
        : input(
            type: switch (type) {
              'number' => InputType.number,
              'date' => InputType.date,
              _ => InputType.text,
            },
            attributes: {
              'id': key,
              'value': val,
              'placeholder': hint ?? '',
              if (type == 'number') 'step': 'any',
              if (required) 'required': '',
            },
            events: event,
          );
    return div(classes: 'stack stack--xs', [
      label(htmlFor: key, [
        Component.text(labelText),
        if (required) Component.text(' *'),
      ]),
      control,
      if (_fieldErrors[key] != null)
        p(classes: 'text-danger small', [Component.text(_fieldErrors[key]!)]),
    ]);
  }

  Component _select(
    String key,
    String labelText,
    List<String> options, {
    bool required = false,
    String? value,
    void Function(String)? onChanged,
  }) => div(classes: 'stack stack--xs', [
    label(htmlFor: key, [
      Component.text(labelText),
      if (required) Component.text(' *'),
    ]),
    select(
      attributes: {'id': key, if (required) 'required': ''},
      events: events<List<String>>(
        onInput: (v) {
          final selected = v.isEmpty ? '' : v.first;
          (onChanged ?? (x) => _set(key, x))(selected);
        },
      ),
      [
        option(value: '', [Component.text('Select…')]),
        for (final opt in options)
          option(
            value: opt,
            attributes: (value ?? _v[key]) == opt ? {'selected': ''} : null,
            [Component.text(opt)],
          ),
      ],
    ),
    if (_fieldErrors[key] != null)
      p(classes: 'text-danger small', [Component.text(_fieldErrors[key]!)]),
  ]);
  Component _pair(String k, String v) => div(classes: 'stack stack--xs', [
    span(classes: 'text-muted', [Component.text(k)]),
    span([Component.text(v)]),
  ]);

  Component _typeCards() => div(classes: 'stack stack--xs', [
    label([Component.text('Commercial property type *')]),
    div(classes: 'grid grid--2', [
      for (final type in commercialPropertyTypeLabels)
        button(
          classes: 'card card--interactive',
          attributes: {
            'type': 'button',
            'aria-pressed': '${_v['property_type'] == type}',
          },
          events: events(onClick: () => _set('property_type', type)),
          [Component.text(type)],
        ),
    ]),
    if (_fieldErrors['property_type'] != null)
      p(classes: 'text-danger small', [
        Component.text(_fieldErrors['property_type']!),
      ]),
  ]);

  Component _confirmation() => div(classes: 'card stack stack--md', [
    h2([Component.text('Property draft saved')]),
    p([
      Component.text(
        'Reference: ${_savedId ?? 'Unavailable'} · Status: ${_status ?? 'draft'}',
      ),
    ]),
    p([
      Component.text(
        'The property has not been published. Continue to the existing ownership proof and agent request workflow in the SiteWise mobile app.',
      ),
    ]),
    if (_addressStatus != null)
      p(classes: 'small', [
        Component.text(
          'Address check: ${_addressStatus!.replaceAll('_', ' ')}',
        ),
      ]),
    button(
      classes: 'btn btn--secondary',
      disabled: _checkingAddress,
      events: events(onClick: _validateAddress),
      [
        Component.text(
          _checkingAddress ? 'Checking address…' : 'Validate saved address',
        ),
      ],
    ),
    div(classes: 'row', [
      a(
        href: '/owner/property-detail?id=${_savedId ?? ''}',
        classes: 'btn btn--primary',
        [Component.text('View property details')],
      ),
      a(href: '/owner/properties', classes: 'btn btn--secondary', [
        Component.text('Go to My Listings'),
      ]),
    ]),
  ]);

  Component _readOnly() => div(classes: 'card stack stack--md', [
    h2([Component.text('Property details are read-only')]),
    p([
      Component.text(
        'Current status: ${_status ?? 'under review'}. An administrator must reopen this listing through the authorized correction workflow before its submitted details can change.',
      ),
    ]),
    _reviewStep(),
    a(
      href: '/owner/property-detail?id=${component.editingId ?? ''}',
      classes: 'btn btn--secondary',
      [Component.text('View property details')],
    ),
  ]);
}
