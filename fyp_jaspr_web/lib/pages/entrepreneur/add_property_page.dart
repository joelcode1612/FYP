import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
// The wizard uses the web repository's owner-listing/address endpoints, not
// the shared catalogue repository of the same name.
import 'package:shared_logic/shared_logic.dart' hide ApiPropertyRepository;
import 'package:universal_web/web.dart' as web;

import '../../components/ui.dart';
import '../../data/api_property_repository.dart';
import '../../data/app_locator.dart';
import '../../layouts/app_layout.dart';

/// A photo selected in this browser session. [url] is a browser object URL,
/// revoked when the photo is removed or the page state is disposed. Nothing is
/// uploaded: the web app has no image-upload endpoint or media service.
final class _SelectedPhoto {
  const _SelectedPhoto({
    required this.name,
    required this.sizeLabel,
    required this.url,
  });

  final String name;
  final String sizeLabel;
  final String url;
}

/// Entrepreneur property registration — a compact five-step wizard.
///
/// Steps: property details, location & pricing, F&B readiness, photos & proof,
/// then review. The review step saves a real **draft** through FastAPI, runs the
/// two-phase geospatial enrichment (PostGIS first, population second) and only
/// then offers an explicit **Submit to Admin**. Nothing enters the review queue
/// on its own.
///
/// Layout note: this is a single centred 720px column — the design system's cap
/// for a standalone form. The former hero banner, in-page breadcrumb and
/// persistent preview sidebar were removed; they pushed the form below the fold
/// and made a five-field step read as a long vertical list. The global
/// [AppLayout] navigation is the only navigation on the page.
@client
class AddPropertyPage extends StatefulComponent {
  const AddPropertyPage({super.key});

  @override
  State<AddPropertyPage> createState() => _AddPropertyPageState();
}

class _AddPropertyPageState extends State<AddPropertyPage> {
  int _step = 0;
  final Map<String, String> _fields = {};
  final Set<String> _facilities = {};
  bool _confirm = false;
  bool _saved = false;
  bool _saving = false;
  final Map<String, String> _errors = {};
  final List<_SelectedPhoto> _photos = [];
  String? _photoError;

  /// Set when the backend rejects the submission — rendered verbatim so the
  /// administrator's/user's own sentence is never replaced by "something
  /// went wrong".
  String? _submitError;

  /// The server's own sentence when the verification submission failed after
  /// the listing was saved — shown honestly, never disguised as a success.
  String? _enqueueError;

  /// Latest per-category enrichment state, straight from the backend.
  PropertyEnrichmentSummary? _enrichment;

  /// `true` while an enrichment phase (or a single-category retry) is running.
  bool _enriching = false;

  /// A phase-level failure. Per-category failures live in [_enrichment].
  String? _enrichmentError;

  /// `true` once the owner has explicitly asked to submit.
  bool _submitting = false;
  bool _submitted = false;

  /// The owner accepted that population could not be measured. Required
  /// before a submission with an unavailable population is allowed through.
  bool _ackPopulation = false;

  /// Populated only from a confirmed API response.
  OwnerListingResult? _result;

  /// Address-verification state machine. Kept SEPARATE from the property's
  /// administrative verification status: a Google verdict proves the address
  /// exists, never ownership or approval.
  AddressVerificationState _addressState = AddressVerificationState.unverified;
  AddressValidationResult? _addressResult;
  AddressSnapshot? _verifiedSnapshot;
  String? _addressMessage;
  double? _verifiedLatitude;
  double? _verifiedLongitude;

  /// Monotonic token: a late response from an earlier request must never mark
  /// a modified address as verified.
  int _addressRequestId = 0;

  final ApiPropertyRepository _repository = ApiPropertyRepository();

  /// Short labels for the horizontal step indicator.
  static const _steps = ['Details', 'Location', 'F&B', 'Photos', 'Review'];

  /// Full titles for the card heading.
  static const _stepTitles = [
    'Property details',
    'Location & pricing',
    'F&B readiness',
    'Photos & proof',
    'Review & submit',
  ];

  /// The ten owner-declared facilities. Rendered as compact chips, not a long
  /// list of full-width checkboxes.
  static const _facilityOptions = [
    'Grease trap',
    'Exhaust provision',
    'Three-phase power',
    'Water supply',
    'Food preparation area',
    'Dedicated drainage',
    'Parking available',
    'Ground floor frontage',
    'Loading access',
    'Accessible entrance',
  ];

  /// Required field keys per step.
  static const _required = <int, List<String>>{
    0: ['propertyName', 'propertyType', 'builtUp', 'monthlyRent'],
    1: ['address', 'city', 'state', 'postcode'],
    3: ['ownerRole'],
    4: [],
  };

  /// Human labels for cross-step validation messages.
  static const _labels = <String, String>{
    'propertyName': 'Property name',
    'propertyType': 'Property type',
    'builtUp': 'Floor area',
    'address': 'Street address',
    'latitude': 'Latitude',
    'longitude': 'Longitude',
    'city': 'City / township',
    'state': 'State',
    'postcode': 'Postcode',
    'monthlyRent': 'Monthly rent',
    'ownerRole': 'Relationship to the property',
    'confirm': 'Confirmation',
    'addressVerification': 'Address verification',
  };

  static const int _maxPhotos = 8;
  static const int _maxPhotoBytes = 8 * 1024 * 1024;
  static const _allowedPhotoTypes = <String>{
    'image/jpeg',
    'image/png',
    'image/webp',
  };

  bool get _isLast => _step == _steps.length - 1;

  void _set(String key, String value) => setState(() => _fields[key] = value);

  void _toggleFacility(String value) => setState(() {
    if (_facilities.contains(value)) {
      _facilities.remove(value);
    } else {
      _facilities.add(value);
    }
  });

  /// Only completed steps are re-openable, and never once the draft is saved:
  /// the persisted record would otherwise drift from the edited form.
  bool _canNavigateTo(int index) {
    if (_saved || _saving || _submitting) return false;
    return index < _step;
  }

  void _validate() {
    _errors.clear();
    final checkDetails = _step == 0 || _isLast;
    final checkLocation = _step == 1 || _isLast;

    if (checkDetails) {
      _putError(
        'propertyName',
        PropertyFormRules.titleError(_fields['propertyName']),
      );
      _putError(
        'propertyType',
        PropertyFormRules.propertyTypeError(_fields['propertyType']),
      );
      _putError(
        'monthlyRent',
        PropertyFormRules.rentError(_fields['monthlyRent']),
      );
      _putError('builtUp', PropertyFormRules.areaError(_fields['builtUp']));
    }
    if (checkLocation) {
      _putError('address', PropertyFormRules.addressError(_fields['address']));
      _putError('state', PropertyFormRules.stateError(_fields['state']));
      _putError(
        'city',
        PropertyFormRules.cityError(_fields['state'], _fields['city']),
      );
      _putError(
        'postcode',
        PropertyFormRules.postcodeError(
          _fields['postcode'],
          state: _fields['state'],
          city: _fields['city'],
        ),
      );
    }
    // On the final step, re-check every earlier step so navigating back and
    // clearing a field cannot produce an incomplete draft.
    if (_isLast) {
      for (final keys in _required.values) {
        for (final key in keys) {
          if ((_fields[key] ?? '').trim().isEmpty &&
              !_errors.containsKey(key)) {
            _errors[key] = 'This field is required.';
          }
        }
      }
      if (!_addressVerified) {
        _errors['addressVerification'] = AddressVerificationCopy.required;
      }
      if (!_confirm) {
        _errors['confirm'] = 'Please confirm the details before saving.';
      }
    }
  }

