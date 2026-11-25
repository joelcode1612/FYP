import 'dart:async';
import 'dart:math';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';
import 'package:sitewise_jaspr_web/core/di/app_locator.dart';
import 'package:sitewise_jaspr_web/features/authentication/data/auth_service.dart';
import 'package:sitewise_jaspr_web/shared/presentation/components/address_preview_map.dart';
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
  final Map<String, String> _baseline = {'property_type': 'Shoplot'};
  String? _requestId;
  Map<String, dynamic>? _createAttempt;
  final Set<String> _pendingReplayFields = {};
  bool _recoveryFailed = false;
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

  // --- Automatic address preview (Google/fallback geocoder, server-side) ---
  // Debounced auto-search once the required address fields are valid; the
  // confirmed location rides Save Draft as signed evidence that the backend
  // verifies against the stored address.
  Timer? _previewTimer;
  int _previewSeq = 0;
  AddressPreview? _preview;
  bool _previewPending = false;
  String? _previewError;
  String? _lastRequestedKey;
  String? _confirmedToken;
  String? _confirmedKey;
  String? _confirmedLabel;
  bool _mapExpanded = false;
  bool _panelCollapsed = false;

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
    if (id != null) {
      unawaited(_load(id));
    } else {
      unawaited(_recoverCreation());
    }
  }

  Future<void> _load(String id) async {
    setState(() => _loading = true);
    try {
      final p = await AppLocator.ownerListings.getListing(id);
      if (!mounted) return;
      _applyListing(p);
    } on Object {
      if (mounted) {
        setState(() {
          _error = 'Could not load this listing. Please retry.';
          _loading = false;
        });
      }
    }
  }

  void _applyListing(OwnerListing p) {
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
        'lease_duration_negotiable': switch (p.leaseDurationNegotiable) {
          true => 'yes',
          false => 'no',
          null => '',
        },
        'tenure': p.tenure ?? '',
        'title_type': p.titleType ?? '',
      });
      _baseline
        ..clear()
        ..addAll(_v);
      _savedId = p.id;
      _loadedExisting = true;
      _locked = !p.locallyEditable;
      _status = p.verificationStatus;
      // A saved verdict with live coordinates IS a confirmed location for the
      // stored address: the backend clears it on any address change, so its
      // presence here means the user already confirmed THIS address.
      final validation = p.addressValidationStatus;
      if ((validation == 'validated' || validation == 'partially_validated') &&
          p.latitude != null &&
          p.longitude != null) {
        _confirmedToken = null;
        _confirmedKey = _currentAddressKey;
        _confirmedLabel = null;
        _preview = null;
      }
      _loading = false;
    });
  }

  Future<void> _recoverCreation() async {
    setState(() {
      _loading = true;
      _error = null;
      _recoveryFailed = false;
    });
    try {
      _requestId ??= WebAuth.draftRequestId;
      final requestId = _requestId;
      if (requestId == null) return;
      final listing = await AppLocator.ownerListings.recoverDraft(requestId);
      if (!mounted || listing == null) return;
      _applyListing(listing);
      _forgetCreation();
    } catch (error) {
      if (mounted) {
        setState(() {
          _recoveryFailed = true;
          _error = _saveError(error, 'Could not check for an earlier draft.');
        });
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _forgetCreation() {
    // A failed local cleanup is safe. Reopening will recover the same row.
    try {
      WebAuth.rememberDraftRequestId(null);
    } on Object {
      return;
    }
    _requestId = null;
    _createAttempt = null;
    _pendingReplayFields.clear();
  }

  String _saveError(Object error, String fallback) {
    if (error is AppFailure) {
      if (error is ServiceFailure || error is ResponseFormatFailure) {
        return '${error.userMessage} Your entries are still here.';
      }
      return '${error.message} Your entries are still here.';
    }
    return '$fallback Your entries are still here.';
  }

  static String _num(num? n) => n == null ? '' : n.toString();
  static String _availabilityLabel(String? v) => switch (v) {
    'Available now' || 'Ready to move in' => 'Ready to move in',
    'Available from a specific date' => 'Available from a specific date',
    'By arrangement' => 'By arrangement',
    _ => v ?? '',
  };

  void _set(String key, String value) {
    setState(() {
      _v[key] = value;
      _fieldErrors.remove(key);
      _error = null;
      _draftSaved = false;
    });
    // Any address-field edit invalidates a previous confirmation and schedules
    // the debounced automatic re-search.
    if (const {'address', 'state', 'city', 'postcode'}.contains(key)) {
      _onAddressFieldsChanged();
    }
  }
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
    if (_saving || _loading || _locked || _recoveryFailed) return;
    final editingId = component.editingId ?? _savedId;
    if (editingId != null && !_loadedExisting) return;
    final snapshot = Map<String, String>.of(_v);
    bool changed(String field) => snapshot[field] != _baseline[field];
    final titleError = PropertyFormRules.titleError(snapshot['name']);
    if (titleError != null &&
        (editingId == null || changed('name') || !partial)) {
      setState(() {
        _fieldErrors['name'] = titleError;
        _error = titleError;
      });
      return;
    }
    if (!partial) {
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

    final invalid = <String, String>{};
    final payload = <String, dynamic>{};
    void add(String key, Object? value, {bool dependentChange = false}) {
      if (editingId == null || changed(key) || dependentChange) {
        payload[key] = value;
      }
    }

    String? value(String key) {
      final text = snapshot[key]?.trim();
      return text == null || text.isEmpty ? null : text;
    }

    void number(String key, String label, double min, double max) {
      if (editingId != null && !changed(key)) return;
      final raw = value(key);
      final parsed = raw == null ? null : double.tryParse(raw);
      if (raw != null &&
          (parsed == null ||
              !parsed.isFinite ||
              parsed < min ||
              parsed > max)) {
        invalid[key] = 'Enter a valid $label.';
      }
      add(key, parsed);
    }

    for (final key in const [
      'name',
      'property_type',
      'description',
      'address',
      'city',
      'state',
      'postcode',
      'floor_description',
      'unit_position',
      'furnishing',
      'tenure',
      'title_type',
    ]) {
      add(key, value(key));
    }
    number('rental_price', 'monthly rent', 0.01, 10000000);
    number('size_sqft', 'built-up area', 0.01, 10000000);
    number('floor_level', 'floor number', -1, 9999.9);
    number('frontage_ft', 'frontage', 0, 10000);
    number('rental_deposit_myr', 'rental deposit', 0, 10000000);
    add('has_parking', switch (snapshot['has_parking']) {
      'Available' => true,
      'Not available' => false,
      _ => null,
    });
    add('availability', _availabilityWire(snapshot['availability']));
    add(
      'available_from',
      snapshot['availability'] == 'Available from a specific date'
          ? value('available_from')
          : null,
      dependentChange: changed('availability'),
    );
    final leaseChanged =
        changed('lease_duration_negotiable') ||
        changed('lease_duration_months');
    if (editingId == null || leaseChanged) {
      final negotiable = switch (snapshot['lease_duration_negotiable']) {
        'yes' => true,
        'no' => false,
        _ => null,
      };
      final raw = value('lease_duration_months');
      final lease = negotiable == true || raw == null
          ? null
          : int.tryParse(raw);
      if (negotiable != true &&
          raw != null &&
          (lease == null || lease < 1 || lease > 360)) {
        invalid['lease_duration_months'] =
            'Enter a rental period from 1 to 360 months.';
      }
      payload['lease_duration_months'] = lease;
      payload['lease_duration_negotiable'] = negotiable;
    }
    if (invalid.isNotEmpty) {
      setState(() {
        _fieldErrors.addAll(invalid);
        _error = invalid.values.join(' ');
      });
      return;
    }
    // The confirmed location rides the save as signed evidence bound to the
    // exact address; without it the draft simply saves unverified.
    if (_confirmationCurrent && _confirmedToken != null) {
      payload['address_confirmation_token'] = _confirmedToken;
    }

    setState(() {
      _saving = true;
      _error = null;
      _draftSaved = false;
    });
    try {
      final OwnerListing result;
      if (editingId == null) {
        final requestId = _requestId ??= WebAuth.draftRequestId ?? _uuid();
        WebAuth.rememberDraftRequestId(requestId);
        final previous = _createAttempt;
        _createAttempt ??= Map.of(payload);
        // A retried create replays only changed fields, but confirmation
        // evidence must ride EVERY attempt: the first attempt may have failed
        // before the server applied it.
        if (_confirmationCurrent && _confirmedToken != null) {
          _pendingReplayFields.add('address_confirmation_token');
        }
        final replayPatch = Map<String, dynamic>.of(payload)
          ..removeWhere(
            (key, value) => previous == null
                ? !changed(key)
                : previous[key] == value && !_pendingReplayFields.contains(key),
          );
        if (previous != null) _pendingReplayFields.addAll(replayPatch.keys);
        result = await AppLocator.ownerListings.createDraft({
          ...payload,
          'draft_request_id': requestId,
        }, replayPatch: replayPatch);
        if (mounted) _forgetCreation();
      } else {
        result = await AppLocator.ownerListings.updateDraft(editingId, payload);
      }
      if (!mounted) return;
      setState(() {
        _savedId = result.id;
        _loadedExisting = true;
        _baseline
          ..clear()
          ..addAll(snapshot);
        _draftSaved = partial;
        _saved = !partial;
        _status = result.verificationStatus;
      });
    } catch (error) {
      if (mounted) {
        setState(() => _error = _saveError(error, 'Could not save the draft.'));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
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

  // ---------------------------------------------------------------------------
  // Automatic address preview + location confirmation
  // ---------------------------------------------------------------------------

  /// Canonical identity of the typed address, matching the backend's evidence
  /// binding (whitespace-collapsed, case-folded parts joined with '|').
  String get _currentAddressKey => [
    (_v['address'] ?? '').trim(),
    (_v['city'] ?? '').trim(),
    (_v['state'] ?? '').trim(),
    (_v['postcode'] ?? '').trim(),
  ].map((part) => part.toLowerCase().replaceAll(RegExp(r'\s+'), ' ')).join('|');

  /// The preview fires only when the required address fields carry valid
  /// Malaysian dropdown values (state/city/postcode stay dropdown-driven).
  bool get _addressComplete {
    final state = _v['state'] ?? '';
    final city = _v['city'] ?? '';
    final postcode = _v['postcode'] ?? '';
    return (_v['address'] ?? '').trim().isNotEmpty &&
        MalaysiaLocations.stateNames.contains(state) &&
        MalaysiaLocations.citiesFor(state).contains(city) &&
        MalaysiaLocations.postcodesFor(state, city).contains(postcode);
  }

  /// Confirmation is valid only while the typed address is unchanged.
  bool get _confirmationCurrent =>
      _confirmedToken != null && _confirmedKey == _currentAddressKey;

  void _onAddressFieldsChanged() {
    // An edited address immediately invalidates the previous confirmation —
    // Save Draft must never carry evidence for an address the user changed.
    if (_confirmedKey != null && _confirmedKey != _currentAddressKey) {
      setState(() {
        _confirmedToken = null;
        _confirmedKey = null;
        _confirmedLabel = null;
      });
    }
    _schedulePreview();
  }

  void _schedulePreview() {
    _previewTimer?.cancel();
    if (!_addressComplete) {
      if (_preview != null || _previewPending || _previewError != null) {
        setState(() {
          _preview = null;
          _previewPending = false;
          _previewError = null;
          _lastRequestedKey = null;
          _mapExpanded = false;
          _panelCollapsed = false;
        });
      }
      return;
    }
    final key = _currentAddressKey;
    // Duplicate guard: an identical address is already previewed or in
    // flight, so typing non-address noise never re-requests.
    if (key == _lastRequestedKey && (_preview != null || _previewPending)) {
      return;
    }
    // ~800 ms after the latest change, request the match automatically.
    _previewTimer = Timer(const Duration(milliseconds: 800), () {
      unawaited(_runPreview(key));
    });
  }

  Future<void> _runPreview(String key) async {
    final seq = ++_previewSeq;
    setState(() {
      _previewPending = true;
      _previewError = null;
      _panelCollapsed = false;
    });
    try {
      final preview = await AppLocator.ownerListings.previewAddress(
        address: (_v['address'] ?? '').trim(),
        city: (_v['city'] ?? '').trim(),
        state: (_v['state'] ?? '').trim(),
        postcode: (_v['postcode'] ?? '').trim(),
      );
      // Ignore outdated responses: the user changed the address meanwhile.
      if (!mounted || seq != _previewSeq) return;
      setState(() {
        _previewPending = false;
        _lastRequestedKey = key;
        _preview = preview;
        if (_confirmedKey != null && _confirmedKey != key) {
          _confirmedToken = null;
          _confirmedKey = null;
          _confirmedLabel = null;
        }
      });
    } on Object {
      if (!mounted || seq != _previewSeq) return;
      setState(() {
        _previewPending = false;
        _lastRequestedKey = key;
        _preview = null;
        _previewError =
            'Address lookup is temporarily unavailable. You can still save '
            'the draft with the address you typed; its location can be '
            'verified later.';
      });
    }
  }

  void _confirmLocation() {
    final token = _preview?.confirmation?.token;
    if (token == null || _preview == null) return;
    setState(() {
      _confirmedToken = token;
      _confirmedKey = _currentAddressKey;
      _confirmedLabel = _preview!.formattedAddress ?? '';
    });
  }

  void _editAddress() {
    // Collapse the preview and drop the confirmation so the owner can retype;
    // the next change re-runs the automatic search automatically.
    setState(() {
      _panelCollapsed = true;
      _confirmedToken = null;
      _confirmedKey = null;
      _confirmedLabel = null;
    });
  }

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
        : (_recoveryFailed ||
              (component.editingId != null && !_loadedExisting && !_locked))
        ? div(classes: 'card stack', [
            p([
              Component.text(_error ?? 'Property details could not be loaded.'),
            ]),
            button(
              classes: 'btn btn--secondary',
              events: events(
                onClick: () {
                  final id = component.editingId;
                  unawaited(id == null ? _recoverCreation() : _load(id));
                },
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
        _onAddressFieldsChanged();
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
        _onAddressFieldsChanged();
      }),
    ),
    _select(
      'postcode',
      'Postcode',
      MalaysiaLocations.postcodesFor(_v['state'], _v['city']),
      required: true,
    ),
    ?_addressPreviewPanel(),
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
      'RM ${_v['rental_price'] ?? '—'} / month · ${_v['size_sqft'] ?? '—'} sq ft · $_psfLabel · ${_leaseChoice ?? 'Not provided'} · ${_v['availability'] ?? 'Not provided'} · available from ${_v['available_from']?.isNotEmpty == true ? _v['available_from'] : 'Not applicable'} · deposit RM ${_v['rental_deposit_myr']?.isNotEmpty == true ? _v['rental_deposit_myr'] : 'Not provided'}',
    ),
    _pair(
      'Ownership information',
      '${_v['tenure'] ?? 'Not provided'} · ${_v['title_type'] ?? 'Not provided'} (owner declaration; legal ownership is verified from submitted evidence)',
    ),
    _pair(
      'Address',
      '${_v['address'] ?? 'Not provided'}, ${_v['city'] ?? 'Not provided'}, ${_v['state'] ?? 'Not provided'} ${_v['postcode'] ?? ''}'
      '${_confirmationCurrent ? ' · location confirmed on the map' : ' · location not yet confirmed'}',
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

  /// Compact interactive map + match status below the address fields:
  /// automatic search result, confirmation evidence, edit and expand.
  Component? _addressPreviewPanel() {
    final preview = _preview;
    final confirmed = _confirmationCurrent;
    final showPanel =
        (preview != null || _previewPending || _previewError != null || confirmed) &&
        !_panelCollapsed;
    if (!showPanel) return null;

    final children = <Component>[];
    if (confirmed) {
      children.add(
        div(classes: 'sw-addr-confirmed', [
          Component.text(
            'Location confirmed for this address'
            '${_confirmedLabel != null && _confirmedLabel!.isNotEmpty ? ' — $_confirmedLabel' : ''}.',
          ),
        ]),
      );
    }
    if (_previewPending) {
      children.add(
        div(classes: 'sw-addr-status is-searching', [
          span(classes: 'spinner spinner--sm', []),
          Component.text(' Searching for the address…'),
        ]),
      );
    } else if (_previewError != null && preview == null) {
      children.add(div(classes: 'sw-addr-status is-error', [
        Component.text(_previewError!),
      ]));
    } else if (preview != null && !confirmed) {
      children.add(
        div(classes: 'sw-addr-status is-${preview.matchClass.name}', [
          Component.text(
            '${preview.matchClass.label}'
            '${preview.provider == null ? '' : ' (${preview.provider})'}',
          ),
        ]),
      );
      if (preview.formattedAddress != null) {
        children.add(
          p(classes: 'small', [Component.text(preview.formattedAddress!)]),
        );
      }
      children.add(_componentChips(preview));
      for (final note in preview.notes) {
        children.add(p(classes: 'small text-muted', [Component.text(note)]));
      }
    }
    if (preview != null && preview.hasLocation) {
      children.add(
        AddressPreviewMap(
          latitude: preview.latitude!,
          longitude: preview.longitude!,
          label: preview.formattedAddress ?? '',
          title: 'Preview of the matched property location',
          height: _mapExpanded ? 560 : 300,
        ),
      );
      children.add(
        p(classes: 'small text-muted', [
          Component.text('Map data © OpenStreetMap contributors.'),
        ]),
      );
    }
    if (preview != null && !confirmed && preview.confirmable) {
      children.add(
        div(classes: 'row', [
          button(
            classes: 'btn btn--primary',
            events: events(onClick: _confirmLocation),
            [Component.text('Confirm location')],
          ),
          button(
            classes: 'btn btn--secondary',
            events: events(onClick: _editAddress),
            [Component.text('Edit address')],
          ),
        ]),
      );
      children.add(
        p(classes: 'small text-muted', [
          Component.text(
            'Confirming records that the shown location is the actual '
            'property location for this address. It is not ownership proof '
            'or administrator verification.',
          ),
        ]),
      );
    } else if (confirmed) {
      children.add(
        div(classes: 'row', [
          button(
            classes: 'btn btn--secondary',
            events: events(onClick: _editAddress),
            [Component.text('Edit address')],
          ),
        ]),
      );
    }
    return div(classes: 'card stack stack--sm sw-addr-preview', [
      div(classes: 'row row--between', [
        h3([Component.text('Location preview')]),
        if (preview != null && preview.hasLocation)
          button(
            classes: 'btn btn--secondary btn--sm',
            events: events(
              onClick: () => setState(() => _mapExpanded = !_mapExpanded),
            ),
            [Component.text(_mapExpanded ? 'Collapse map' : 'Expand map')],
          ),
      ]),
      div(classes: 'stack stack--xs', children),
    ]);
  }

  Component _componentChips(AddressPreview preview) {
    String label(bool ok, String what) => ok ? '$what matched' : '$what differs';
    final chips = <Component>[
      span(classes: preview.components['postcode_matches'] == false ? 'chip chip--bad' : 'chip chip--ok', [
        Component.text(label(preview.components['postcode_matches'] != false, 'Postcode')),
      ]),
      span(classes: preview.components['city_matches'] == false ? 'chip chip--bad' : 'chip chip--ok', [
        Component.text(label(preview.components['city_matches'] != false, 'City')),
      ]),
      span(classes: preview.components['state_matches'] == false ? 'chip chip--bad' : 'chip chip--ok', [
        Component.text(label(preview.components['state_matches'] != false, 'State')),
      ]),
      span(classes: preview.components['country_matches'] == false ? 'chip chip--bad' : 'chip chip--ok', [
        Component.text(label(preview.components['country_matches'] != false, 'Country: Malaysia')),
      ]),
    ];
    return div(classes: 'sw-addr-chips', chips);
  }

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
