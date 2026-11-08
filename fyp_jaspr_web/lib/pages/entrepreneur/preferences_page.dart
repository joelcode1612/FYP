import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/ui.dart';
import '../../data/app_locator.dart';
import '../../layouts/app_layout.dart';

/// Web preferences, laid out as the source's `preferences.html`.
///
/// ```text
/// .page-head   "Recommendations" · "Your preferences" · explanation
/// .section     "How preferences turn into a shortlist" · .quick (3 steps)
/// .filters     .frow of .field (rent + area ranges)
///              .frow of .field (type · business category · target market · save)
/// disclaimer
/// ```
///
/// The previous version was two generic `.card`s with two range sliders, so the
/// three-step explanation the source uses to justify the form was missing and
/// the numeric inputs were sliders rather than the source's labelled fields.
@client
class PreferencesPage extends StatefulComponent {
  const PreferencesPage({super.key});

  @override
  State<PreferencesPage> createState() => _PreferencesPageState();
}

class _PreferencesPageState extends State<PreferencesPage> {
  /// Every control maps 1:1 onto a [BusinessPreferences] field — no shared
  /// state and no dead handlers, so what the user entered is what gets saved.
  late String _businessType = AppLocator.preferences.businessType;
  late String _propertyType = AppLocator.preferences.propertyType;
  late double _minBudget = AppLocator.preferences.minBudgetRm;
  late double _budget = AppLocator.preferences.maxBudgetRm;
  late double _size = AppLocator.preferences.minSizeSqft;
  late double _maxSize = AppLocator.preferences.maxSizeSqft.isFinite
      ? AppLocator.preferences.maxSizeSqft
      : 3000;
  late String _targetMarket = AppLocator.preferences.requirements.join(', ');
  String? _savedSummary;
  bool _saving = false;

  /// Property types the recommendation engine can rank. Same vocabulary the
  /// source's checkpills use.
  static const _types = ['Cafe', 'Restaurant', 'Kiosk', 'Bakery', 'Other'];

  void _save() {
    if (_saving) return;
    setState(() => _saving = true);
    final value = BusinessPreferences(
      businessType: _businessType.trim(),
      propertyType: _propertyType,
      minBudgetRm: _minBudget,
      maxBudgetRm: _budget,
      minSizeSqft: _size,
      maxSizeSqft: _maxSize,
      // Target market is a single free-text field; it round-trips through the
      // first requirement entry so the saved value is what the form showed.
      requirements: _targetMarket.trim().isEmpty
          ? const []
          : [_targetMarket.trim()],
      preferredAreas: AppLocator.preferences.preferredAreas,
      seatingModel: AppLocator.preferences.seatingModel,
    );
    // The notifier applies the value AND the locator persists it (session
    // singleton + reload-surviving cookie), so the confirmation below states
    // what the ranking engine will actually read back.
    context.read(entrepreneurNotifierProvider.notifier).updatePreferences(value);
    AppLocator.persistPreferences(value);
    setState(() {
      _saving = false;
      _savedSummary =
          '${value.propertyType} · ${value.budgetDisplay} · '
          '${value.minSizeSqft.toStringAsFixed(0)}–'
          '${value.maxSizeSqft.toStringAsFixed(0)} sq ft'
          '${value.requirements.isEmpty ? '' : ' · target: ${value.requirements.first}'}';
    });
  }