  void _putError(String key, String? message) {
    if (message != null) _errors[key] = message;
  }

  Future<void> _next() async {
    if (_saving || _saved) return;
    _validate();
    if (_errors.isNotEmpty) {
      setState(() {});
      return;
    }
    if (_isLast) {
      await _saveDraft();
    } else {
      setState(() => _step++);
    }
  }

  void _back() {
    if (_step > 0) setState(() => _step--);
  }

  // --------------------------------------------------- address verification

  AddressSnapshot _addressSnapshot() => AddressSnapshot(
    address: (_fields['address'] ?? '').trim(),
    city: (_fields['city'] ?? '').trim(),
    state: (_fields['state'] ?? '').trim(),
    postcode: (_fields['postcode'] ?? '').trim(),
    latitude: _verifiedLatitude,
    longitude: _verifiedLongitude,
  );

  /// Any edit to a location value invalidates the previous verdict: a verified
  /// address is bound to the exact values that were validated.
  void _invalidateAddress() {
    _addressRequestId++;
    _addressState = AddressVerificationState.unverified;
    _addressResult = null;
    _verifiedSnapshot = null;
    _addressMessage = null;
    _verifiedLatitude = null;
    _verifiedLongitude = null;
    _fields.remove('latitude');
    _fields.remove('longitude');
  }

  void _onLocationChanged(String key, String value) {
    setState(() {
      _fields[key] = value;
      if (key == 'state') {
        // A city/postcode from the previous state cannot stay selected.
        _fields.remove('city');
        _fields.remove('postcode');
      } else if (key == 'city') {
        _fields.remove('postcode');
      }
      _invalidateAddress();
      _errors.remove(key);
    });
  }

  /// Ask the backend (which holds the Google key) to validate the address.
  /// A verdict here never changes the listing's verification status.
  Future<void> _validateAddress() async {
    if (_addressState == AddressVerificationState.verifying) return;
    final snapshot = _addressSnapshot();
    if (snapshot.address.isEmpty) {
      setState(() {
        _errors['address'] =
            PropertyFormRules.addressError(snapshot.address) ??
            'Enter a street address first.';
      });
      return;
    }
    if (snapshot.state.isEmpty ||
        snapshot.city.isEmpty ||
        snapshot.postcode.isEmpty) {
      _validate();
      setState(() {});
      return;
    }
    final requestId = ++_addressRequestId;
    setState(() {
      _addressState = AddressVerificationState.verifying;
      _addressMessage = null;
      _errors.remove('addressVerification');
    });
    try {
      final result = await _repository.validateAddress(
        addressLines: [snapshot.address, snapshot.postcode],
        city: snapshot.city,
        state: snapshot.state,
        postcode: snapshot.postcode,
      );
      if (!mounted || requestId != _addressRequestId) return;
      if (_addressSnapshot() != snapshot) {
        // The owner edited the address while the request was in flight; a
        // late verdict must not mark the new address as verified.
        setState(() {
          _addressState = AddressVerificationState.unverified;
          _addressMessage = AddressVerificationCopy.stale;
        });
        return;
      }
      final (state, message) = switch (result.status) {
        'validated' => (
          AddressVerificationState.validatedPendingConfirmation,
          AddressVerificationCopy.validated,
        ),
        'partially_validated' => (
          AddressVerificationState.partiallyValidated,
          AddressVerificationCopy.partiallyValidated,
        ),
        _ => (
          AddressVerificationState.unconfirmed,
          AddressVerificationCopy.unconfirmed,
        ),
      };
      setState(() {
        _addressResult = result;
        _addressState = state;
        _addressMessage = message;
      });
    } catch (error) {
      if (!mounted || requestId != _addressRequestId) return;
      setState(() {
        _addressState = AddressVerificationState.serviceError;
        _addressMessage = _addressFailureCopy(_cleanError(error));
        _verifiedLatitude = null;
        _verifiedLongitude = null;
      });
    }
  }

  /// Distinguishes "provider unavailable" from "address rejected" so the owner
  /// is told which action to take. All values are preserved either way.
  String _addressFailureCopy(String message) {
    final lower = message.toLowerCase();
    if (lower.contains('temporarily unavailable') ||
        lower.contains('not enabled') ||
        lower.contains('not configured') ||
        lower.contains('503')) {
      return AddressVerificationCopy.unavailable;
    }
    if (lower.contains('rejected') ||
        lower.contains('422') ||
        lower.contains('invalid')) {
      return AddressVerificationCopy.invalidRequest;
    }
    return message.isEmpty ? AddressVerificationCopy.unavailable : message;
  }

  /// Explicit confirmation step: `validated` alone is not `verified`.
  void _confirmAddress() {
    final result = _addressResult;
    if (_addressState !=
            AddressVerificationState.validatedPendingConfirmation ||
        result == null ||
        !result.hasCoordinates) {
      return;
    }
    setState(() {
      // Coordinates first: the snapshot must describe the CONFIRMED values,
      // otherwise `_addressVerified` can never match afterwards.
      _verifiedLatitude = result.latitude;
      _verifiedLongitude = result.longitude;
      _addressState = AddressVerificationState.verified;
      _verifiedSnapshot = _addressSnapshot();
      _fields['latitude'] = result.latitude!.toStringAsFixed(6);
      _fields['longitude'] = result.longitude!.toStringAsFixed(6);
      _addressMessage =
          result.formattedAddress ?? AddressVerificationCopy.validated;
      _errors.remove('addressVerification');
    });
  }

  bool get _addressVerified =>
      _addressState == AddressVerificationState.verified &&
      _verifiedSnapshot == _addressSnapshot();

