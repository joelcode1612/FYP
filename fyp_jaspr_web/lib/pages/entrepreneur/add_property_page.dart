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

  /// `true` once the listing-scope verification submission succeeded and the
  /// property is genuinely sitting in the admin review queue.
  bool _enqueued = false;

  /// The server's own sentence when the verification submission failed after
  /// the listing was saved — shown honestly, never disguised as a success.
  String? _enqueueError;

  /// Populated only from a confirmed API response.
  OwnerListingResult? _result;

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

  // --------------------------------------------------- location edits

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
      _errors.remove(key);
    });
  }

  /// Submit the wizard to FastAPI.
  ///
  /// The listing is created first (`pending`, unpublished) and enriched from
  /// the PostGIS data second. Both outcomes are reported truthfully: a saved
  /// listing with a failed enrichment is NOT presented as a failure, and an
  /// API rejection is never presented as a save.
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
      final result = await _repository.submitOwnerListing({
        'name': _fields['propertyName']!.trim(),
        'property_type': commercialPropertyTypeWire(
          (_fields['propertyType'] ?? '').trim(),
        ),
        'description': _optional('description'),
        'address': _fields['address']!.trim(),
        'city': _fields['city']!.trim(),
        'state': _fields['state']!.trim(),
        'postcode': _fields['postcode']!.trim(),
        // No coordinates: the wizard does not geocode. The backend's
        // geospatial enrichment and admin review resolve the location.
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
      // Enter the admin review queue with the LISTING-ONLY scope: the saved
      // listing is complete, and this wizard collects no ownership documents
      // — ownership therefore stays `not_submitted` and only an
      // administrator's listing decision follows. Best-effort: a failed
      // enqueue is reported honestly below, it never rolls back the saved
      // listing.
      try {
        await AppLocator.propertyVerificationRepo.submit(
          '${result.propertyId}',
          scope: 'listing',
        );
        if (!mounted) return;
        setState(() => _enqueued = true);
      } catch (error) {
        if (!mounted) return;
        setState(() => _enqueueError = _cleanError(error));
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _submitError = _cleanError(error);
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
            'SiteWise administrators separately verify the listing and '
            'ownership evidence after submission.',
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
        ]),
        _reviewSection('Facilities & photos', 3, [
          _reviewRow('Facilities', '${_facilities.length} selected'),
          _reviewRow(
            'Photographs',
            '${_photos.length} selected (local preview only)',
          ),
          _reviewRow('Relationship', _fields['ownerRole']),
        ]),
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

  Component _savedView() {
    final result = _result;
    final features = result?.features;
    return AppLayout(
      role: AppRole.entrepreneur,
      currentRoute: '/entrepreneur/add-property',
      title: 'Listing submitted',
      eyebrow: 'Workspace',
      subtitle: 'Saved by SiteWise and queued for verification.',
      child: div(classes: 'stack stack--sections sw-reg-saved', [
        div(classes: 'sw-saved-card', [
          div(classes: 'sw-saved-icon', [Icon('check_circle', size: 'lg')]),
          h2([Component.text('Listing saved — pending verification')]),
          p([
            Component.text(
              result == null
                  ? 'The submission was accepted by the server.'
                  : '“${result.name}” was saved with property ID ${result.propertyId}. '
                        'It is ${result.verificationStatus} and '
                        '${result.isPublished ? 'published' : 'not published'} — '
                        'an administrator must verify it before it appears in Explore.',
            ),
          ]),
          div(
            classes: 'sw-saved-notice',
            attributes: const {'role': 'note'},
            [
              strong([Component.text('Review queue')]),
              if (_enqueued)
                p([
                  Component.text(
                    'The listing information has entered the administrator '
                    'review queue. Ownership documents were not required for '
                    'this submission; publishing still needs a separate '
                    'ownership verification.',
                  ),
                ])
              else if (_enqueueError != null)
                p([
                  Component.text(
                    'The listing is saved, but it has NOT entered the review '
                    'queue yet ($_enqueueError). Open the property from My '
                    'Properties and submit it for verification there.',
                  ),
                ])
              else
                p([
                  Component.text(
                    'Queueing the listing for review…',
                  ),
                ]),
            ],
          ),
          div(
            classes: 'sw-saved-notice',
            attributes: const {'role': 'note'},
            [
              strong([Component.text('Automatic location enrichment')]),
              if (result == null)
                p([Component.text('Enrichment status unavailable.')])
              else if (!result.enriched)
                p([
                  Component.text(
                    'The listing is saved, but the spatial enrichment step did not '
                    'complete (${result.enrichmentDetail ?? result.enrichmentStatus}). '
                    'Nothing was lost — you can retry it from My Properties.',
                  ),
                ])
              else
                p([
                  Component.text(
                    'F&B competitors within 500 m: '
                    '${result.featureInt('competitor_count_500m') ?? 'unavailable'}, '
                    'within 1 km: ${result.featureInt('competitor_count_1km') ?? 'unavailable'}. '
                    'Demand generators within 500 m: '
                    '${result.featureInt('demand_generator_count_500m') ?? 'unavailable'}. '
                    'Population within 500 m: '
                    '${features?['population_500m'] ?? 'unavailable (no raster source)'}.',
                  ),
                ]),
            ],
          ),
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
