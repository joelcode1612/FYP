import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';
import 'package:universal_web/web.dart' as web;

import '../../components/ui.dart';
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

  static const _steps = [
    'Property details',
    'Location & pricing',
    'F&B readiness',
    'Photos & proof',
    'Review & save',
  ];

  /// Required field keys per step.
  static const _required = <int, List<String>>{
    0: ['propertyName', 'propertyType', 'builtUp'],
    1: ['address', 'city', 'state', 'postcode', 'monthlyRent'],
    3: ['ownerRole'],
    4: [],
  };

  /// Human labels for cross-step validation messages.
  static const _labels = <String, String>{
    'propertyName': 'Property name',
    'propertyType': 'Property type',
    'builtUp': 'Built-up area',
    'address': 'Street address',
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
    for (final key in _required[_step] ?? const []) {
      if ((_fields[key] ?? '').trim().isEmpty) {
        _errors[key] = 'This field is required.';
      }
    }
    // Numeric values are validated in Dart, not left to the browser's
    // type=number spinner (which accepts "-1", "e" and empty strings).
    if (_step == 0 || _isLast) {
      _validatePositiveNumber(
        'builtUp',
        'Built-up area must be a number greater than 0.',
      );
    }
    if (_step == 1 || _isLast) {
      _validatePositiveNumber(
        'monthlyRent',
        'Monthly rent must be a number greater than 0.',
      );
      _validatePostcode();
    }
    // On the final step, re-check every earlier step so navigating back and
    // clearing a field cannot produce an incomplete draft.
    if (_isLast) {
      for (final keys in _required.values) {
        for (final key in keys) {
          if ((_fields[key] ?? '').trim().isEmpty) {
            _errors[key] = 'This field is required.';
          }
        }
      }
      if (!_confirm) {
      _errors['confirm'] = 'Please confirm the details before saving.';
    }
  }
  }

  void _validatePositiveNumber(String key, String message) {
    final raw = (_fields[key] ?? '').trim();
    if (raw.isEmpty || _errors.containsKey(key)) return;
    final value = double.tryParse(raw);
    if (value == null || !value.isFinite || value <= 0) {
      _errors[key] = message;
    }
  }

  void _validatePostcode() {
    final raw = (_fields['postcode'] ?? '').trim();
    if (raw.isEmpty || _errors.containsKey('postcode')) return;
    if (!RegExp(r'^\d{5}$').hasMatch(raw)) {
      _errors['postcode'] = 'Enter a 5-digit Malaysian postcode.';
    }
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

  Future<void> _saveDraft() async {
    // Duplicate-submit guard. `_saving` stays true for the whole transition so
    // a second click cannot start a second save. No async property-creation
    // service exists: the web repository's createProperty() throws
    // UnsupportedError and there is no image-upload endpoint. When a real
    // service is connected, its `await` replaces the microtask below and the
    // real returned property_id can be read afterwards.
    if (_saving || _saved) return;
    setState(() => _saving = true);
    await Future<void>.delayed(Duration.zero);
    if (!mounted) return;
    setState(() {
      // The draft is held in memory for this browser session only. Nothing is
      // persisted to a server, localStorage or the database, and no
      // property_id is issued.
      _saving = false;
      _saved = true;
    });
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
                'ownership information in one structured workflow. This form '
                'keeps a local draft only.',
              ),
            ]),
          ]),
          span(classes: 'sw-reg-status', [
            i(
              classes: 'sw-reg-status-dot',
              attributes: const {'aria-hidden': 'true'},
              [],
            ),
            span([Component.text('Local draft · not submitted')]),
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
      h3([Component.text('Submission not connected')]),
          p([
            Component.text(
          'The web property repository does not expose a working create '
          'operation, and no image-upload endpoint exists. Saving keeps a '
          'local, in-session draft: nothing is sent to the backend, no '
          'record is created and no property ID is issued.',
            ),
          ]),
    ],
  );

  // --------------------------------------------------------------- step card

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
                  ? 'Saving…'
                  : (_isLast ? 'Save local draft ' : 'Continue '),
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
        _ => 'Confirm the details before saving your local draft.',
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
              : events<String>(onInput: (v) => _set(key, v)),
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
        _field(key: 'propertyName', label: 'Property name', required: true),
        _field(
          key: 'propertyType',
          label: 'Property type',
          required: true,
          type: 'select',
          options: const [
            'Shoplot / shophouse',
            'Ground floor retail',
            'Corner retail unit',
            'Shopping mall unit',
            'Commercial kiosk',
            'Standalone commercial',
            'Other commercial premises',
          ],
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
          key: 'builtUp',
          label: 'Built-up area (sqft)',
          required: true,
          type: 'number',
          hint: 'e.g. 1680',
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
      ]);

  // --------------------------------------------------------------- step: location

  Component _stepLocation() => div(classes: 'sw-fields', [
    _field(key: 'address', label: 'Street address', required: true, wide: true),
        _field(key: 'city', label: 'City / township', required: true),
        _field(
          key: 'state',
          label: 'State',
          required: true,
          type: 'select',
          options: const [
            'Johor',
            'Kedah',
            'Kelantan',
            'Melaka',
            'Negeri Sembilan',
            'Pahang',
            'Penang',
            'Perak',
            'Perlis',
            'Sabah',
            'Sarawak',
            'Selangor',
            'Terengganu',
            'Kuala Lumpur',
            'Putrajaya',
            'Labuan',
          ],
        ),
        _field(
          key: 'postcode',
          label: 'Postcode',
          required: true,
          hint: 'e.g. 47500',
        ),
        _field(
          key: 'monthlyRent',
          label: 'Monthly rent (RM)',
          required: true,
          type: 'number',
          hint: '7800',
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
            'The address is saved as supplied. This preview does not validate a '
            'map location, public transport distance or commercial demand.',
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
        h3(classes: 'sw-reg-section-title', [
          Component.text('Review your property record '),
          small([Component.text('Confirm before saving')]),
        ]),
        dl(classes: 'sw-review-list', [
          _reviewRow('Property name', _fields['propertyName']),
          _reviewRow('Type', _fields['propertyType']),
          _reviewRow('Built-up area', _fields['builtUp']),
          _reviewRow('Address', _fields['address']),
          _reviewRow('City', _fields['city']),
          _reviewRow('State', _fields['state']),
          _reviewRow('Postcode', _fields['postcode']),
          _reviewRow('Monthly rent (RM)', _fields['monthlyRent']),
          _reviewRow('Facilities', '${_facilities.length} selected'),
          _reviewRow('F&B approval', _fields['fbApproval']),
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

  Component _savedView() => AppLayout(
        role: AppRole.entrepreneur,
        currentRoute: '/entrepreneur/add-property',
        title: 'Draft saved',
        eyebrow: 'Workspace',
        subtitle: 'Your property draft is held in this browser session.',
        child: div(classes: 'stack stack--sections sw-reg-saved', [
          div(classes: 'sw-saved-card', [
            div(classes: 'sw-saved-icon', [Icon('check_circle', size: 'lg')]),
        h2([Component.text('Local draft saved — not submitted')]),
            p([
              Component.text(
                '“${_fields['propertyName']?.isNotEmpty == true ? _fields['propertyName']! : 'Untitled property'}” '
            'is held in this browser session only. It has not been sent to '
            'the backend, no property was created and no property ID was '
            'issued.',
              ),
            ]),
        div(
          classes: 'sw-saved-notice',
          attributes: const {'role': 'note'},
          [
            strong([Component.text('Property creation is not connected.')]),
            p([
              Component.text(
                'The web repository has no working create operation and '
                'there is no image-upload endpoint. This screen is a '
                'design-state preview, not a successful API response.',
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
