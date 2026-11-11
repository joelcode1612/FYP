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

/// Entrepreneur property registration — a **browser-local draft** wizard.
///
/// Five steps: details, location & pricing, F&B readiness, photos & proof,
/// review. It mirrors the reference prototype's own honesty note: records are
/// stored in this browser and are **not** submitted to any server or backend.
/// There is no owner-listing entity in `shared_logic`, so this is intentionally a
/// local, unverified draft surface rather than a fabricated "published" listing.
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

  static const _steps = [
    'Property details',
    'Location & pricing',
    'F&B readiness',
    'Photos & proof',
    'Review & save',
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
    'propertyName': 'Property title',
    'propertyType': 'Property type',
    'builtUp': 'Built-up area',
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

  String get _percent => '${((_step + 1) * 100 / _steps.length).round()}%';

  void _set(String key, String value) => setState(() => _fields[key] = value);

  void _toggleFacility(String value) => setState(() {
    if (_facilities.contains(value)) {
      _facilities.remove(value);
    } else {
      _facilities.add(value);
    }
  });

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

  @override
  Component build(BuildContext context) {
    if (_saved) return _savedView();

    return AppLayout(
      role: AppRole.entrepreneur,
      currentRoute: '/entrepreneur/add-property',
      title: 'Register a property',
      showPageHead: false,
      // The wizard hero renders its own styled `sw-reg-breadcrumb` below;
      // the global AppLayout trail is suppressed so the page never shows two.
      showBreadcrumbs: false,
      child: div(classes: 'stack stack--sections sw-reg', [
        div(classes: 'sw-reg-breadcrumb', [
          AppLink(
            to: '/entrepreneur',
            classes: 'sw-reg-crumb-link',
            children: [Component.text('Home')],
          ),
          span(classes: 'sw-reg-crumb-sep', [Component.text('›')]),
          AppLink(
            to: '/entrepreneur/my-properties',
            classes: 'sw-reg-crumb-link',
            children: [Component.text('My Properties')],
          ),
          span(classes: 'sw-reg-crumb-sep', [Component.text('›')]),
          span([Component.text('Add Property')]),
        ]),
        div(classes: 'sw-reg-hero', [
          div([
            p(classes: 'sw-reg-kicker', [
              Component.text('ENTREPRENEUR WORKSPACE / REGISTRATION'),
            ]),
            h1([Component.text('Add commercial property')]),
            p([
              Component.text(
                'Capture commercial details, location, F&B facilities and '
                    'ownership information in one structured workflow. Submitting '
                    'saves the listing as pending and enriches it from the '
                    'SiteWise geospatial data.',
              ),
            ]),
          ]),
          span(classes: 'sw-reg-status', [
            i(
              classes: 'sw-reg-status-dot',
              attributes: const {'aria-hidden': 'true'},
              [],
            ),
            span([Component.text('Submits to SiteWise · pending verification')]),
          ]),
        ]),
        _stepper(),
        div(classes: 'sw-reg-grid', [
          div(classes: 'sw-reg-card', [_stepCard()]),
          div(classes: 'sw-reg-aside', [_preview(), _connectionNotice()]),
        ]),
      ]),
    );
  }

  // --------------------------------------------------------------- stepper

  /// Horizontal five-step progress strip. Completed steps remain clickable so
  /// entered values can be edited without losing the rest of the draft.
  Component _stepper() => div(classes: 'sw-reg-stepper-wrap', [
    div(classes: 'sw-reg-stepper-caption', [
      strong([Component.text('Step ${_step + 1} of ${_steps.length}')]),
      span([Component.text(' · $_percent complete')]),
    ]),
    nav(
      classes: 'sw-reg-stepper',
      attributes: const {'aria-label': 'Add Property progress'},
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
              if (i > _step) 'disabled': '',
            },
            events: events(
              onClick: i < _step ? () => setState(() => _step = i) : null,
            ),
            [
              span(
                classes: 'sw-reg-step-index',
                attributes: const {'aria-hidden': 'true'},
                [Component.text(i < _step ? '✓' : '${i + 1}')],
              ),
              span(classes: 'sw-reg-step-meta', [
                strong([Component.text(_steps[i])]),
                small([
                  Component.text(
                    i == _step
                        ? 'In progress'
                        : (i < _step ? 'Completed' : 'Upcoming'),
                  ),
                ]),
              ]),
            ],
          ),
      ],
    ),
  ]);

  Component _connectionNotice() => div(
    classes: 'sw-reg-connection',
    attributes: const {'role': 'note'},
    [
      h3([Component.text('How submission works')]),
      p([
        Component.text(
          'Submitting creates a real listing through FastAPI, saved as '
              'pending and unpublished. SiteWise then computes nearby F&B '
              'competitors, demand generators and road accessibility from its '
              'PostGIS data; any feature the database cannot compute for these '
              'coordinates is reported as unavailable rather than estimated. '
              'Photographs are not uploaded yet.',
        ),
      ]),
    ],
  );

  // --------------------------------------------------------------- step card

  /// Ask the backend (which holds the Google key) to validate the address.
  /// A verdict here never changes the listing's verification status.
  Future<void> _validateAddress() async {
    if (_addressState == AddressVerificationState.verifying) return;
    final snapshot = _addressSnapshot();
    if (snapshot.address.isEmpty) {
      setState(() {
        _errors['address'] = PropertyFormRules.addressError(snapshot.address) ??
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

  Component _stepCard() => div([
    header(classes: 'sw-reg-card-head', [
      div([
        span(classes: 'sw-label', [
          Component.text('STEP 0${_step + 1} / ${_stepLabel()}'),
        ]),
        h2([Component.text(_steps[_step])]),
        p([Component.text(_stepDesc())]),
      ]),
      span(classes: 'sw-reg-counter', [
        Component.text('0${_step + 1} / 0${_steps.length}'),
      ]),
    ]),
    _errorSummary(),
    _submitErrorNotice(),
    div(classes: 'sw-reg-step-body', [
      if (_step == 0) _stepDetails(),
      if (_step == 1) _stepLocation(),
      if (_step == 2) _stepReadiness(),
      if (_step == 3) _stepProof(),
      if (_step == 4) _stepReview(),
    ]),
    footer(classes: 'sw-reg-footer', [
      AppLink(
        to: '/entrepreneur/my-properties',
        classes: 'sw-btn sw-btn-text',
        children: [Component.text('Cancel')],
      ),
      div([
        button(
          classes: 'sw-btn',
          attributes: {'type': 'button', if (_step == 0) 'disabled': ''},
          events: events(onClick: _step == 0 ? null : _back),
          [Component.text('← Back')],
        ),
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
              _saving
                  ? 'Submitting…'
                  : (_isLast ? 'Submit for verification ' : 'Continue '),
            ),
            if (!_saving) span([Component.text('→')]),
          ],
        ),
      ]),
    ]),
  ]);

  String _stepLabel() => switch (_step) {
    0 => 'BASICS',
    1 => 'LOCATION',
    2 => 'READINESS',
    3 => 'PROOF',
    _ => 'REVIEW',
  };

  String _stepDesc() => switch (_step) {
    0 => 'Start with the identifying details of the commercial premises.',
    1 =>
    'Where the premises is and the commercial terms on offer. '
        'Malaysia · MYR.',
    2 => 'Utilities and infrastructure that affect F&B operations.',
    3 => 'Visuals and the ownership or authorization behind the listing.',
    _ => 'Confirm the details before submitting your listing.',
  };

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
          'rows': '4',
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

  Component _stepDetails() => div(classes: 'sw-fields', [
    _field(
      key: 'propertyName',
      label: 'Property title',
      required: true,
      hint: 'e.g. Ground Floor Corner Shoplot at SS15',
    ),
    _field(
      key: 'propertyType',
      label: 'Commercial property type',
      required: true,
      type: 'select',
      options: commercialPropertyTypeLabels,
    ),
    _field(
      key: 'monthlyRent',
      label: 'Monthly rental (RM)',
      required: true,
      type: 'number',
      hint: 'e.g. 7800',
    ),
    _field(
      key: 'builtUp',
      label: 'Built-up area (sqft)',
      required: true,
      type: 'number',
      hint: 'e.g. 1680',
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
      key: 'description',
      label: 'Property description',
      isTextarea: true,
      wide: true,
      hint: 'Frontage, layout, access and important premises features…',
    ),
    p(classes: 'sw-reg-note', [
      Component.text(
        'Only F&B commercial premises are accepted. The title, type, '
            'monthly rental and floor area are validated again by the server.',
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
          'placeholder': hint ??
              (enabled
                  ? 'Start typing to search…'
                  : 'Select the previous field first'),
          if (!enabled) 'disabled': '',
          if (required) 'required': '',
          if (err != null) 'aria-invalid': 'true',
          if (err != null) 'aria-describedby': '$key-error',
        },
        events: events<String>(
          onInput: (v) => _onLocationChanged(key, v),
        ),
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
    AddressVerificationState.unverified => 'NOT VERIFIED',
    AddressVerificationState.verifying => 'CHECKING',
    AddressVerificationState.validatedPendingConfirmation => 'CONFIRM REQUIRED',
    AddressVerificationState.verified => 'VERIFIED',
    AddressVerificationState.partiallyValidated => 'CORRECTION REQUIRED',
    AddressVerificationState.unconfirmed => 'CORRECTION REQUIRED',
    AddressVerificationState.serviceError => 'UNAVAILABLE',
  };

  Component _addressVerificationPanel() {
    final state = _addressState;
    final busy = state == AddressVerificationState.verifying;
    final result = _addressResult;
    final tone = switch (state) {
      AddressVerificationState.verified => 'sw-address-panel--ok',
      AddressVerificationState.validatedPendingConfirmation =>
      'sw-address-panel--confirm',
      AddressVerificationState.partiallyValidated ||
      AddressVerificationState.unconfirmed => 'sw-address-panel--warn',
      AddressVerificationState.serviceError => 'sw-address-panel--error',
      _ => 'sw-address-panel--idle',
    };
    return div(classes: 'sw-address-panel $tone', [
      div(classes: 'sw-address-head', [
        span(classes: 'sw-label', [Component.text('ADDRESS VERIFICATION')]),
        span(classes: 'sw-address-badge', [
          Component.text(_addressStateLabel(state)),
        ]),
      ]),
      p(classes: 'sw-address-copy', [
        Component.text(
          _addressMessage ??
              'Verify the address with Google before submitting. A validated '
                  'address confirms the location only — it does not verify '
                  'ownership or approve the listing.',
        ),
      ]),
      if (result != null &&
          result.formattedAddress != null &&
          result.formattedAddress!.isNotEmpty)
        p(classes: 'sw-address-formatted', [
          strong([Component.text('Normalized address: ')]),
          Component.text(result.formattedAddress!),
        ]),
      if (result != null && result.latitude != null && result.longitude != null)
        p(classes: 'sw-address-coords', [
          Component.text(
            'Coordinates: ${result.latitude!.toStringAsFixed(6)}, '
                '${result.longitude!.toStringAsFixed(6)}',
          ),
        ]),
      div(classes: 'sw-address-actions', [
        button(
          classes: 'sw-btn sw-btn-text',
          attributes: {
            'type': 'button',
            if (busy) 'disabled': '',
            'aria-busy': busy ? 'true' : 'false',
          },
          events: events(onClick: _validateAddress),
          [
            Component.text(
              busy
                  ? 'Checking address…'
                  : (state == AddressVerificationState.unverified
                  ? 'Verify address'
                  : 'Verify again'),
            ),
          ],
        ),
        if (state == AddressVerificationState.validatedPendingConfirmation)
          button(
            classes: 'sw-btn sw-btn-primary',
            attributes: const {'type': 'button'},
            events: events(onClick: _confirmAddress),
            [Component.text('Confirm this address')],
          ),
      ]),
      if (_errors['addressVerification'] != null)
        _fieldError('addressVerification', _errors['addressVerification']!),
    ]);
  }

  Component _stepLocation() => div(classes: 'sw-fields', [
    _field(
      key: 'address',
      label: 'Building / unit number and street address',
      required: true,
      wide: true,
      hint: 'e.g. No. 12, Jalan SS 15/4',
      onChanged: (v) => _onLocationChanged('address', v),
    ),
    _stateField(),
    _locationTextField(
      key: 'city',
      label: 'City / township',
      options: MalaysiaLocations.citiesFor(_fields['state']),
      enabled: (_fields['state'] ?? '').isNotEmpty,
      required: true,
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
      hint: 'e.g. 47500',
    ),
    div(classes: 'sw-field sw-field--wide', [
      _addressVerificationPanel(),
    ]),
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
    p(classes: 'sw-reg-note', [
      Component.text(
        'Changing the address, state, city or postcode clears the previous '
            'verification — verify the updated address again. Google validates '
            'the address only; SiteWise administrators separately verify the '
            'listing and ownership evidence.',
      ),
    ]),
  ]);

  // --------------------------------------------------------------- step: readiness

  Component _stepReadiness() => div([
    h3(classes: 'sw-reg-section-title', [
      Component.text('Available F&B infrastructure '),
      small([Component.text('Check what is documented')]),
    ]),
    div(classes: 'sw-facilities', [
      for (final f in const [
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
      ])
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
            Icon(
              _facilities.contains(f) ? 'check_circle' : 'add_circle',
              size: 'sm',
            ),
            Component.text(f),
          ],
        ),
    ]),
    h3(classes: 'sw-reg-section-title sw-extra-title', [
      Component.text('Operational details'),
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
        hint:
        'Ventilation, utilities, equipment restrictions or fit-out needs…',
      ),
    ]),
    p(classes: 'sw-reg-note', [
      Component.text(
        'These facilities are owner-declared, not independently inspected or '
            'certified.',
      ),
    ]),
  ]);

  // --------------------------------------------------------------- step: proof

  Component _stepProof() => div([
    h3(classes: 'sw-reg-section-title', [
      Component.text('Property photography '),
      small([Component.text('8 photos maximum')]),
    ]),
    label(
      classes: 'sw-upload',
      attributes: const {'for': 'swRegPhotoInput'},
      [
        span(
          classes: 'sw-upload-icon',
          attributes: const {'aria-hidden': 'true'},
          [Component.text('↥')],
        ),
        span([
          strong([Component.text('Select property photographs')]),
          small([Component.text('JPG, PNG or WebP · up to 8 MB per file')]),
        ]),
      ],
    ),
    input(
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
            div(classes: 'sw-photo-meta', [
              span([Component.text(_photos[i].name)]),
              small([Component.text(_photos[i].sizeLabel)]),
            ]),
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
      ])
    else
      p(classes: 'sw-reg-note', [
        Component.text(
          'No photographs selected yet. Photos are optional for a local draft.',
        ),
      ]),
    p(classes: 'sw-reg-note', [
      Component.text(
        'Selected images are previewed in this browser only. No image '
            'upload endpoint or media service is connected, so they are never '
            'transmitted, stored or attached to a property record.',
      ),
    ]),
    h3(classes: 'sw-reg-section-title sw-extra-title', [
      Component.text('Authorization details'),
    ]),
    div(classes: 'sw-fields', [
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
        'Supporting documents are not retained or transmitted by this '
            'preview.',
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
    final free = _maxPhotos - _photos.length;
    if (accepted.length > free) {
      error = 'You can select up to $_maxPhotos photographs.';
      if (free <= 0) {
        accepted.clear();
      } else {
        accepted.removeRange(free, accepted.length);
      }
    }
    final added = <_SelectedPhoto>[];
    for (final file in accepted) {
      added.add(
        _SelectedPhoto(
          name: file.name,
          sizeLabel: _formatBytes(file.size),
          url: web.URL.createObjectURL(file),
        ),
      );
    }
    setState(() {
      _photos.addAll(added);
      _photoError = error;
    });
  }

  void _removePhoto(int index) {
    if (index < 0 || index >= _photos.length) return;
    final removed = _photos.removeAt(index);
    web.URL.revokeObjectURL(removed.url);
    setState(() => _photoError = null);
  }

  static String _formatBytes(int bytes) => bytes < 1024 * 1024
      ? '${(bytes / 1024).round()} KB'
      : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';

  // --------------------------------------------------------------- step: review

  Component _stepReview() => div([
    _reviewSection('Property details', 0, [
      _reviewRow('Property title', _fields['propertyName']),
      _reviewRow('Commercial property type', _fields['propertyType']),
      _reviewRow(
        'Monthly rental',
        (_fields['monthlyRent'] ?? '').isEmpty
            ? null
            : 'RM ${_fields['monthlyRent']}',
      ),
      _reviewRow(
        'Built-up area',
        (_fields['builtUp'] ?? '').isEmpty
            ? null
            : '${_fields['builtUp']} sq ft',
      ),
    ]),
    _reviewSection('Location & address', 1, [
      _reviewRow('Address', _fields['address']),
      _reviewRow('State', _fields['state']),
      _reviewRow('City / township', _fields['city']),
      _reviewRow('Postcode', _fields['postcode']),
      _reviewRow(
        'Address verification',
        _addressVerified
            ? 'Verified${_addressResult?.formattedAddress == null ? '' : ' · ${_addressResult!.formattedAddress}'}'
            : _addressStateLabel(_addressState),
      ),
      _reviewRow(
        'Coordinates',
        _verifiedLatitude == null || _verifiedLongitude == null
            ? null
            : '${_verifiedLatitude!.toStringAsFixed(6)}, '
            '${_verifiedLongitude!.toStringAsFixed(6)}',
      ),
    ]),
    _reviewSection('Facilities & photos', 3, [
      _reviewRow('Facilities', '${_facilities.length} selected'),
      _reviewRow(
        'Photographs',
        '${_photos.length} selected (local preview only)',
      ),
      _reviewRow('Relationship', _fields['ownerRole']),
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
          'I confirm the details are accurate to the best of my knowledge. '
              'Saving a local draft does not verify ownership, authorize F&B use '
              'or publish a public listing.',
        ),
      ]),
    ]),
    if (_errors['confirm'] != null) _fieldError('confirm', _errors['confirm']!),
  ]);

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

  // --------------------------------------------------------------- live preview

  Component _preview() => aside(classes: 'sw-reg-preview', [
    div(classes: 'sw-preview-top', [
      span(classes: 'sw-label', [Component.text('LIVE PROPERTY PREVIEW')]),
      span(classes: 'sw-preview-badge', [Component.text('UNPUBLISHED')]),
    ]),
    div(classes: 'sw-preview-content', [
      span(classes: 'sw-label', [Component.text('COMMERCIAL PROPERTY')]),
      h3([
        Component.text(
          _fields['propertyName']?.isNotEmpty == true
              ? _fields['propertyName']!
              : 'Untitled property',
        ),
      ]),
      p([
        Component.text(
          _fields['address']?.isNotEmpty == true
              ? _fields['address']!
              : 'Location not specified',
        ),
      ]),
      div(classes: 'sw-preview-rent', [
        small([Component.text('MONTHLY RENT')]),
        strong([
          Component.text(
            _fields['monthlyRent']?.isNotEmpty == true
                ? 'RM ${_fields['monthlyRent']}'
                : '—',
          ),
        ]),
        span([Component.text(' / month')]),
      ]),
      dl([
        _previewRow('Property type', _fields['propertyType']),
        _previewRow('Built-up area', _fields['builtUp']),
        _previewRow('Floor', _fields['floorLevel']),
        _previewRow('Facilities', '${_facilities.length} selected'),
      ]),
    ]),
    div(classes: 'sw-preview-foot', [
      Component.text(
        'This preview reflects entered information, not independently '
            'verified data.',
      ),
    ]),
  ]);

  Component _previewRow(String label, String? value) => div([
    dt([Component.text(label)]),
    dd([Component.text((value ?? '').isEmpty ? '—' : value!)]),
  ]);

  // --------------------------------------------------------------- saved view

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

  /// One line summarising what a category actually measured.
  String _measurementLine(EnrichmentCategoryState state) {
    final c = state.category;
    if (!state.status.hasMeasurement) return '';
    switch (c) {
      case EnrichmentCategory.fnbCompetitors:
        return '500 m: ${_measured(state.number('competitor_count_500m'))} · '
            '1 km: ${_measured(state.number('competitor_count_1km'))}';
      case EnrichmentCategory.demandGenerators:
        return '500 m: ${_measured(state.number('demand_generator_count_500m'))} · '
            '1 km: ${_measured(state.number('demand_generator_count_1km'))}';
      case EnrichmentCategory.roadsTransport:
        return 'Road length (1 km): '
            '${_measured(state.number('accessibility_road_km_1km'), decimals: 1, unit: ' km')} · '
            'Nearest major road: '
            '${_measured(state.number('nearest_major_road_m'), unit: ' m')} · '
            'Transit stops (500 m): '
            '${_measured(state.number('transit_stops_500m'))}';
      case EnrichmentCategory.parking:
        return 'Facilities (500 m): '
            '${_measured(state.number('parking_facilities_500m'))} · '
            '1 km: ${_measured(state.number('parking_facilities_1km'))} · '
            'Nearest: ${_measured(state.number('nearest_parking_m'), unit: ' m')}';
      case EnrichmentCategory.population:
        final unavailable = state.unavailableRadii;
        final parts = <String>[
          '500 m: ${_measured(state.number('population_500m'))}',
          '1 km: ${_measured(state.number('population_1km'))}',
        ];
        final line = parts.join(' · ');
        return unavailable.isEmpty
            ? line
            : '$line (no raster coverage at ${unavailable.join(', ')})';
    }
  }

  static String _statusTone(EnrichmentStatus status) => switch (status) {
    EnrichmentStatus.current => 'success',
    EnrichmentStatus.unavailable => 'warning',
    EnrichmentStatus.failed => 'danger',
    EnrichmentStatus.running => 'action',
    EnrichmentStatus.stale => 'warning',
    EnrichmentStatus.pending => 'neutral',
  };

  /// The eight-step sequence: save, the five categories, the summary, submit.
  Component _stageSequence(PropertyEnrichmentSummary? summary) {
    final rows = <Component>[];
    var index = 0;
    Component row(
      String label,
      String statusLabel,
      String tone, {
      String detail = '',
      Component? action,
    }) {
      index += 1;
      final done = tone == 'success';
      return div(
        classes: 'sw-enrich-step'
            '${done ? ' is-done' : ''}'
            '${tone == 'danger' ? ' is-failed' : ''}'
            '${tone == 'action' ? ' is-running' : ''}',
        [
          span(classes: 'sw-enrich-step__index', [
            Component.text(done ? '✓' : '$index'),
          ]),
          div(classes: 'sw-enrich-step__body', [
            div(classes: 'sw-enrich-step__head', [
              strong([Component.text(label)]),
              StatusBadge(statusLabel, tone: tone),
            ]),
            if (detail.isNotEmpty)
              p(classes: 'sw-enrich-step__detail', [Component.text(detail)]),
          ]),
          ?action,
        ],
      );
    }

    rows.add(
      row(
        'Draft saved',
        'Done',
        'success',
        detail: summary == null
            ? 'The listing is stored privately and is not in the review queue.'
            : 'The listing is stored privately and is not in the review queue.',
      ),
    );

    for (final category in EnrichmentCategory.values) {
      final state = summary?.state(category);
      final status = state?.status ?? EnrichmentStatus.pending;
      final measured = state == null ? '' : _measurementLine(state);
      final reason = state?.reason ?? '';
      final detail = <String>[
        if (measured.isNotEmpty) measured,
        if (reason.isNotEmpty && status != EnrichmentStatus.current) reason,
        if (category.phase == EnrichmentPhase.population &&
            status == EnrichmentStatus.current)
          'Source: ${state?.provenance?['source'] ?? 'population raster'}',
      ].join(' — ');
      rows.add(
        row(
          category.label,
          status.label,
          _statusTone(status),
          detail: detail,
          action: (state != null && status.retryable && !_enriching)
              ? button(
                  classes: 'sw-enrich-retry',
                  attributes: const {'type': 'button'},
                  events: events(
                    onClick: () => _retryCategory(category),
                  ),
                  [Component.text('Retry')],
                )
              : null,
        ),
      );
    }

    final settled = summary != null && summary.phaseOneComplete && summary.phaseTwoComplete;
    rows.add(
      row(
        'Location summary',
        settled ? 'Ready' : 'Waiting',
        settled ? 'success' : 'neutral',
        detail: settled
            ? 'All five categories have settled. Review the figures above before submitting.'
            : 'Waiting for the remaining categories to finish.',
      ),
    );

    rows.add(
      row(
        'Submit to Admin',
        _submitted ? 'Submitted' : 'Your decision',
        _submitted ? 'success' : 'neutral',
        detail: _submitted
            ? 'The listing information is in the administrator review queue.'
            : 'Nothing is sent for review until you press the button below.',
      ),
    );

    return div(classes: 'sw-enrich-steps', rows);
  }

  Component _enrichmentPanel(PropertyEnrichmentSummary? summary) {
    return div(classes: 'sw-saved-notice', attributes: const {'role': 'note'}, [
      strong([Component.text('Location enrichment')]),
      p([
        Component.text(
          _enriching
              ? 'Calculating from PostGIS and the population raster. '
                  'Each category reports as soon as it settles — there is no '
                  'countdown and no invented progress.'
              : 'Each category reports its own state. A category that could not be '
                  'measured is labelled, never shown as zero.',
        ),
      ]),
      if (_enrichmentError != null)
        p(classes: 'sw-enrich-error', [Component.text(_enrichmentError!)]),
      _stageSequence(summary),
    ]);
  }

  Component _submitPanel(PropertyEnrichmentSummary? summary) {
    if (_submitted) {
      return div(classes: 'sw-saved-notice', attributes: const {'role': 'note'}, [
        strong([Component.text('Review queue')]),
        p([
          Component.text(
            'The listing information has entered the administrator review '
            'queue. Ownership documents were not required for this submission; '
            'publishing still needs a separate ownership verification.',
          ),
        ]),
      ]);
    }

    final populationUnavailable = summary?.populationUnavailable ?? false;
    final running = summary?.isRunning ?? _enriching;
    final canSubmit = !running && !_submitting;

    return div(classes: 'sw-saved-notice sw-enrich-submit', [
      strong([Component.text('Submit to Admin')]),
      p([
        Component.text(
          'Saving a draft never submits it. Review the figures above, then send '
          'the listing to an administrator when you are ready.',
        ),
      ]),
      if (populationUnavailable)
        div(classes: 'sw-enrich-ack', [
          p([
            Component.text(
              'Population could not be measured for these coordinates. No '
              'estimate is substituted, so the administrator will see '
              '"Not available" for population. Confirm that you want to '
              'submit anyway.',
            ),
          ]),
          label(classes: 'sw-enrich-ack__check', [
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
          ]),
        ]),
      if (_enqueueError != null)
        p(classes: 'sw-enrich-error', [Component.text(_enqueueError!)]),
      div(classes: 'sw-saved-actions', [
        button(
          classes: 'sw-btn sw-btn-primary'
              '${canSubmit ? '' : ' is-disabled'}',
          attributes: {
            'type': 'button',
            if (!canSubmit) 'disabled': '',
          },
          events: events(onClick: canSubmit ? _submitToAdmin : null),
          [
            Component.text(
              _submitting
                  ? 'Submitting…'
                  : running
                  ? 'Waiting for enrichment…'
                  : 'Submit to Admin',
            ),
          ],
        ),
      ]),
    ]);
  }

  Component _savedView() {
    final result = _result;
    final summary = _enrichment;
    return AppLayout(
      role: AppRole.entrepreneur,
      currentRoute: '/entrepreneur/add-property',
      title: _submitted ? 'Submitted for review' : 'Draft saved',
      eyebrow: 'Workspace',
      subtitle: _submitted
          ? 'Saved and queued for administrator verification.'
          : 'Saved as a draft. Nothing has been sent for review yet.',
      child: div(classes: 'stack stack--sections sw-reg-saved', [
        div(classes: 'sw-saved-card', [
          div(classes: 'sw-saved-icon', [
            Icon(_submitted ? 'check_circle' : 'save', size: 'lg'),
          ]),
          h2([
            Component.text(
              _submitted
                  ? 'Listing submitted — pending verification'
                  : 'Draft saved — not yet submitted',
            ),
          ]),
          p([
            Component.text(
              result == null
                  ? 'The draft was accepted by the server.'
                  : '“${result.name}” was saved with property ID '
                      '${result.propertyId}. It is ${result.verificationStatus} '
                      'and ${result.isPublished ? 'published' : 'not published'}.',
            ),
          ]),
          if (_submitError != null)
            p(classes: 'sw-enrich-error', [Component.text(_submitError!)]),
          _enrichmentPanel(summary),
          _submitPanel(summary),
          div(classes: 'sw-saved-actions', [
            AppLink(
              to: '/entrepreneur/add-property',
              classes: 'sw-btn sw-btn-primary',
              children: [Component.text('Register another')],
            ),
            AppLink(
              to: '/entrepreneur/my-properties',
              classes: 'sw-btn',
              children: [Component.text('Back to My Properties')],
            ),
          ]),
        ]),
      ]),
    );
  }
}
