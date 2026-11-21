import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';

import 'package:fyp/core/di/service_locator.dart';
import 'package:fyp/core/config/mobile_config.dart';
import 'package:fyp/core/theme/sitewise_theme.dart';
import 'package:fyp/shared/presentation/layouts/mobile_app_shell.dart';

/// User Preferences — the same seven inputs, API contract and validation as
/// the Jaspr web `/entrepreneur/preferences` page, in a mobile-friendly form.
/// This remains the existing `/entrepreneur/preferences` route.
class EntrepreneurPreferencesMobilePage extends ConsumerStatefulWidget {
  const EntrepreneurPreferencesMobilePage({super.key});

  @override
  ConsumerState<EntrepreneurPreferencesMobilePage> createState() =>
      _EntrepreneurPreferencesMobilePageState();
}

class _EntrepreneurPreferencesMobilePageState
    extends ConsumerState<EntrepreneurPreferencesMobilePage> {
  static const _categories = <String>[
    'Cafe / Coffee Shop',
    'Restaurant',
    'Bakery / Dessert Shop',
    'Fast Food / Quick Service',
    'Beverage Shop / Kiosk',
    'Other F&B',
  ];

  /// Constructed by the composition root; the page never builds a repository.
  /// Constructed by the composition root; the page never builds a repository.
  late final _repository = ServiceLocator.userPreferences;
  final _minRent = TextEditingController();
  final _maxRent = TextEditingController();
  final _minSize = TextEditingController();
  final _maxSize = TextEditingController();
  final _targetMarket = TextEditingController();

  String _businessType = '';
  String _propertyType = 'Any';
  List<String>? _catalogueTypes;
  String? _catalogueError;
  String? _loadError;
  String? _saveError;
  String? _savedMessage;
  String? _savedAt;
  bool _loading = true;
  bool _saving = false;
  Map<String, String> _errors = {};
  Map<String, String> _baseline = {};
  int _formVersion = 0;

  @override
  void initState() {
    super.initState();
    // Build first, then read account state; never block the initial frame.
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _minRent.dispose();
    _maxRent.dispose();
    _minSize.dispose();
    _maxSize.dispose();
    _targetMarket.dispose();
    super.dispose();
  }

  static String _numberText(double value, {bool optional = false}) {
    if (!value.isFinite) return '';
    if (optional && value == 0) return '0';
    if (value == value.roundToDouble()) return value.toStringAsFixed(0);
    return value.toString();
  }

  static double _storedNumber(Map<String, dynamic>? raw, String key,
      double fallback) {
    final value = raw?[key];
    if (value is num) return value.toDouble();
    return fallback;
  }

  static List<String> _storedRequirements(Map<String, dynamic> raw) => [
        for (final item in (raw['requirements'] as List? ?? const [])) '$item',
      ];

  BusinessPreferences _modelFromStored(Map<String, dynamic> raw) {
    final before = ServiceLocator.preferences;
    return BusinessPreferences(
      businessType: raw['business_type'] as String? ?? before.businessType,
      propertyType: raw['property_type'] as String? ?? before.propertyType,
      preferredLocation: before.preferredLocation,
      minBudgetRm: _storedNumber(raw, 'min_budget_rm', before.minBudgetRm),
      maxBudgetRm: _storedNumber(raw, 'max_budget_rm', before.maxBudgetRm),
      minSizeSqft: _storedNumber(raw, 'min_size_sqft', before.minSizeSqft),
      maxSizeSqft: _storedNumber(raw, 'max_size_sqft', before.maxSizeSqft),
      requirements: _storedRequirements(raw),
      preferredAreas: [
        for (final item in (raw['preferred_areas'] as List? ?? before.preferredAreas))
          '$item',
      ],
      seatingModel: raw['seating_model'] as String? ?? before.seatingModel,
    );
  }

  /// Populate the controls from server values (or cached draft defaults).
  void _seed(Map<String, dynamic>? raw) {
    final fallback = ServiceLocator.preferences;
    _businessType = raw?['business_type'] as String? ?? fallback.businessType;
    final type = raw?['property_type'] as String? ?? fallback.propertyType;
    _propertyType = type.trim().isEmpty ? 'Any' : type;
    _minRent.text = _numberText(
      _storedNumber(raw, 'min_budget_rm', fallback.minBudgetRm),
      optional: true,
    );
    _maxRent.text = _numberText(
      _storedNumber(raw, 'max_budget_rm', fallback.maxBudgetRm),
    );
    _minSize.text = _numberText(
      _storedNumber(raw, 'min_size_sqft', fallback.minSizeSqft),
      optional: true,
    );
    _maxSize.text = _numberText(
      _storedNumber(raw, 'max_size_sqft', fallback.maxSizeSqft),
    );
    final market = raw?['target_market'] as String?;
    _targetMarket.text = market ??
        (raw == null
            ? fallback.requirements.join(', ')
            : _storedRequirements(raw).join(', '));
    _errors = {};
    _formVersion++;
    _baseline = _snapshot();
  }

  Map<String, String> _snapshot() => {
        'business_type': _businessType,
        'property_type': _propertyType,
        'min_budget_rm': _minRent.text,
        'max_budget_rm': _maxRent.text,
        'min_size_sqft': _minSize.text,
        'max_size_sqft': _maxSize.text,
        'target_market': _targetMarket.text,
      };

  bool get _dirty {
    final now = _snapshot();
    return now.keys.any((key) => now[key] != _baseline[key]);
  }

  Future<void> _load() async {
    if (_saving) return;
    setState(() {
      _loading = true;
      _loadError = null;
      _saveError = null;
      _savedMessage = null;
    });

    if (!MobileConfig.usesLiveApi) {
      if (!mounted) return;
      setState(() {
        _catalogueTypes = commercialPropertyTypeLabels;
        _catalogueError = null;
        _seed(null);
        _loading = false;
      });
      return;
    }

    try {
      final record = await _repository.load();
      List<String>? types;
      String? typesError;
      try {
        types = await _repository.propertyTypes();
      } on Object catch (error) {
        typesError = readableFailure(
          error,
          fallback: 'Could not load property types.',
        );
      }
      if (!mounted) return;
      // Only real saved legacy criteria should update the local ranking
      // profile. A v2/v3 assessment record must not be fabricated as v1.
      final raw = record.preferences;
      if (raw != null && raw.containsKey('business_type')) {
        ref.read(entrepreneurNotifierProvider.notifier)
            .updatePreferences(_modelFromStored(raw));
      }
      setState(() {
        _catalogueTypes = types;
        _catalogueError = typesError;
        _savedAt = record.updatedAt;
        _seed(raw);
        _loading = false;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = readableFailure(
          error,
          fallback: 'Could not load your saved preferences.',
        );
      });
    }
  }

  double? _parseNumber(String key, String raw,
      Map<String, String> errors, {bool required = false}) {
    final text = raw.trim();
    if (text.isEmpty) {
      if (required) errors[key] = 'This value is required.';
      return 0;
    }
    final parsed = double.tryParse(text);
    if (parsed == null || !parsed.isFinite) {
      errors[key] = 'Enter a valid number.';
      return null;
    }
    if (parsed < 0 || (required && parsed <= 0)) {
      errors[key] = required
          ? 'Enter a number greater than zero.'
          : 'Enter zero or a positive number.';
      return null;
    }
    return parsed;
  }

  Map<String, dynamic>? _payload() {
    final errors = <String, String>{};
    final category = _businessType.trim();
    final type = _propertyType.trim();
    final target = _targetMarket.text.trim();

    if (category.isEmpty) {
      errors['business_type'] = 'Select a business category.';
    } else if (category.length > 120) {
      errors['business_type'] = 'Use 120 characters or fewer.';
    }
    if (type.isEmpty) {
      errors['property_type'] = 'Choose a property type, or Any.';
    } else if (type.length > 60) {
      errors['property_type'] = 'Use 60 characters or fewer.';
    }
    if (target.length > 240) {
      errors['target_market'] = 'Use 240 characters or fewer.';
    }

    final minRent = _parseNumber('min_budget_rm', _minRent.text, errors);
    final maxRent = _parseNumber('max_budget_rm', _maxRent.text, errors,
        required: true);
    final minSize = _parseNumber('min_size_sqft', _minSize.text, errors);
    final maxSize = _parseNumber('max_size_sqft', _maxSize.text, errors,
        required: true);
    if (minRent != null && maxRent != null && minRent > maxRent) {
      errors['min_budget_rm'] = 'Minimum rent cannot exceed maximum rent.';
    }
    if (minSize != null && maxSize != null && minSize > maxSize) {
      errors['min_size_sqft'] = 'Minimum area cannot exceed maximum area.';
    }
    setState(() => _errors = errors);
    if (errors.isNotEmpty || minRent == null || maxRent == null ||
        minSize == null || maxSize == null) {
      return null;
    }

    return {
      'business_type': category,
      'property_type': type,
      'target_market': target,
      'min_budget_rm': minRent,
      'max_budget_rm': maxRent,
      'min_size_sqft': minSize,
      'max_size_sqft': maxSize,
      'requirements': target.isEmpty ? <String>[] : <String>[target],
    };
  }

  Future<void> _save() async {
    if (_loading || _saving) return;
    final values = _payload();
    if (values == null) return;
    setState(() {
      _saving = true;
      _saveError = null;
      _savedMessage = null;
    });
    try {
      if (MobileConfig.usesLiveApi) {
        final stored = await _repository.save(values);
        if (!mounted) return;
        final raw = stored.preferences;
        if (raw == null || !stored.saved) {
          throw StateError('The server did not confirm the saved preferences.');
        }
        ref.read(entrepreneurNotifierProvider.notifier)
            .updatePreferences(_modelFromStored(raw));
        setState(() {
          _savedAt = stored.updatedAt;
          _seed(raw);
          _savedMessage = 'Preferences saved to your account.';
        });
      } else {
        // Demo builds cannot truthfully claim an account-backed save.
        ref.read(entrepreneurNotifierProvider.notifier)
            .updatePreferences(_modelFromStored(values));
        setState(() {
          _seed(values);
          _savedMessage = 'Preferences saved on this device (demo mode).';
        });
      }
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _saveError = readableFailure(
          error,
          fallback: 'Could not save preferences. Nothing was changed.',
        );
      });
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _discard() {
    if (_saving || !_dirty) return;
    setState(() {
      _businessType = _baseline['business_type'] ?? '';
      _propertyType = _baseline['property_type'] ?? 'Any';
      _minRent.text = _baseline['min_budget_rm'] ?? '';
      _maxRent.text = _baseline['max_budget_rm'] ?? '';
      _minSize.text = _baseline['min_size_sqft'] ?? '';
      _maxSize.text = _baseline['max_size_sqft'] ?? '';
      _targetMarket.text = _baseline['target_market'] ?? '';
      _errors = {};
      _formVersion++;
      _saveError = null;
      _savedMessage = null;
    });
  }

  void _changed(String key) => setState(() {
        _errors.remove(key);
        _saveError = null;
        _savedMessage = null;
      });

  InputDecoration _decoration(String label, {
    String? hint,
    String? error,
    String? helper,
  }) => InputDecoration(
        labelText: label,
        hintText: hint,
        errorText: error,
        helperText: helper,
        helperMaxLines: 2,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      );

  Widget _numberInput(String key, String label, TextEditingController controller,
      {String? helper}) => TextField(
        controller: controller,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        onChanged: (_) => _changed(key),
        decoration: _decoration(label,
            error: _errors[key], hint: 'e.g. 2000', helper: helper),
      );

  Widget _categoryInput() {
    final values = <String>[
      if (_businessType.isNotEmpty && !_categories.contains(_businessType))
        _businessType,
      ..._categories,
    ];
    return DropdownButtonFormField<String>(
      key: ValueKey('category-$_businessType'),
      initialValue: _businessType.isEmpty ? '' : _businessType,
      isExpanded: true,
      decoration: _decoration('Business category',
          error: _errors['business_type']),
      items: [
        const DropdownMenuItem<String>(
          value: '', child: Text('Select business category'),
        ),
        for (final category in values)
          DropdownMenuItem<String>(value: category, child: Text(category)),
      ],
      onChanged: (value) {
        if (value == null) return;
        setState(() => _businessType = value);
        _changed('business_type');
      },
    );
  }

  Widget _propertyInput() {
    final types = _catalogueTypes;
    if (types == null) {
      return TextFormField(
        key: ValueKey('property-type-fallback-$_formVersion'),
        initialValue: _propertyType == 'Any' ? '' : _propertyType,
        onChanged: (value) {
          _propertyType = value.isEmpty ? 'Any' : value;
          _changed('property_type');
        },
        decoration: _decoration('Property type',
          hint: 'Any or exact catalogue property type',
          error: _errors['property_type'],
          helper: 'The property-type list is unavailable. Enter an exact type '
              'or leave empty for Any.'),
      );
    }
    final options = <String>{'Any', ...types, _propertyType}.toList();
    return DropdownButtonFormField<String>(
      key: ValueKey('property-type-$_propertyType'),
      initialValue: _propertyType,
      isExpanded: true,
      decoration: _decoration('Property type',
        error: _errors['property_type'],
        helper: 'Choose a commercial property type, or Any.'),
      items: [
        for (final type in options)
          DropdownMenuItem<String>(value: type, child: Text(type)),
      ],
      onChanged: (value) {
        if (value == null) return;
        setState(() => _propertyType = value);
        _changed('property_type');
      },
    );
  }

  Widget _inputSection(String title, String note, List<Widget> inputs) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(
              fontSize: 16, fontWeight: FontWeight.w800,
              color: SitewiseColors.ink,
            )),
            const SizedBox(height: 4),
            Text(note, style: const TextStyle(
              fontSize: 12, height: 1.45, color: SitewiseColors.muted,
            )),
            const SizedBox(height: 14),
            ...[
              for (final input in inputs) ...[
                input,
                const SizedBox(height: 14),
              ],
            ],
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    return MobileAppShell(
      title: 'User Preferences',
      currentRoute: '/entrepreneur/preferences',
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _loadError != null
              ? Center(child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.wifi_off_outlined, size: 36,
                        color: SitewiseColors.muted),
                    const SizedBox(height: 12),
                    const Text('Unable to load your preferences',
                        style: TextStyle(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 8),
                    Text(_loadError!, textAlign: TextAlign.center),
                    const SizedBox(height: 16),
                    OutlinedButton.icon(onPressed: _load,
                        icon: const Icon(Icons.refresh), label: const Text('Retry')),
                  ]),
                ))
              : SingleChildScrollView(
                  keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                  padding: const EdgeInsets.fromLTRB(16, 20, 16, 36),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 620),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Text('Your property requirements',
                            style: TextStyle(fontSize: 22,
                              fontWeight: FontWeight.w800,
                              color: SitewiseColors.ink)),
                          const SizedBox(height: 6),
                          const Text('Set the rental, size, property type and '
                            'business details used when comparing locations.',
                            style: TextStyle(fontSize: 13, height: 1.5,
                                color: SitewiseColors.muted)),
                          const SizedBox(height: 22),
                          _inputSection('Monthly rental',
                            'Specify the price range you are comfortable with.', [
                            _numberInput('min_budget_rm', 'Min monthly rent (RM)',
                                _minRent, helper: 'Enter 0 for no minimum.'),
                            _numberInput('max_budget_rm', 'Max monthly rent (RM)',
                                _maxRent, helper: 'Required; greater than 0.'),
                          ]),
                          _inputSection('Floor area',
                            'Choose the amount of space your business needs.', [
                            _numberInput('min_size_sqft', 'Min floor area (sq ft)',
                                _minSize, helper: 'Enter 0 for no minimum.'),
                            _numberInput('max_size_sqft', 'Max floor area (sq ft)',
                                _maxSize, helper: 'Required; greater than 0.'),
                          ]),
                          _inputSection('Your business',
                            'The commercial unit and your F&B concept are '
                            'different types of information.', [
                            _propertyInput(),
                            _categoryInput(),
                            TextField(
                              controller: _targetMarket,
                              onChanged: (_) => _changed('target_market'),
                              decoration: _decoration('Target market',
                                  hint: 'e.g. Office workers, students',
                                  error: _errors['target_market'],
                                  helper: 'Optional. Can contain multiple '
                                      'customer groups.'),
                            ),
                          ]),
                          if (_catalogueError != null)
                            Padding(padding: const EdgeInsets.only(bottom: 14),
                              child: Text('Property-type options are unavailable: '
                                '$_catalogueError',
                                style: const TextStyle(fontSize: 12,
                                    color: SitewiseColors.muted))),
                          if (_saveError != null)
                            Padding(padding: const EdgeInsets.only(bottom: 14),
                              child: Text(_saveError!,
                                style: const TextStyle(color: Color(0xFFB42318),
                                    fontWeight: FontWeight.w600))),
                          if (_savedMessage != null)
                            Padding(padding: const EdgeInsets.only(bottom: 14),
                              child: Row(children: [
                                const Icon(Icons.check_circle_outline,
                                    size: 19, color: Color(0xFF087443)),
                                const SizedBox(width: 8),
                                Expanded(child: Text(_savedMessage!,
                                  style: const TextStyle(color: Color(0xFF087443),
                                      fontWeight: FontWeight.w600))),
                              ])),
                          FilledButton.icon(
                            onPressed: _saving ? null : _save,
                            icon: _saving
                                ? const SizedBox(height: 18, width: 18,
                                    child: CircularProgressIndicator(strokeWidth: 2,
                                      color: Colors.white))
                                : const Icon(Icons.save_outlined),
                            label: Text(_saving ? 'Saving…' : 'Save preferences'),
                            style: FilledButton.styleFrom(
                              minimumSize: const Size.fromHeight(50),
                              backgroundColor: SitewiseColors.action),
                          ),
                          const SizedBox(height: 10),
                          OutlinedButton(
                            onPressed: _saving || !_dirty ? null : _discard,
                            style: OutlinedButton.styleFrom(
                                minimumSize: const Size.fromHeight(48)),
                            child: const Text('Discard changes'),
                          ),
                          const SizedBox(height: 16),
                          const Text('Preferences guide filtering and ordering. '
                            'They do not predict whether a business will succeed.',
                            style: TextStyle(fontSize: 12,
                                height: 1.5, color: SitewiseColors.muted)),
                          if (_savedAt != null) ...[
                            const SizedBox(height: 6),
                            Text('Last saved: $_savedAt',
                                style: const TextStyle(fontSize: 11,
                                    color: SitewiseColors.muted)),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
    );
  }
}