  @override
  Component build(BuildContext context) {
    return AppLayout(
      role: AppRole.entrepreneur,
      currentRoute: '/entrepreneur/preferences',
      title: 'Your preferences',
      eyebrow: 'Recommendations',
      subtitle:
          'These values decide which properties are eligible and how candidates '
          'are ranked. They persist in this browser and are used by every '
          'ranking you see.',
      child: div(classes: 'stack stack--sections', [
        _explainer(),
        _form(),
        p(classes: 'disclaimer', [
          Component.text(
            'Preferences are a filter and a weighting, not a prediction. Changing '
            'them changes which listings are eligible and how the eligible ones '
            'are ordered — it does not change the underlying listing data.',
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
        'Scoring and ranking',
        'Eligible properties are scored on property and spatial features, then '
            'ordered by the result.',
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
        'Min monthly rent (RM)',
        hint: 'Properties below this are excluded.',
        value: _minBudget,
        min: 0,
        max: 20000,
        step: 100,
        onChanged: (v) => setState(() => _minBudget = v),
      ),
      _numberField(
        'Max monthly rent (RM)',
        hint: 'Hard eligibility cut-off for candidates.',
        value: _budget,
        min: 1500,
        max: 20000,
        step: 500,
        onChanged: (v) => setState(() => _budget = v),
      ),
      _numberField(
        'Min floor area (sq ft)',
        hint: 'Smaller units are excluded.',
        value: _size,
        min: 200,
        max: 3000,
        step: 100,
        onChanged: (v) => setState(() => _size = v),
      ),
      _numberField(
        'Max floor area (sq ft)',
        hint: 'Larger units are excluded.',
        value: _maxSize,
        min: 200,
        max: 10000,
        step: 100,
        onChanged: (v) => setState(() => _maxSize = v),
      ),
    ]),

    div(classes: 'frow', [
      // Property type as checkpills, as in the source. This is the field the
      // eligibility filter reads (`propertyType`) — single-choice radio group.
      div(classes: 'field', [
        span(classes: 'field__label', [Component.text('Property type')]),
        div(classes: 'chips', [
          for (final t in _types)
            label(classes: t == _propertyType ? 'checkpill is-on' : 'checkpill', [
              input(
                attributes: {
                  'type': 'radio',
                  'name': 'propertyType',
                  if (t == _propertyType) 'checked': '',
                },
                events: events(onChange: (_) => setState(() => _propertyType = t)),
              ),
              span([Component.text(t)]),
            ]),
        ]),
        span(classes: 'hint', [
          Component.text('Determines which listings are eligible.'),
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
            'placeholder': 'e.g. Cafe',
          },
          events: events<String>(onInput: (v) => setState(() => _businessType = v)),
        ),
        span(classes: 'hint', [
          Component.text('Describes your concept; kept with your profile.'),
        ]),
      ]),

      div(classes: 'field', [
        span(classes: 'field__label', [Component.text('Target market')]),
        input(
          attributes: {
            'type': 'text',
            'value': _targetMarket,
            'placeholder': 'e.g. Office workers, students',
          },
          events: events<String>(onInput: (v) => setState(() => _targetMarket = v)),
        ),
        span(classes: 'hint', [
          Component.text('Saved with your preferences as a requirement note.'),
        ]),
      ]),

      div(classes: 'field', [
        span(classes: 'field__label', [Component.text('\u00a0')]),
        div(classes: 'actions-row', [
          ActionButton(
            _saving ? 'Saving…' : 'Save preferences',
            onClick: _save,
          ),
          const ActionLink(
            'See recommendations',
            href: '/entrepreneur/recommendations',
            variant: 'secondary',
          ),
        ]),
      ]),
    ]),

    if (_savedSummary != null)
      div(classes: 'notice notice-info', [
        div([
          Component.text('Preferences saved and in use by your rankings.'),
          span(classes: 'small muted', [Component.text(' Saved criteria: $_savedSummary')]),
        ]),
      ]),
  ]);

  Component _numberField(
    String label, {
    required String hint,
    required double value,
    required double min,
    required double max,
    required double step,
    required void Function(double) onChanged,
  }) => div(classes: 'field', [
    span(classes: 'field__label', [Component.text(label)]),
    input(
      attributes: {
        'type': 'number',
        'min': min.toStringAsFixed(0),
        'max': max.toStringAsFixed(0),
        'step': step.toStringAsFixed(0),
        'inputmode': 'numeric',
        'value': value.toStringAsFixed(0),
      },
      events: events<String>(
        onInput: (raw) {
          final parsed = double.tryParse(raw.trim());
          if (parsed != null) onChanged(parsed);
        },
      ),
    ),
    span(classes: 'hint', [Component.text(hint)]),
  ]);
}
