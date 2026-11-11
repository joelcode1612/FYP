import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/ui.dart';
import '../../data/app_locator.dart';
import '../../data/assessment_api.dart';
import '../../data/assessment_format.dart';
import '../../layouts/app_layout.dart';

/// The entrepreneur's recommendation criteria, stored on their account.
///
/// Three defects this page had, and what replaced them:
///
/// * Persistence was a browser cookie. It now reads and writes
///   `/api/v1/preferences/me`, so the criteria belong to the account rather than
///   to one device, and a success notice is only shown once the server has
///   confirmed the write.
/// * The property-type pills were a hardcoded list — `Cafe`, `Restaurant`,
///   `Kiosk`, `Bakery`, `Other` — none of which is a `property_type` in the
///   imported catalogue. Eligibility is an exact match, so picking any of them
///   silently emptied every shortlist while still looking functional. The
///   options now come from `/api/v1/catalog/property-types`.
/// * The numeric inputs parsed on every keystroke and discarded anything
///   unparseable, so clearing a field or typing a partial number did nothing at
///   all. The values are kept as text and validated explicitly, including the
///   min-cannot-exceed-max pairs.
///
/// The stored payload uses the assessment workspace's business-requirements
/// vocabulary and its server-side validation, so this page and stage 2 of the
/// workspace are one preference system rather than two.
@client
class PreferencesPage extends StatefulComponent {
  const PreferencesPage({super.key});

  @override
  State<PreferencesPage> createState() => _PreferencesPageState();
}

class _PreferencesPageState extends State<PreferencesPage> {
  static const _api = AssessmentApi();

  static const _businessCategories = <String>[
    'Cafe / Coffee Shop',
    'Restaurant',
    'Bakery / Dessert Shop',
    'Fast Food / Quick Service',
    'Beverage Shop / Kiosk',
    'Other F&B',
  ];

  bool _loading = true;
  String? _loadError;
  bool _unauthorized = false;

  /// The catalogue's real `property_type` values, or null if that call failed.
  /// A failure is not fatal: the field degrades to exact-match text with an
  /// explanation instead of offering types that would match nothing.
  List<String>? _catalogueTypes;
  String? _typesError;

  // Numbers are held as text. Parsing on input and dropping the unparseable is
  // what made an emptied field silently keep its old value.
  String _businessType = '';
  String _propertyType = 'Any';
  String _minBudget = '0';
  String _maxBudget = '';
  String _minSize = '0';
  String _maxSize = '';
  String _targetMarket = '';

  /// The last server-confirmed values. Discard restores these, so after a
  /// successful save it returns to what is actually stored rather than to
  /// whatever the form held beforehand.
  Map<String, String> _baseline = const {};
  String? _savedAt;

