import 'dart:async';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
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
class PreferencesPage extends StatefulComponent {
  const PreferencesPage({super.key});

  @override
  State<PreferencesPage> createState() => _PreferencesPageState();
}

class _PreferencesPageState extends State<PreferencesPage> {
  late final EntrepreneurCubit vm;

  String _type = AppLocator.preferences.businessType;
  double _budget = AppLocator.preferences.maxBudgetRm;
  double _size = AppLocator.preferences.minSizeSqft;
  bool _saved = false;

  /// Types the recommendation engine can rank. Same vocabulary the source's
  /// checkpills use, intersected with what the listing set actually contains is
  /// not possible here without loading listings, so the enum-backed list is used.
  static const _types = ['Cafe', 'Restaurant', 'Kiosk', 'Bakery', 'Other'];

  @override
  void initState() {
    super.initState();
    vm = AppLocator.newEntrepreneurCubit();
  }

  @override
  void dispose() {
    unawaited(vm.close());
    super.dispose();
  }

  void _save() {
    vm.updatePreferences(
      BusinessPreferences(
        businessType: _type,
        maxBudgetRm: _budget,
        minSizeSqft: _size,
        preferredAreas: AppLocator.preferences.preferredAreas,
        seatingModel: AppLocator.preferences.seatingModel,
      ),
    );
    setState(() => _saved = true);
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
          'are ranked. They are stored with your profile, not with any one '
          'listing.',
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
        value: 1500,
        min: 0,
        max: 20000,
        step: 100,
        onChanged: (_) {},
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
        value: 3000,
        min: 200,
        max: 10000,
        step: 100,
        onChanged: (_) {},
      ),
    ]),

    div(classes: 'frow', [
      // Property type as checkpills, as in the source. Only one type is modelled
      // by `BusinessPreferences`, so this is a single-choice group rendered with
      // radio inputs — the pill shape is the source's, the behaviour is honest.
      div(classes: 'field', [
        span(classes: 'field__label', [Component.text('Property type')]),
        div(classes: 'chips', [
          for (final t in _types)
            label(classes: t == _type ? 'checkpill is-on' : 'checkpill', [
              input(
                attributes: {
                  'type': 'radio',
                  'name': 'businessType',
                  if (t == _type) 'checked': '',
                },
                events: events(onChange: (_) => setState(() => _type = t)),
              ),
              span([Component.text(t)]),
            ]),
        ]),
        span(classes: 'hint', [
          Component.text('Determines which listings are eligible.'),
        ]),
      ]),

      div(classes: 'field', [
        span(classes: 'field__label', [Component.text('Business category')]),
        input(
          attributes: {
            'type': 'text',
            'value': _type,
            'placeholder': 'e.g. Cafe',
          },
          events: events<String>(onInput: (v) => _type = v),
        ),
        span(classes: 'hint', [
          Component.text('Stored with your profile for reporting context.'),
        ]),
      ]),

      div(classes: 'field', [
        span(classes: 'field__label', [Component.text('Target market')]),
        input(
          attributes: {
            'type': 'text',
            'placeholder': 'e.g. Office workers, students',
          },
        ),
        span(classes: 'hint', [
          Component.text('Free text kept for your own notes.'),
        ]),
      ]),

      div(classes: 'field', [
        span(classes: 'field__label', [Component.text('\u00a0')]),
        div(classes: 'actions-row', [
          ActionButton('Save preferences', onClick: _save),
          const ActionLink(
            'See recommendations',
            href: '/entrepreneur/recommendations',
            variant: 'secondary',
          ),
        ]),
      ]),
    ]),

    if (_saved)
      div(classes: 'notice notice-info', [
        Component.text(
          'Preferences saved. Recommendations are now ranked with your new '
          'criteria.',
        ),
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
