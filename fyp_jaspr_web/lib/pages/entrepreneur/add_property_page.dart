import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/ui.dart';
import '../../layouts/app_layout.dart';

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
  final Map<String, String> _errors = {};

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
    if (_isLast && !_confirm) {
      _errors['confirm'] = 'Please confirm the details before saving.';
    }
  }

  void _next() {
    _validate();
    if (_errors.isNotEmpty) {
      setState(() {});
      return;
    }
    if (_isLast) {
      _saveDraft();
    } else {
      setState(() => _step++);
    }
  }

  void _back() {
    if (_step > 0) setState(() => _step--);
  }

  void _saveDraft() {
    // The draft is held in memory for the current browser session only. There
    // is no backend entity for owner-listed properties, and the reference
    // prototype does not submit anywhere — so this is intentionally a local,
    // unverified, in-session record rather than something persisted to
    // localStorage or a server.
    setState(() => _saved = true);
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
            to: '/entrepreneur/my-properties',
            classes: 'sw-reg-crumb-link',
            children: [Component.text('My Properties')],
          ),
          span(classes: 'sw-reg-crumb-sep', [Component.text('/')]),
          span([Component.text('New property')]),
        ]),
        div(classes: 'sw-reg-hero', [
          div([
            p(classes: 'sw-reg-kicker', [
              Component.text('PROPERTY WORKSPACE / REGISTRATION'),
            ]),
            h1([Component.text('Register a property')]),
            p([
              Component.text(
                'Capture commercial details, location, F&B facilities and '
                'ownership information in one structured workflow.',
              ),
            ]),
          ]),
          span(classes: 'sw-reg-status', [
            i(classes: 'sw-reg-status-dot', attributes: const {
              'aria-hidden': 'true',
            }, []),
            span([Component.text('Local draft')]),
          ]),
        ]),
        div(classes: 'sw-reg-grid', [
          _sidebar(),
          div(classes: 'sw-reg-card', [_stepCard()]),
          _preview(),
        ]),
      ]),
    );
  }

  // --------------------------------------------------------------- sidebar

  Component _sidebar() => aside(classes: 'sw-reg-sidebar', [
        div(classes: 'sw-reg-side-head', [
          span(classes: 'sw-label', [Component.text('REGISTRATION PROGRESS')]),
          div(classes: 'sw-reg-progress-top', [
            strong([Component.text('Step ${_step + 1} of ${_steps.length}')]),
            span([Component.text(_percent)]),
          ]),
          div(
            classes: 'sw-reg-meter',
            attributes: const {'role': 'progressbar'},
            [
              div(classes: 'sw-reg-meter-fill', styles: Styles(raw: {
                'width': _percent,
              }), []),
            ],
          ),
        ]),
        nav(classes: 'sw-reg-steps', [
          for (var i = 0; i < _steps.length; i++)
            button(
              classes: i == _step ? 'active' : (i < _step ? 'done' : ''),
              attributes: {
                'type': 'button',
                'aria-current': i == _step ? 'step' : 'false',
              },
              events: events(
                onClick: i <= _step ? () => setState(() => _step = i) : null,
              ),
              [
                span(classes: 'sw-step-circle', [
                  Component.text('0${i + 1}'),
                ]),
                span([
                  strong([Component.text(_steps[i])]),
                  small([Component.text(_stepHint(i))]),
                ]),
              ],
            ),
        ]),
        div(classes: 'sw-reg-side-foot', [
          strong([Component.text('Local preview')]),
          p([
            Component.text(
              'Records are held in this browser session. This form does not '
              'submit to a server or perform ownership verification.',
            ),
          ]),
        ]),
      ]);

  String _stepHint(int i) => switch (i) {
        0 => 'Premises & dimensions',
        1 => 'Address & commercial terms',
        2 => 'Utilities & infrastructure',
        3 => 'Visuals & ownership',
        _ => 'Verify your details',
      };

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
        if (_step == 0) _stepDetails(),
        if (_step == 1) _stepLocation(),
        if (_step == 2) _stepReadiness(),
        if (_step == 3) _stepProof(),
        if (_step == 4) _stepReview(),
        footer(classes: 'sw-reg-footer', [
          AppLink(
            to: '/entrepreneur/my-properties',
            classes: 'sw-btn sw-btn-text',
            children: [Component.text('Cancel')],
          ),
          div([
            button(
              classes: 'sw-btn',
              attributes: {
                'type': 'button',
                if (_step == 0) 'disabled': '',
              },
              events: events(onClick: _step == 0 ? null : _back),
              [Component.text('← Back')],
            ),
            button(
              classes: 'sw-btn sw-btn-primary',
              attributes: {'type': 'button'},
              events: events(onClick: _next),
              [
                Component.text(_isLast ? 'Save draft ' : 'Continue '),
                span([Component.text(_isLast ? '✓' : '→')]),
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
        1 => 'Where the premises is and the commercial terms on offer. '
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
            'name': key,
            if (err != null) 'aria-invalid': 'true',
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
            'name': key,
            'rows': '4',
            'placeholder': hint ?? '',
            if (err != null) 'aria-invalid': 'true',
          },
          events: events<String>(onInput: (v) => _set(key, v)),
          [Component.text(value)],
        ),
      _ => input(
          attributes: {
            'name': key,
            'type': type,
            'value': value,
            // Keep the value non-nullable so the map stays Map<String,String>;
            // a `hint?` null-aware entry would widen it to Map<String,String?>
            // and fail the `attributes` parameter type.
            // ignore: use_null_aware_elements
            if (hint != null) 'placeholder': hint,
            if (err != null) 'aria-invalid': 'true',
          },
          events: events<String>(onInput: (v) => _set(key, v)),
        ),
    };

    return div(
      classes: wide ? 'sw-field sw-field--wide' : 'sw-field',
      [
        _label(label, required),
        field,
        if (err != null) _fieldError(err),
      ],
    );
  }

  Component _label(String label, bool required) => span(classes: 'sw-field-label', [
        Component.text(label),
        if (required)
          em(attributes: const {'aria-hidden': 'true'}, [Component.text(' *')]),
      ]);

  Component _fieldError(String err) =>
      span(classes: 'sw-field-error', [Component.text(err)]);

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
        _field(
          key: 'address',
          label: 'Street address',
          required: true,
          wide: true,
        ),
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
              attributes: {'type': 'button', 'aria-pressed': _facilities.contains(f) ? 'true' : 'false'},
              events: events(onClick: () => _toggleFacility(f)),
              [
                Icon(_facilities.contains(f) ? 'check_circle' : 'add_circle', size: 'sm'),
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
            hint: 'Ventilation, utilities, equipment restrictions or fit-out needs…',
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
            span(classes: 'sw-upload-icon', attributes: const {
              'aria-hidden': 'true',
            }, [Component.text('↥')]),
            span([
              strong([Component.text('Select property photographs')]),
              small([Component.text('JPG, PNG or WebP · up to 8 MB per file')]),
            ]),
          ],
        ),
        input(attributes: {
          'id': 'swRegPhotoInput',
          'type': 'file',
          'accept': 'image/jpeg,image/png,image/webp',
          'multiple': '',
        }),
        p(classes: 'sw-reg-note', [
          Component.text(
            'Photos are previewed locally and not persisted or uploaded.',
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
        ]),
        label(classes: _confirm ? 'sw-confirm sw-confirm--on' : 'sw-confirm', [
          button(
            classes: _confirm ? 'sw-confirm-box sw-confirm-box--on' : 'sw-confirm-box',
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
        if (_errors['confirm'] != null) _fieldError(_errors['confirm']!),
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
            strong([Component.text('Please correct the highlighted information')]),
            ul([
              for (final e in _errors.values) li([Component.text(e)]),
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
          h3([Component.text(_fields['propertyName']?.isNotEmpty == true
              ? _fields['propertyName']!
              : 'Untitled property')]),
          p([Component.text(_fields['address']?.isNotEmpty == true
              ? _fields['address']!
              : 'Location not specified')]),
          div(classes: 'sw-preview-rent', [
            small([Component.text('MONTHLY RENT')]),
            strong([Component.text(_fields['monthlyRent']?.isNotEmpty == true
                ? 'RM ${_fields['monthlyRent']}'
                : '—')]),
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
            h2([Component.text('Draft saved locally')]),
            p([
              Component.text(
                '“${_fields['propertyName']?.isNotEmpty == true ? _fields['propertyName']! : 'Untitled property'}” '
                'is held in this browser session. It has not been submitted to a '
                'server or published as a public listing.',
              ),
            ]),
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