  /// Save the wizard as a DRAFT.
  ///
  /// Nothing is submitted to an administrator here. The draft is persisted
  /// first, then enrichment runs in two independent phases while the owner
  /// watches per-category progress. Submission is a separate, explicit action
  /// ([_submitToAdmin]) that the owner has to take after seeing the results.
  Future<void> _saveDraft() async {
    if (_saving || _saved) return;
    _validate();
    if (_errors.isNotEmpty) {
      setState(() {});
      return;
    }
    setState(() {
      _saving = true;
      _submitError = null;
    });
    try {
      final latitude = _verifiedLatitude;
      final longitude = _verifiedLongitude;
      if (latitude == null || longitude == null) {
        setState(() {
          _saving = false;
          _errors['addressVerification'] = AddressVerificationCopy.required;
        });
        return;
      }
      final result = await _repository.createOwnerDraft({
        'name': _fields['propertyName']!.trim(),
        'property_type': commercialPropertyTypeWire(
          (_fields['propertyType'] ?? '').trim(),
        ),
        'description': _optional('description'),
        'address': _fields['address']!.trim(),
        'city': _fields['city']!.trim(),
        'state': _fields['state']!.trim(),
        'postcode': _fields['postcode']!.trim(),
        // Coordinates come from the confirmed Google verdict, never from a
        // manually typed value. The backend re-validates the address and
        // replaces these with the provider's own coordinates.
        'latitude': latitude,
        'longitude': longitude,
        'rental_price': double.parse(_fields['monthlyRent']!.trim()),
        'size_sqft': double.parse(_fields['builtUp']!.trim()),
        'availability': _optional('availability'),
        'floor_level': _optional('floorLevel'),
        'has_parking': _facilities.any(
          (facility) => facility.toLowerCase().contains('parking'),
        ),
      });
      if (!mounted) return;
      setState(() {
        _result = result;
        _saved = true;
        _saving = false;
      });
      await _runEnrichment();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _submitError = _cleanError(error);
      });
    }
  }

  /// Run both enrichment phases, one after the other, publishing each result
  /// as soon as it settles.
  ///
  /// Phase 1 (PostGIS) is fast, so the owner sees the four location categories
  /// complete while Phase 2 (population raster work) is still running. A
  /// failure in either phase is recorded per phase and never discards the
  /// other one's results.
  Future<void> _runEnrichment() async {
    final propertyId = _result?.propertyId ?? 0;
    if (propertyId == 0 || _enriching) return;
    setState(() {
      _enriching = true;
      _enrichmentError = null;
    });

    try {
      final phaseOne = await _repository.enrichListing(
        propertyId,
        phase: EnrichmentPhase.postgis,
      );
      if (!mounted) return;
      setState(() => _enrichment = phaseOne);
    } catch (error) {
      if (!mounted) return;
      setState(() => _enrichmentError = _cleanError(error));
    }

    try {
      final phaseTwo = await _repository.enrichListing(
        propertyId,
        phase: EnrichmentPhase.population,
      );
      if (!mounted) return;
      setState(() => _enrichment = phaseTwo);
    } catch (error) {
      if (!mounted) return;
      setState(() => _enrichmentError = _cleanError(error));
    }

    if (!mounted) return;
    setState(() => _enriching = false);
  }

  /// Retry ONE category. The other four keep their stored values.
  Future<void> _retryCategory(EnrichmentCategory category) async {
    final propertyId = _result?.propertyId ?? 0;
    if (propertyId == 0 || _enriching) return;
    setState(() {
      _enriching = true;
      _enrichmentError = null;
    });
    try {
      final summary = await _repository.retryEnrichment(propertyId, category);
      if (!mounted) return;
      setState(() => _enrichment = summary);
    } catch (error) {
      if (!mounted) return;
      setState(() => _enrichmentError = _cleanError(error));
    }
    if (!mounted) return;
    setState(() => _enriching = false);
  }

  /// The explicit "Submit to Admin" action.
  ///
  /// Refused while a category is still calculating (the reviewer would see
  /// unsettled figures) and refused without an acknowledgement when population
  /// could not be measured — population is never estimated, so the gap has to
  /// be accepted rather than silently shipped to the reviewer.
  Future<void> _submitToAdmin() async {
    final propertyId = _result?.propertyId ?? 0;
    if (propertyId == 0 || _submitting || _submitted) return;

    final summary = _enrichment;
    if (summary != null && summary.isRunning) {
      setState(() {
        _enqueueError = 'Enrichment is still running. Wait for it to finish.';
      });
      return;
    }
    if ((summary?.populationUnavailable ?? false) && !_ackPopulation) {
      setState(() {
        _enqueueError =
            'Population could not be measured for these coordinates. '
            'Confirm that you want to submit without a population figure.';
      });
      return;
    }

    setState(() {
      _submitting = true;
      _enqueueError = null;
    });
    try {
      await AppLocator.propertyVerificationRepo.submit(
        '$propertyId',
        scope: 'listing',
        acknowledgeUnavailablePopulation: _ackPopulation,
      );
      if (!mounted) return;
      setState(() {
        _submitted = true;
        _submitting = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _enqueueError = _cleanError(error);
      });
    }
  }

  String? _optional(String key) {
    final value = (_fields[key] ?? '').trim();
    return value.isEmpty ? null : value;
  }

  /// Strips the bridge's `Exception: ` prefixes so the backend's own sentence
  /// is what the owner reads.
  static String _cleanError(Object error) {
    var raw = error.toString();
    raw = raw.replaceFirst(
      RegExp(r'^((Bad state|Exception|Error|StateError)(\([^)]*\))?):\s*'),
      '',
    );
    final trimmed = raw.trim();
    return trimmed.isEmpty ? 'The submission could not be completed.' : trimmed;
  }

  @override
  void dispose() {
    for (final photo in _photos) {
      web.URL.revokeObjectURL(photo.url);
    }
    _photos.clear();
    super.dispose();
  }

  // ------------------------------------------------------------------- shell

  @override
  Component build(BuildContext context) {
    return AppLayout(
      role: AppRole.entrepreneur,
      currentRoute: '/entrepreneur/add-property',
      title: 'Add property',
      // The page renders its own compact heading; the global PageHead would
      // add a second, oversized one.
      showPageHead: false,
      // The global trail duplicates the step indicator on a single-form page.
      showBreadcrumbs: false,
      child: div(classes: 'sw-reg', [
        // One 720px column for heading, steps and form. Aligning all three to
        // the same measure is what makes the page read as a single organised
        // form rather than a full-width banner above a floating card.
        div(classes: 'sw-reg-shell', [
          header(classes: 'sw-reg-head', [
            h1([Component.text('Add a commercial property')]),
            p([
              Component.text(
                _saved
                    ? 'Draft saved. Review the location analysis, then submit it '
                          'for administrator review.'
                    : 'Five short steps. Your listing is stored as a draft and is '
                          'not sent for review until you submit it.',
              ),
            ]),
          ]),
          _stepper(),
          div(classes: 'sw-reg-card', [
            _cardHead(),
            _errorSummary(),
            _submitErrorNotice(),
            div(classes: 'sw-reg-body', [
              if (_step == 0) _stepDetails(),
              if (_step == 1) _stepLocation(),
              if (_step == 2) _stepReadiness(),
              if (_step == 3) _stepProof(),
              if (_step == 4) _stepReview(),
            ]),
            _footer(),
          ]),
        ]),
      ]),
    );
  }

  /// Compact horizontal step indicator. Completed steps remain clickable so
  /// entered values can be edited without losing the rest of the draft.
  Component _stepper() => nav(
    classes: 'sw-reg-stepper',
    attributes: const {'aria-label': 'Add property steps'},
    [
      for (var i = 0; i < _steps.length; i++)
        button(
          classes:
              'sw-reg-step'
              '${i == _step ? ' is-active' : ''}'
              '${i < _step ? ' is-done' : ''}',
          attributes: {
            'type': 'button',
            'aria-current': i == _step ? 'step' : 'false',
            'aria-label': 'Step ${i + 1}: ${_stepTitles[i]}',
            if (!_canNavigateTo(i)) 'disabled': '',
          },
          events: events(
            onClick: _canNavigateTo(i) ? () => setState(() => _step = i) : null,
          ),
          [
            span(
              classes: 'sw-reg-step-index',
              attributes: const {'aria-hidden': 'true'},
              [Component.text(i < _step ? '✓' : '${i + 1}')],
            ),
            span(classes: 'sw-reg-step-label', [
              Component.text(_steps[i]),
            ]),
          ],
        ),
    ],
  );

  Component _cardHead() => div(classes: 'sw-reg-card-head', [
    span(classes: 'sw-reg-step-kicker', [
      Component.text(
        _saved ? 'Final step' : 'Step ${_step + 1} of ${_steps.length}',
      ),
    ]),
    h2([Component.text(_stepTitles[_step])]),
  ]);

  // ------------------------------------------------------------ field helpers

  Component _field({
    required String key,
    required String label,
    bool required = false,
    String? hint,
    String type = 'text',
    List<String>? options,
    bool isTextarea = false,
    bool wide = false,
    int rows = 3,
    void Function(String)? onChanged,
  }) {
    final err = _errors[key];
    final value = _fields[key] ?? '';
    final field = switch (type) {
      'select' => select(
        attributes: {
          'id': key,
          'name': key,
          if (required) 'required': '',
          if (err != null) 'aria-invalid': 'true',
          if (err != null) 'aria-describedby': '$key-error',
        },
        events: events<List<String>>(
          onInput: (v) => _set(key, v.isEmpty ? '' : v.first),
        ),
        [
          option(value: '', [Component.text('Select…')]),
          for (final opt in options ?? const [])
            option(
              value: opt,
              attributes: value == opt ? {'selected': ''} : null,
              [Component.text(opt)],
            ),
        ],
      ),
      _ when isTextarea => textarea(
        attributes: {
          'id': key,
          'name': key,
          'rows': '$rows',
          'placeholder': hint ?? '',
          if (required) 'required': '',
          if (err != null) 'aria-invalid': 'true',
          if (err != null) 'aria-describedby': '$key-error',
        },
        events: events<String>(onInput: (v) => _set(key, v)),
        [Component.text(value)],
      ),
      _ => input(
        attributes: {
          'id': key,
          'name': key,
          'type': type,
          'value': value,
          // Keep the value non-nullable so the map stays Map<String,String>;
          // a `hint?` null-aware entry would widen it to Map<String,String?>
          // and fail the `attributes` parameter type.
          // ignore: use_null_aware_elements
          if (hint != null) 'placeholder': hint,
          if (required) 'required': '',
          if (err != null) 'aria-invalid': 'true',
          if (err != null) 'aria-describedby': '$key-error',
        },
        // Jaspr delivers `num` (valueAsNumber) for type=number controls and
        // `String` for everything else. Subscribing a number input as
        // `events<String>` throws at runtime, so rent/area never reached
        // state. See jaspr/src/dom/events.dart.
        events: type == 'number'
            ? events<num>(onInput: (v) => _set(key, _numberText(v)))
            : events<String>(onInput: onChanged ?? (v) => _set(key, v)),
      ),
    };

    return div(classes: wide ? 'sw-field sw-field--wide' : 'sw-field', [
      // A real <label for> (not a <span>) so assistive technology and
      // click-to-focus work on every field. `Component.element` is used
      // because the `_field(..., label: ...)` parameter shadows Jaspr's
      // top-level `label()` helper.
      Component.element(
        tag: 'label',
        classes: 'sw-field-label',
        attributes: {'for': key},
        children: [
          Component.text(label),
          if (required)
            Component.element(
              tag: 'em',
              attributes: const {'aria-hidden': 'true'},
              children: [Component.text(' *')],
            ),
        ],
      ),
      field,
      if (err != null) _fieldError(key, err),
    ]);
  }

  Component _fieldError(String key, String err) => span(
    classes: 'sw-field-error',
    attributes: {'id': '$key-error', 'role': 'alert'},
    [Component.text(err)],
  );

  /// `valueAsNumber` is a double in JS; keep integer-looking values readable.
  static String _numberText(num value) =>
      value % 1 == 0 ? value.toInt().toString() : value.toString();

  // --------------------------------------------------------------- step: details

  /// Two-column grouping: identity first, then the commercial terms, then the
  /// free-text description. Name and description span the full width because
  /// they are the only fields whose content is unbounded.
  Component _stepDetails() => div(classes: 'sw-fields', [
    _field(
      key: 'propertyName',
      label: 'Property name',
      required: true,
      wide: true,
      hint: 'e.g. Ground floor corner shoplot at SS15',
    ),
    _field(
      key: 'propertyType',
      label: 'Property type',
      required: true,
      type: 'select',
      options: commercialPropertyTypeLabels,
    ),
    _field(
      key: 'floorLevel',
      label: 'Floor level',
      type: 'select',
      options: const [
        'Ground floor',
        'Basement',
        'First floor',
        'Second floor',
        'Third floor or above',
        'Multiple levels',
      ],
    ),
    _field(
      key: 'monthlyRent',
      label: 'Monthly rental (RM)',
      required: true,
      type: 'number',
      hint: '7800',
    ),
    _field(
      key: 'builtUp',
      label: 'Floor area (sq ft)',
      required: true,
      type: 'number',
      hint: '1680',
    ),
    _field(
      key: 'premiseStatus',
      label: 'Premises status',
      type: 'select',
      options: const [
        'Vacant',
        'Owner occupied',
        'Tenant occupied',
        'Under renovation',
      ],
    ),
    _field(
      key: 'availability',
      label: 'Availability',
      type: 'select',
      options: const [
        'Available now',
        'Within 30 days',
        'Within 60 days',
        'Within 90 days',
        'Contact for availability',
      ],
    ),
    _field(
      key: 'description',
      label: 'Description',
      isTextarea: true,
      wide: true,
      rows: 3,
      hint: 'Frontage, layout, access and premises features (optional)…',
    ),
    p(classes: 'sw-reg-note sw-field--wide', [
      Component.text(
        'F&B commercial premises only. Name, type, rent and floor area are '
        're-validated by the server.',
      ),
    ]),
  ]);

  // --------------------------------------------------------------- step: location

  /// State is a fixed list of the 16 states/federal territories.
  Component _stateField() {
    final err = _errors['state'];
    final value = _fields['state'] ?? '';
    return div(classes: 'sw-field', [
      Component.element(
        tag: 'label',
        classes: 'sw-field-label',
        attributes: const {'for': 'state'},
        children: [
          Component.text('State'),
          Component.element(
            tag: 'em',
            attributes: const {'aria-hidden': 'true'},
            children: [Component.text(' *')],
          ),
        ],
      ),
      select(
        attributes: {
          'id': 'state',
          'name': 'state',
          'required': '',
          if (err != null) 'aria-invalid': 'true',
          if (err != null) 'aria-describedby': 'state-error',
        },
        events: events<List<String>>(
          onInput: (v) => _onLocationChanged('state', v.isEmpty ? '' : v.first),
        ),
        [
          option(value: '', [Component.text('Select a state…')]),
          for (final name in MalaysiaLocations.stateNames)
            option(
              value: name,
              attributes: value == name ? {'selected': ''} : null,
              [Component.text(name)],
            ),
        ],
      ),
      if (err != null) _fieldError('state', err),
    ]);
  }

  /// Searchable city/postcode input backed by a native `<datalist>`: typing
  /// filters the options, while the value is validated against the same
  /// dataset the options come from.
  Component _locationTextField({
    required String key,
    required String label,
    required List<String> options,
    required bool enabled,
    String? hint,
    bool required = false,
  }) {
    final err = _errors[key];
    final value = _fields[key] ?? '';
    final listId = 'sw-$key-options';
    return div(classes: 'sw-field', [
      Component.element(
        tag: 'label',
        classes: 'sw-field-label',
        attributes: {'for': key},
        children: [
          Component.text(label),
          if (required)
            Component.element(
              tag: 'em',
              attributes: const {'aria-hidden': 'true'},
              children: [Component.text(' *')],
            ),
        ],
      ),
      input(
        attributes: {
          'id': key,
          'name': key,
          'list': listId,
          'value': value,
          'autocomplete': 'off',
          'placeholder':
              hint ??
              (enabled ? 'Start typing to search…' : 'Select the state first'),
          if (!enabled) 'disabled': '',
          if (required) 'required': '',
          if (err != null) 'aria-invalid': 'true',
          if (err != null) 'aria-describedby': '$key-error',
        },
        events: events<String>(onInput: (v) => _onLocationChanged(key, v)),
      ),
      Component.element(
        tag: 'datalist',
        attributes: {'id': listId},
        children: [
          for (final optionValue in options)
            option(value: optionValue, const []),
        ],
      ),
      if (err != null) _fieldError(key, err),
    ]);
  }

  String _addressStateLabel(AddressVerificationState state) => switch (state) {
    AddressVerificationState.unverified => 'NOT CHECKED',
    AddressVerificationState.verifying => 'CHECKING',
    AddressVerificationState.validatedPendingConfirmation => 'CONFIRM',
    AddressVerificationState.verified => 'VERIFIED',
    AddressVerificationState.partiallyValidated => 'CORRECTION',
    AddressVerificationState.unconfirmed => 'CORRECTION',
    AddressVerificationState.serviceError => 'UNAVAILABLE',
  };

  static String _addressTone(AddressVerificationState state) =>
      switch (state) {
        AddressVerificationState.verified => 'success',
        AddressVerificationState.validatedPendingConfirmation => 'action',
        AddressVerificationState.partiallyValidated ||
        AddressVerificationState.unconfirmed => 'warning',
        AddressVerificationState.serviceError => 'danger',
        _ => 'neutral',
      };

  /// The "location verification" half of the postcode row: a single button in
  /// the adjacent grid cell, aligned with the input. The verdict itself is a
  /// one-line status strip underneath rather than a full panel.
  Component _verifyCell() {
    final busy = _addressState == AddressVerificationState.verifying;
    final verified = _addressVerified;
    return div(classes: 'sw-field sw-field--action', [
      span(classes: 'sw-field-label', [Component.text('Location check')]),
      button(
        classes: 'sw-btn sw-btn-check${verified ? ' is-ok' : ''}',
        attributes: {
          'type': 'button',
          if (busy) 'disabled': '',
          'aria-busy': busy ? 'true' : 'false',
        },
        events: events(onClick: busy ? null : _validateAddress),
        [
          Component.text(
            busy
                ? 'Checking…'
                : (verified ? 'Checked' : 'Verify address'),
          ),
        ],
      ),
    ]);
  }

  /// Compact verdict strip. The normalized address and coordinates are shown
  /// as read-only facts only once the provider actually returned them.
  Component _addressStatusLine() {
    final state = _addressState;
    final result = _addressResult;
    final coords = _verifiedLatitude != null && _verifiedLongitude != null;
    return div([
      div(classes: 'sw-addr-line', [
        StatusBadge(_addressStateLabel(state), tone: _addressTone(state)),
        span(classes: 'sw-addr-line__copy', [
          Component.text(
            _addressMessage ??
                'The address is confirmed with the location provider before '
                    'the draft can be saved.',
          ),
        ]),
        if (state == AddressVerificationState.validatedPendingConfirmation)
          button(
            classes: 'sw-btn sw-btn-check sw-btn-check--primary',
            attributes: const {'type': 'button'},
            events: events(onClick: _confirmAddress),
            [Component.text('Confirm address')],
          ),
      ]),
      if (result != null &&
          (result.formattedAddress ?? '').isNotEmpty)
        p(classes: 'sw-reg-coords', [
          Component.text('Normalized: ${result.formattedAddress}'),
        ]),
      if (coords)
        p(classes: 'sw-reg-coords', [
          Component.text(
            'Verified coordinates: '
            '${_verifiedLatitude!.toStringAsFixed(6)}, '
            '${_verifiedLongitude!.toStringAsFixed(6)}',
          ),
        ]),
      if (_errors['addressVerification'] != null)
        _fieldError('addressVerification', _errors['addressVerification']!),
    ]);
  }

  Component _stepLocation() => div([
    div(classes: 'sw-fields', [
      _stateField(),
      _locationTextField(
        key: 'city',
        label: 'City / township',
        options: MalaysiaLocations.citiesFor(_fields['state']),
        enabled: (_fields['state'] ?? '').isNotEmpty,
        required: true,
      ),
      _field(
        key: 'address',
        label: 'Street address',
        required: true,
        wide: true,
        hint: 'e.g. No. 12, Jalan SS 15/4',
        onChanged: (v) => _onLocationChanged('address', v),
      ),
      _locationTextField(
        key: 'postcode',
        label: 'Postcode',
        options: MalaysiaLocations.postcodesFor(
          _fields['state'],
          _fields['city'],
        ),
        enabled: (_fields['city'] ?? '').isNotEmpty,
        required: true,
        hint: '47500',
      ),
      _verifyCell(),
    ]),
    _addressStatusLine(),
    p(classes: 'sw-reg-note', [
      Component.text(
        'Editing the address clears the previous check. The provider confirms '
        'the address only — it never verifies ownership.',
      ),
    ]),
  ]);

  // --------------------------------------------------------------- step: readiness

  /// Facilities as compact toggle chips; the operational selects follow in the
  /// same two-column grid as every other step.
  Component _stepReadiness() => div([
    div(classes: 'sw-facilities', [
      for (final f in _facilityOptions)
        button(
          classes: _facilities.contains(f)
              ? 'sw-facility sw-facility--on'
              : 'sw-facility',
          attributes: {
            'type': 'button',
            'aria-pressed': _facilities.contains(f) ? 'true' : 'false',
          },
          events: events(onClick: () => _toggleFacility(f)),
          [
            if (_facilities.contains(f))
              span(
                classes: 'sw-facility__tick',
                attributes: const {'aria-hidden': 'true'},
                [Component.text('✓')],
              ),
            Component.text(f),
          ],
        ),
    ]),
    div(classes: 'sw-fields', [
      _field(
        key: 'fbApproval',
        label: 'F&B use approval',
        type: 'select',
        options: const [
          'Not confirmed',
          'Documented approval',
          'Approval pending',
          'Not approved for F&B',
        ],
      ),
      _field(
        key: 'electricity',
        label: 'Electricity',
        type: 'select',
        options: const [
          'Not confirmed',
          'Single-phase',
          'Three-phase',
          'Other / assess on-site',
        ],
      ),
      _field(
        key: 'readinessNotes',
        label: 'Readiness notes',
        wide: true,
        isTextarea: true,
        rows: 2,
        hint: 'Ventilation, utilities, equipment restrictions…',
      ),
    ]),
    p(classes: 'sw-reg-note', [
      Component.text(
        'Facilities are owner-declared and are not independently inspected.',
      ),
    ]),
  ]);

  // --------------------------------------------------------------- step: proof

  Component _stepProof() => div([
    label(
      classes: 'sw-upload',
      attributes: const {'for': 'swRegPhotoInput'},
      [
        span(
          classes: 'sw-upload-icon',
          attributes: const {'aria-hidden': 'true'},
          [Component.text('+')],
        ),
        span([
          strong([Component.text('Add photographs')]),
          small([
            Component.text(
              'JPG, PNG or WebP · 8 MB max · ${_photos.length}/$_maxPhotos '
              'selected',
            ),
          ]),
        ]),
      ],
    ),
    input(
      classes: 'sw-upload-input',
      attributes: const {
        'id': 'swRegPhotoInput',
        'type': 'file',
        'accept': 'image/jpeg,image/png,image/webp',
        'multiple': '',
      },
      events: events<List<web.File>>(onChange: _onPhotosSelected),
    ),
    if (_photoError != null)
      p(
        classes: 'sw-photo-error',
        attributes: const {'role': 'alert'},
        [Component.text(_photoError!)],
      ),
    if (_photos.isNotEmpty)
      div(classes: 'sw-photo-grid', [
        for (var i = 0; i < _photos.length; i++)
          div(classes: 'sw-photo-item', [
            Component.element(
              tag: 'img',
              attributes: {
                'src': _photos[i].url,
                'alt': 'Selected photo: ${_photos[i].name}',
              },
              children: const [],
            ),
            button(
              classes: 'sw-photo-remove',
              attributes: {
                'type': 'button',
                'aria-label': 'Remove ${_photos[i].name}',
              },
              events: events(onClick: () => _removePhoto(i)),
              [Component.text('×')],
            ),
          ]),
      ]),
    div(classes: 'sw-fields sw-fields--spaced', [
      _field(
        key: 'ownerRole',
        label: 'Your relationship to the property',
        required: true,
        type: 'select',
        options: const [
          'Registered owner',
          'Authorized representative',
          'Property manager',
          'Registered real estate agent',
          'Tenant with authorization',
        ],
      ),
      _field(
        key: 'contactEmail',
        label: 'Contact email',
        type: 'email',
        hint: 'name@example.com',
      ),
    ]),
    p(classes: 'sw-reg-note', [
      Component.text(
        'Photographs are previewed in this browser only. No upload service is '
        'connected, so they are never transmitted or attached to the record.',
      ),
    ]),
  ]);

  // ------------------------------------------------------------ photo handling

  /// Applies the existing file-input contract (JPG/PNG/WebP, 8 MB, 8 files)
  /// and creates browser object URLs for local previews. No upload is attempted.
  void _onPhotosSelected(List<web.File> files) {
    String? error;
    final accepted = <web.File>[];
    for (final file in files) {
      if (!_allowedPhotoTypes.contains(file.type)) {
        error = 'Only JPG, PNG or WebP images are supported.';
        continue;
      }
      if (file.size > _maxPhotoBytes) {
        error = 'Each photograph must be 8 MB or smaller.';
        continue;
      }
      accepted.add(file);
    }
    final room = _maxPhotos - _photos.length;
    if (accepted.length > room) {
      error = 'A listing can hold up to $_maxPhotos photographs.';
      accepted.removeRange(room < 0 ? 0 : room, accepted.length);
    }
    setState(() {
      _photoError = error;
      for (final file in accepted) {
        _photos.add(
          _SelectedPhoto(
            name: file.name,
            sizeLabel: _sizeLabel(file.size),
            url: web.URL.createObjectURL(file),
          ),
        );
      }
    });
  }

  void _removePhoto(int index) {
    if (index < 0 || index >= _photos.length) return;
    setState(() {
      web.URL.revokeObjectURL(_photos[index].url);
      _photos.removeAt(index);
      _photoError = null;
    });
  }

  static String _sizeLabel(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024).round()} KB';
  }

  // --------------------------------------------------------------- step: review

  Component _stepReview() {
    if (_saved) return _analysisStep();
    return div([
      _reviewSection('Property details', 0, [
        _reviewRow('Property name', _fields['propertyName']),
        _reviewRow('Property type', _fields['propertyType']),
        _reviewRow('Floor level', _fields['floorLevel']),
        _reviewRow(
          'Monthly rental',
          (_fields['monthlyRent'] ?? '').isEmpty
              ? null
              : 'RM ${_fields['monthlyRent']}',
        ),
        _reviewRow(
          'Floor area',
          (_fields['builtUp'] ?? '').isEmpty
              ? null
              : '${_fields['builtUp']} sq ft',
        ),
        _reviewRow('Premises status', _fields['premiseStatus']),
      ]),
      _reviewSection('Location & pricing', 1, [
        _reviewRow('Street address', _fields['address']),
        _reviewRow('City / township', _fields['city']),
        _reviewRow('State', _fields['state']),
        _reviewRow('Postcode', _fields['postcode']),
        _reviewRow('Availability', _fields['availability']),
        _reviewRow(
          'Address check',
          _addressVerified
              ? 'Verified'
              : _addressStateLabel(_addressState),
        ),
      ]),
      _reviewSection('F&B readiness', 2, [
        _reviewRow('Facilities', '${_facilities.length} selected'),
        _reviewRow('F&B approval', _fields['fbApproval']),
        _reviewRow('Electricity', _fields['electricity']),
      ]),
      _reviewSection('Photos & authorization', 3, [
        _reviewRow(
          'Photographs',
          '${_photos.length} selected (preview only)',
        ),
        _reviewRow('Relationship', _fields['ownerRole']),
        _reviewRow('Contact email', _fields['contactEmail']),
      ]),
      if (_errors['addressVerification'] != null)
        _fieldError('addressVerification', _errors['addressVerification']!),
      label(classes: _confirm ? 'sw-confirm sw-confirm--on' : 'sw-confirm', [
        button(
          classes: _confirm
              ? 'sw-confirm-box sw-confirm-box--on'
              : 'sw-confirm-box',
          attributes: {
            'type': 'button',
            'role': 'checkbox',
            'aria-checked': _confirm ? 'true' : 'false',
          },
          events: events(onClick: () => setState(() => _confirm = !_confirm)),
          [Icon(_confirm ? 'check' : 'check_box_outline_blank', size: 'sm')],
        ),
        span([
          Component.text(
            'I confirm these details are accurate to the best of my knowledge. '
            'Saving a draft does not verify ownership, authorise F&B use or '
            'publish a listing.',
          ),
        ]),
      ]),
      if (_errors['confirm'] != null)
        _fieldError('confirm', _errors['confirm']!),
    ]);
  }

  Component _reviewSection(String heading, int step, List<Component> rows) =>
      div(classes: 'sw-review-section', [
        div(classes: 'sw-review-head', [
          h3([Component.text(heading)]),
          button(
            classes: 'sw-edit',
            attributes: {'type': 'button'},
            events: events(onClick: () => setState(() => _step = step)),
            [Component.text('Edit')],
          ),
        ]),
        dl(classes: 'sw-review-list', rows),
      ]);

  Component _reviewRow(String label, String? value) => div([
    dt([Component.text(label)]),
    dd([Component.text((value ?? '').isEmpty ? '—' : value!)]),
  ]);

  Component _errorSummary() => _errors.isEmpty
      ? span([])
      : div(
          classes: 'sw-error-summary',
          attributes: const {'role': 'alert'},
          [
            strong([
              Component.text('Please correct the highlighted information'),
            ]),
            ul([
              for (final e in _errors.entries)
                li([Component.text('${_labels[e.key] ?? e.key}: ${e.value}')]),
            ]),
          ],
        );

  /// Backend rejection notice. The server's own sentence is shown; nothing
  /// is retried automatically and the form stays editable.
  Component _submitErrorNotice() => _submitError == null
      ? const Component.fragment([])
      : div(
          classes: 'sw-reg-error',
          attributes: const {'role': 'alert'},
          [
            strong([Component.text('Submission not accepted')]),
            p([Component.text(_submitError!)]),
          ],
        );

  // ------------------------------------------------------- geospatial analysis

  /// Formats a measured value, or labels its absence.
  ///
  /// A missing value is NEVER printed as `0`: the reader cannot tell a
  /// measured zero from missing data otherwise, and this product does not
  /// invent figures.
  static String _measured(num? value, {int decimals = 0, String unit = ''}) {
    if (value == null) return 'Not available';
    final text = value.toStringAsFixed(decimals);
    return unit.isEmpty ? text : '$text$unit';
  }

  static String _statusTone(EnrichmentStatus status) => switch (status) {
    EnrichmentStatus.current => 'success',
    EnrichmentStatus.unavailable => 'warning',
    EnrichmentStatus.failed => 'danger',
    EnrichmentStatus.running => 'action',
    EnrichmentStatus.stale => 'warning',
    EnrichmentStatus.pending => 'neutral',
  };

  /// The five categories in the order the wizard presents them: population
  /// first (it is the one that can be genuinely unavailable), then the four
  /// PostGIS categories.
  static const _analysisOrder = <(String, EnrichmentCategory)>[
    ('Population', EnrichmentCategory.population),
    ('F&B competitors', EnrichmentCategory.fnbCompetitors),
    ('Nearby places', EnrichmentCategory.demandGenerators),
    ('Transportation', EnrichmentCategory.roadsTransport),
    ('Parking', EnrichmentCategory.parking),
  ];

  /// One line per category: enough to judge the location, short enough to keep
  /// the wizard compact.
  String _summaryLine(
    EnrichmentCategory category,
    EnrichmentCategoryState state,
  ) {
    if (!state.status.hasMeasurement) return '';
    switch (category) {
      case EnrichmentCategory.population:
        return '500 m ${_measured(state.number('population_500m'))} · '
            '1 km ${_measured(state.number('population_1km'))}';
      case EnrichmentCategory.fnbCompetitors:
        return '500 m ${_measured(state.number('competitor_count_500m'))} · '
            '1 km ${_measured(state.number('competitor_count_1km'))}';
      case EnrichmentCategory.demandGenerators:
        return '500 m '
            '${_measured(state.number('demand_generator_count_500m'))} · '
            '1 km ${_measured(state.number('demand_generator_count_1km'))}';
      case EnrichmentCategory.roadsTransport:
        return 'Roads '
            '${_measured(state.number('accessibility_road_km_1km'), decimals: 1, unit: ' km')} · '
            'nearest ${_measured(state.number('nearest_major_road_m'), unit: ' m')}';
      case EnrichmentCategory.parking:
        return '500 m ${_measured(state.number('parking_facilities_500m'))} · '
            'nearest ${_measured(state.number('nearest_parking_m'), unit: ' m')}';
    }
  }

  /// The full measurement breakdown, revealed only when a category is expanded.
  List<(String, String)> _measurementPairs(
    EnrichmentCategory category,
    EnrichmentCategoryState state,
  ) {
    if (!state.status.hasMeasurement) return const [];
    switch (category) {
      case EnrichmentCategory.population:
        final source = state.provenance?['source'];
        final missing = state.unavailableRadii;
        return [
          ('Within 500 m', _measured(state.number('population_500m'))),
          ('Within 1 km', _measured(state.number('population_1km'))),
          if (source is String && source.isNotEmpty) ('Source', source),
          if (missing.isNotEmpty) ('No raster coverage', missing.join(', ')),
        ];
      case EnrichmentCategory.fnbCompetitors:
        return [
          ('Within 500 m', _measured(state.number('competitor_count_500m'))),
          ('Within 1 km', _measured(state.number('competitor_count_1km'))),
        ];
      case EnrichmentCategory.demandGenerators:
        return [
          (
            'Within 500 m',
            _measured(state.number('demand_generator_count_500m')),
          ),
          (
            'Within 1 km',
            _measured(state.number('demand_generator_count_1km')),
          ),
        ];
      case EnrichmentCategory.roadsTransport:
        return [
          (
            'Road length within 1 km',
            _measured(
              state.number('accessibility_road_km_1km'),
              decimals: 1,
              unit: ' km',
            ),
          ),
          (
            'Nearest major road',
            _measured(state.number('nearest_major_road_m'), unit: ' m'),
          ),
          (
            'Transit stops within 500 m',
            _measured(state.number('transit_stops_500m')),
          ),
          (
            'Transit stops within 1 km',
            _measured(state.number('transit_stops_1km')),
          ),
        ];
      case EnrichmentCategory.parking:
        return [
          (
            'Within 500 m',
            _measured(state.number('parking_facilities_500m')),
          ),
          ('Within 1 km', _measured(state.number('parking_facilities_1km'))),
          ('Nearest facility', _measured(state.number('nearest_parking_m'), unit: ' m')),
        ];
    }
  }

  /// Compact five-row analysis. A row expands only on request — the full
  /// analytical dashboard belongs on the Property Detail page, not here.
  Component _analysisSection(PropertyEnrichmentSummary? summary) {
    return section(classes: 'sw-analysis', [
      div(classes: 'sw-analysis__head', [
        h3([Component.text('Location analysis')]),
        if (_enriching || (summary?.isRunning ?? false))
          span(classes: 'sw-analysis__live', [
            Component.text('Calculating…'),
          ]),
      ]),
      for (final (label, category) in _analysisOrder)
        _analysisRow(label, category, summary?.state(category)),
      if (_enrichmentError != null)
        p(classes: 'sw-enrich-error', [Component.text(_enrichmentError!)]),
      p(classes: 'sw-reg-note', [
        Component.text(
          'Measured from SiteWise PostGIS data and the population raster. A '
          'category with no data is labelled “Not available”, never zero.',
        ),
      ]),
    ]);
  }

  Component _analysisRow(
    String label,
    EnrichmentCategory category,
    EnrichmentCategoryState? state,
  ) {
    final status = state?.status ?? EnrichmentStatus.pending;
    final tone = _statusTone(status);
    final pairs = state == null
        ? const <(String, String)>[]
        : _measurementPairs(category, state);
    final line = state == null ? '' : _summaryLine(category, state);
    final reason = state?.reason ?? '';
    final text = line.isNotEmpty ? line : (reason.isNotEmpty ? reason : '—');

    final badge = span(classes: 'sw-analysis__badge', [
      StatusBadge(status.label, tone: tone),
    ]);

    final header = [
      span(classes: 'sw-analysis__label', [Component.text(label)]),
      span(classes: 'sw-analysis__value', [Component.text(text)]),
      badge,
      span(
        classes: 'sw-analysis__chev',
        attributes: const {'aria-hidden': 'true'},
        [Component.text('▾')],
      ),
    ];

    final body = <Component>[
      if (pairs.isNotEmpty)
        dl(classes: 'sw-analysis__detail', [
          for (final (k, v) in pairs)
            div([dt([Component.text(k)]), dd([Component.text(v)])]),
        ]),
      if (state != null && status.retryable && !_enriching)
        div(classes: 'sw-analysis__actions', [
          button(
            classes: 'sw-enrich-retry',
            attributes: const {'type': 'button'},
            events: events(onClick: () => _retryCategory(category)),
            [Component.text('Retry')],
          ),
        ]),
    ];

    // A settled category with nothing to expand renders as a plain row: an
    // empty <details> would invite a click that reveals nothing.
    if (body.isEmpty) {
      return div(classes: 'sw-analysis__row', [
        div(classes: 'sw-analysis__summary is-static', header),
      ]);
    }
    return Component.element(
      tag: 'details',
      classes: 'sw-analysis__row',
      children: [
        Component.element(
          tag: 'summary',
          classes: 'sw-analysis__summary',
          children: header,
        ),
        ...body,
      ],
    );
  }

  Component _draftLine() {
    final r = _result;
    return div(classes: 'sw-draft-line', [
      StatusBadge(
        _submitted ? 'Submitted' : 'Draft',
        tone: _submitted ? 'success' : 'neutral',
      ),
      span([
        Component.text(
          r == null
              ? 'The draft was accepted by the server.'
              : '“${r.name}” · #${r.propertyId} · '
                    '${r.isPublished ? 'published' : 'not published'}',
        ),
      ]),
    ]);
  }

  /// The acknowledgement + honesty notice that sits directly above the footer
  /// actions. The submit button itself lives in the footer.
  Component _submitNotice(PropertyEnrichmentSummary? summary) {
    if (_submitted) {
      return div(classes: 'sw-notice sw-notice--ok', [
        strong([Component.text('In the review queue')]),
        p([
          Component.text(
            'The listing information is with an administrator. Ownership '
            'documents were not part of this submission, so publishing still '
            'needs a separate ownership check.',
          ),
        ]),
      ]);
    }

    final populationUnavailable = summary?.populationUnavailable ?? false;
    return div(classes: 'sw-notice', [
      strong([Component.text('Submit to Admin')]),
      p([
        Component.text(
          'Nothing is sent for review until you press Submit to Admin.',
        ),
      ]),
      if (populationUnavailable)
        div(classes: 'sw-enrich-ack', [
          p([
            Component.text(
              'Population could not be measured for these coordinates. No '
              'estimate is substituted, so the administrator will see “Not '
              'available”. Confirm that you want to submit anyway.',
            ),
          ]),
          label(
            classes: 'sw-enrich-ack__check',
            attributes: const {'for': 'ack-population'},
            [
              input(
                attributes: {
                  'type': 'checkbox',
                  'id': 'ack-population',
                  if (_ackPopulation) 'checked': '',
                },
                events: events(onClick: () {
                  setState(() => _ackPopulation = !_ackPopulation);
                }),
              ),
              span([
                Component.text(
                  'I understand population is unavailable for this property.',
                ),
              ]),
            ],
          ),
        ]),
      if (_enqueueError != null)
        p(classes: 'sw-enrich-error', [Component.text(_enqueueError!)]),
    ]);
  }

  /// The saved half of the final step: draft identity, the five analysis rows,
  /// the submit notice and (once submitted) the way out.
  Component _analysisStep() {
    final summary = _enrichment;
    return div([
      _draftLine(),
      _analysisSection(summary),
      _submitNotice(summary),
      if (_submitted)
        div(classes: 'sw-saved-actions', [
          AppLink(
            to: '/entrepreneur/my-properties',
            classes: 'sw-btn',
            children: [Component.text('My properties')],
          ),
          AppLink(
            to: '/entrepreneur/add-property',
            classes: 'sw-btn sw-btn-primary',
            children: [Component.text('Register another')],
          ),
        ]),
    ]);
  }

  // ------------------------------------------------------------------ footer

  /// Compact action bar. Save Draft appears only on the final step (earlier
  /// steps are incomplete by definition); Generate location analysis appears
  /// while the analysis is unsettled; Submit to Admin only after a draft
  /// exists.
  Component _footer() {
    // Once submitted there is nothing left to act on: the card already ends
    // with the review-queue notice and the way out, so an empty bar with a
    // divider would be pure decoration.
    if (_submitted) return const Component.fragment([]);

    final summary = _enrichment;
    final running = _enriching || (summary?.isRunning ?? false);
    final settled =
        (summary?.phaseOneComplete ?? false) &&
        (summary?.phaseTwoComplete ?? false);

    final left = <Component>[
      if (!_saved && _step > 0)
        button(
          classes: 'sw-btn',
          attributes: const {'type': 'button'},
          events: events(onClick: _back),
          [Component.text('Back')],
        ),
    ];

    final right = <Component>[];
    if (!_saved) {
      right.add(
        button(
          classes: 'sw-btn sw-btn-primary',
          attributes: {
            'type': 'button',
            if (_saving) 'disabled': '',
            'aria-busy': _saving ? 'true' : 'false',
          },
          events: events(onClick: _next),
          [
            Component.text(
              _saving ? 'Saving…' : (_isLast ? 'Save draft' : 'Continue'),
            ),
          ],
        ),
      );
    } else {
      if (!_submitted && !running && !settled) {
        right.add(
          button(
            classes: 'sw-btn',
            attributes: const {'type': 'button'},
            events: events(onClick: _runEnrichment),
            [Component.text('Generate location analysis')],
          ),
        );
      }
      if (!_submitted) {
        right.add(
          button(
            classes: 'sw-btn sw-btn-primary',
            attributes: {
              'type': 'button',
              if (running || _submitting) 'disabled': '',
              'aria-busy': _submitting ? 'true' : 'false',
            },
            events: events(
              onClick: running || _submitting ? null : _submitToAdmin,
            ),
            [
              Component.text(
                _submitting
                    ? 'Submitting…'
                    : running
                    ? 'Analysing…'
                    : 'Submit to Admin',
              ),
            ],
          ),
        );
      }
    }

    return footer(classes: 'sw-reg-footer', [
      div(classes: 'sw-reg-footer-left', left),
      div(classes: 'sw-reg-footer-right', right),
    ]);
  }
}