  bool _saving = false;
  String? _savedMessage;
  String? _errorMessage;
  Map<String, String> _errors = const {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
      _unauthorized = false;
    });
    final preferencesFuture = _api.preferences();
    final typesFuture = _api.propertyTypes();
    final preferences = await preferencesFuture;
    final types = await typesFuture;
    if (!mounted) return;

    if (!preferences.ok) {
      final failure = preferences.failure!;
      setState(() {
        _loading = false;
        _unauthorized = failure.kind == AssessmentFailureKind.unauthorized;
        _loadError = failure.message;
      });
      return;
    }

    final stored = preferences.value!;
    setState(() {
      _loading = false;
      _catalogueTypes = types.ok ? types.value : null;
      _typesError = types.ok ? null : types.failure!.message;
      _savedAt = stored.updatedAt;
      // Nothing stored yet is not an error: the ranking is already using the
      // session preferences, so the form shows those rather than blank fields
      // or values the server never held.
      _seed(
        businessPreferencesFrom(stored.preferences) ?? AppLocator.preferences,
        stored.preferences,
      );
      _savedMessage = null;
      _errorMessage = null;
    });
  }

  void _seed(BusinessPreferences value, Map<String, dynamic>? stored) {
    _businessType = value.businessType;
    _propertyType = value.propertyType.isEmpty ? 'Any' : value.propertyType;
    _minBudget = _text(value.minBudgetRm);
    _maxBudget = _text(value.maxBudgetRm);
    _minSize = _text(value.minSizeSqft);
    _maxSize = value.maxSizeSqft.isFinite ? _text(value.maxSizeSqft) : '';
    _targetMarket =
        stored?['target_market'] as String? ?? value.requirements.join(', ');
    _baseline = _snapshot();
    _errors = const {};
  }

  Map<String, String> _snapshot() => {
    'business_type': _businessType,
    'property_type': _propertyType,
    'min_budget_rm': _minBudget,
    'max_budget_rm': _maxBudget,
    'min_size_sqft': _minSize,
    'max_size_sqft': _maxSize,
    'target_market': _targetMarket,
  };

  /// Always offers the server-supported catalogue values when available.
  /// `Any` remains available because it is the page's no-specific-type choice.
  List<String> get _propertyTypeOptions =>
      <String>{'Any', ...?_catalogueTypes}.toList(growable: false);

  bool get _dirty {
    final now = _snapshot();
    return now.keys.any((key) => _baseline[key] != now[key]);
  }

  static String _text(double value) =>
      value == value.roundToDouble() ? value.toStringAsFixed(0) : '$value';

  // ---------------------------------------------------------------------- save

  Future<void> _save() async {
    if (_saving || _loading) return;
    final payload = _payload();
    if (payload == null) {
      setState(() {
        _savedMessage = null;
        _errorMessage = null;
      });
      return;
    }
    setState(() {
      _saving = true;
      _savedMessage = null;
      _errorMessage = null;
    });

    final result = await _api.savePreferences(payload);
    if (!mounted) return;

    if (!result.ok) {
      setState(() {
        _saving = false;
        // What was typed is left exactly as typed: a failed save must not cost
        // the entrepreneur the form they just filled in.
        _errorMessage = '${result.failure!.message} Nothing was saved.';
      });
      return;
    }

    final stored = result.value!;
    final value = stored.asBusinessPreferences();
    if (value != null) {
      // The server-normalised values, not the raw form text, are what the
      // ranking now reads, so the confirmation describes what is really stored.
      context
          .read(entrepreneurNotifierProvider.notifier)
          .updatePreferences(value);
      AppLocator.persistPreferences(value);
    }
    setState(() {
      _saving = false;
      _savedAt = stored.updatedAt;
      _seed(value ?? AppLocator.preferences, stored.preferences);
      _savedMessage = _savedAt == null
          ? 'Preferences saved and in use by your rankings.'
          : 'Preferences saved at ${assessmentStamp(_savedAt!)} and in use by '
                'your rankings.';
    });
  }

  void _discard() {
    if (_saving) return;
    setState(() {
      _businessType = _baseline['business_type'] ?? '';
      _propertyType = _baseline['property_type'] ?? 'Any';
      _minBudget = _baseline['min_budget_rm'] ?? '0';
      _maxBudget = _baseline['max_budget_rm'] ?? '';
      _minSize = _baseline['min_size_sqft'] ?? '0';
      _maxSize = _baseline['max_size_sqft'] ?? '';
      _targetMarket = _baseline['target_market'] ?? '';
      _errors = const {};
      _savedMessage = null;
      _errorMessage = null;
    });
  }

  /// Validates and builds the request body, or records every field error and
  /// returns null. The rules mirror the server's `validate_requirements` so
  /// problems surface before a round trip; the server stays authoritative.
  Map<String, dynamic>? _payload() {
    final errors = <String, String>{};

    final businessType = _businessType.trim();
    if (businessType.isEmpty) {
      errors['business_type'] = 'Enter your business category.';
    } else if (businessType.length > 120) {
      errors['business_type'] = 'Use 120 characters or fewer.';
    }

    final propertyType = _propertyType.trim();
    if (propertyType.isEmpty) {
      errors['property_type'] = 'Choose a property type, or "Any".';
    } else if (propertyType.length > 60) {
      errors['property_type'] = 'Use 60 characters or fewer.';
    }

    final targetMarket = _targetMarket.trim();
    if (targetMarket.length > 240) {
      errors['target_market'] = 'Use 240 characters or fewer.';
    }

    final minBudget = _number('min_budget_rm', _minBudget, errors);
    final maxBudget = _number(
      'max_budget_rm',
      _maxBudget,
      errors,
      required: true,
    );
    final minSize = _number('min_size_sqft', _minSize, errors);
    final maxSize = _number('max_size_sqft', _maxSize, errors, required: true);

    if (minBudget != null && maxBudget != null && minBudget > maxBudget) {
      errors['min_budget_rm'] = 'Minimum rent cannot exceed the maximum.';
    }
    if (minSize != null && maxSize != null && minSize > maxSize) {
      errors['min_size_sqft'] = 'Minimum floor area cannot exceed the maximum.';
    }

    setState(() => _errors = errors);
    if (errors.isNotEmpty ||
        minBudget == null ||
        maxBudget == null ||
        minSize == null ||
        maxSize == null) {
      return null;
    }

    return {
      'business_type': businessType,
      'property_type': propertyType,
      'target_market': targetMarket,
      'min_budget_rm': minBudget,
      'max_budget_rm': maxBudget,
      'min_size_sqft': minSize,
      'max_size_sqft': maxSize,
      // Target market is mirrored into the first requirement because the shared
      // BusinessPreferences has no target-market field of its own. This is the
      // assessment draft's existing convention, not a second meaning.
      'requirements': targetMarket.isEmpty ? const [] : [targetMarket],
    };
  }

  /// Parses one numeric field. An empty optional field is zero, which is what
  /// the server stores for it; an empty required field is an error.
  double? _number(
    String field,
    String raw,
    Map<String, String> errors, {
    bool required = false,
  }) {
    final text = raw.trim();
    if (text.isEmpty) {
      if (required) errors[field] = 'This value is required.';
      return 0;
    }
    final parsed = double.tryParse(text);
    if (parsed == null || !parsed.isFinite) {
      errors[field] = 'Enter a number.';
      return null;
    }
    if (parsed < 0) {
      errors[field] = 'Enter zero or a positive number.';
      return null;
    }
    if (required && parsed <= 0) {
      errors[field] = 'Enter a value greater than zero.';
      return null;
    }
    return parsed;
  }

  @override
  Component build(BuildContext context) {
    return AppLayout(
      role: AppRole.entrepreneur,
      currentRoute: '/entrepreneur/preferences',
      title: 'Your preferences',
      eyebrow: 'Recommendations',
      subtitle:
          'These values decide which properties are eligible for your shortlist. '
          'They are stored on your account and read by every ranking and every '
          'location assessment you open.',
      child: div(classes: 'stack stack--sections', [
        _explainer(),
        if (_loading)
          _loadingPanel()
        else if (_loadError != null)
          _failurePanel()
        else
          _form(),
        p(classes: 'disclaimer', [
          Component.text(
            'Preferences are a filter, not a prediction. Changing them changes '
            'which listings are eligible and how the eligible ones are ordered '
            '— it does not change the underlying listing data.',
          ),
        ]),
      ]),
    );
  }

  // ---------------------------------------------------------------- explainer

  Component _explainer() => section(classes: 'stack stack--md', [
    h2(classes: 'title-lg', [
      Component.text('How preferences turn into a shortlist'),
    ]),
    div(classes: 'quick', [
      _step(
        'Step 1',
        'Business profile',
        'Your category, budget range and target size define what "suitable" '
            'means for your concept.',
      ),
      _step(
        'Step 2',
        'Eligibility thresholds',
        'Budget, size and type act as hard filters — a property outside them is '
            'never ranked, however good its location.',
      ),
      _step(
        'Step 3',
        'Ordering',
        'Eligible properties are ordered by the imported F&B suitability index '
            'from the source workbook. That index is not a model trained on '
            'your preferences, and no score is generated here.',
      ),
    ]),
  ]);

  Component _step(String eyebrow, String title, String body) => div([
    span(classes: 'eyebrow', [Component.text(eyebrow)]),
    h3([Component.text(title)]),
    p([Component.text(body)]),
  ]);

  // --------------------------------------------------------------------- form

  Component _form() => div(classes: 'filters', [
    div(classes: 'frow', [
      _numberField(
        'min_budget_rm',
        'Min monthly rent (RM)',
        hint:
            'Listings below this are never ranked. Leave empty for no lower '
            'bound.',
        value: _minBudget,
        onChanged: (v) => setState(() => _minBudget = v),
      ),
      _numberField(
        'max_budget_rm',
        'Max monthly rent (RM)',
        hint: 'The hard eligibility cut-off for candidates. Required.',
        value: _maxBudget,
        onChanged: (v) => setState(() => _maxBudget = v),
      ),
      _numberField(
        'min_size_sqft',
        'Min floor area (sq ft)',
        hint: 'Smaller units are never ranked. Leave empty for no lower bound.',
        value: _minSize,
        onChanged: (v) => setState(() => _minSize = v),
      ),
      _numberField(
        'max_size_sqft',
        'Max floor area (sq ft)',
        hint: 'Larger units are never ranked. Required.',
        value: _maxSize,
        onChanged: (v) => setState(() => _maxSize = v),
      ),
    ]),

    div(classes: 'frow', [
      // Property type as checkpills, as in the source. This is the field the
      // eligibility filter reads (`propertyType`) — single-choice radio group.
      div(classes: 'field', [
        span(classes: 'field__label', [Component.text('Property type')]),
        if (_catalogueTypes == null)
          select(
            attributes: {
              'id': 'business-category',
              'name': 'business_type',
              'aria-label': 'Business category',
              if (_errors['business_type'] != null) 'aria-invalid': 'true',
            },
            events: events<String>(
              onInput: (value) {
                setState(() => _businessType = value);
              },
            ),
            [
              option(
                value: '',
                attributes: {if (_businessType.isEmpty) 'selected': ''},
                [Component.text('Select business category')],
              ),

              // Preserve older saved values that are not in the dropdown.
              if (_businessType.isNotEmpty &&
                  !_businessCategories.contains(_businessType))
                option(
                  value: _businessType,
                  attributes: {'selected': ''},
                  [Component.text(_businessType)],
                ),

              for (final category in _businessCategories)
                option(
                  value: category,
                  attributes: {if (_businessType == category) 'selected': ''},
                  [Component.text(category)],
                ),
            ],
          )
        else
          div(classes: 'chips', [
            for (final t in _propertyTypeOptions)
              label(
                classes: t == _propertyType ? 'checkpill is-on' : 'checkpill',
                [
                  input(
                    attributes: {
                      'type': 'radio',
                      'name': 'propertyType',
                      if (t == _propertyType) 'checked': '',
                    },
                    events: events(
                      onChange: (_) => setState(() => _propertyType = t),
                    ),
                  ),
                  span([Component.text(t)]),
                ],
              ),
          ]),
        span(classes: 'hint', [
          Component.text(
            _typesError == null
                ? 'Determines which listings are eligible.'
                : 'The property-type catalogue could not be loaded. Enter an '
                      'exact catalogue value; an unsupported value may match '
                      'no listings. $_typesError',
          ),
        ]),
      ]),

      // Business category describes the entrepreneur's concept; it is stored
      // separately from the property type instead of overwriting it.
      div(classes: 'field', [
        span(classes: 'field__label', [Component.text('Business category')]),
        input(
          attributes: {
            'type': 'text',
            'value': _businessType,
            'placeholder': 'e.g. Specialty coffee',
            if (_errors['business_type'] != null) 'aria-invalid': 'true',
          },
          events: events<String>(
            onInput: (v) => setState(() => _businessType = v),
          ),
        ),
        if (_errors['business_type'] != null)
          span(classes: 'field__error', [
            Component.text(_errors['business_type']!),
          ])
        else
          span(classes: 'hint', [
            Component.text(
              'Describes your concept. Shown on your recommendations and '
              'carried into every assessment; it does not filter the ranking.',
            ),
          ]),
      ]),

      div(classes: 'field', [
        span(classes: 'field__label', [Component.text('Target market')]),
        input(
          attributes: {
            'type': 'text',
            'value': _targetMarket,
            'placeholder': 'e.g. Office workers, students',
            if (_errors['target_market'] != null) 'aria-invalid': 'true',
          },
          events: events<String>(
            onInput: (v) => setState(() => _targetMarket = v),
          ),
        ),
        if (_errors['target_market'] != null)
          span(classes: 'field__error', [
            Component.text(_errors['target_market']!),
          ])
        else
          span(classes: 'hint', [
            Component.text(
              'Stored with your criteria and repeated in your assessment '
              'report; it does not filter the ranking.',
            ),
          ]),
      ]),

      div(classes: 'field', [
        span(classes: 'field__label', [Component.text('\u00a0')]),
        div(classes: 'actions-row', [
          ActionButton(
            _saving ? 'Saving…' : 'Save preferences',
            onClick: _saving ? null : _save,
          ),
          ActionButton(
            'Discard changes',
            variant: 'secondary',
            onClick: (_saving || !_dirty) ? null : _discard,
          ),
        ]),
      ]),
    ]),

    if (_errorMessage != null)
      div(classes: 'notice notice-warn', [Component.text(_errorMessage!)]),
    if (_savedMessage != null)
      div(classes: 'notice notice-info', [Component.text(_savedMessage!)]),
  ]);

  Component _numberField(
    String field,
    String label, {
    required String hint,
    required String value,
    required void Function(String) onChanged,
  }) => div(classes: 'field', [
    span(classes: 'field__label', [Component.text(label)]),
    input(
      attributes: {
        'type': 'number',
        'inputmode': 'numeric',
        'value': value,
        if (_errors[field] != null) 'aria-invalid': 'true',
      },
      events: events<String>(
        // Keep the raw text while the user types. Validation and parsing happen
        // together in _payload(), so clearing a field or entering a partial
        // number does not silently restore the previous value.
        onInput: onChanged,
      ),
    ),
    if (_errors[field] != null)
      span(classes: 'field__error', [Component.text(_errors[field]!)])
    else
      span(classes: 'hint', [Component.text(hint)]),
  ]);

  Component _loadingPanel() => div(classes: 'filters', [
    const Skeleton(variant: 'title'),
    div(classes: 'frow', [
      for (var i = 0; i < 4; i++) const Skeleton(variant: 'block', count: 2),
    ]),
  ]);

  Component _failurePanel() => div(classes: 'filters', [
    div(classes: 'notice notice-warn', [
      div([
        Component.text(
          _unauthorized
              ? 'Your session is not authorised to read these preferences.'
              : 'Your stored preferences could not be loaded.',
        ),
        span(classes: 'small asw-muted', [Component.text(' $_loadError')]),
      ]),
    ]),
    div(classes: 'actions-row', [
      if (_unauthorized)
        const ActionLink('Sign in', href: '/login')
      else
        ActionButton('Try again', onClick: _load),
    ]),
  ]);
}
