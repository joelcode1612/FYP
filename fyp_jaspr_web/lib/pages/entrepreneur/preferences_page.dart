import 'dart:async';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/ui.dart';
import '../../data/app_locator.dart';
import '../../layouts/app_layout.dart';

/// Web preferences: two-column form with an explainer card.
///
/// Ported from `entrepreneur_preferences_web_page.dart` in the Flutter web
/// tree. The form writes into a local copy of [BusinessPreferences] and calls
/// `vm.updatePreferences(...)` on Save — which also writes the app-wide
/// `AppLocator.preferences` through the cubit's `onPreferencesUpdated`
/// callback. The Flutter version navigates to Recommendations after saving;
/// here the success is an inline card with a link, so it works without
/// JavaScript.
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
      title: 'Business preferences',
      subtitle: AppRole.entrepreneur.label,
      child: div(
        attributes: const {'style': 'gap:16px'},
        classes: 'row row--top',
        [
          div(classes: 'grow', [
            div(classes: 'card stack', [
              div(classes: 'stack', [
                span(classes: 'small', [Component.text('Business type')]),
                input(
                  classes: 'input',
                  attributes: {'type': 'text', 'value': _type},
                  events: events<String>(onInput: (v) => _type = v),
                ),
              ]),
              p(classes: 'body', [
                Component.text('Max budget: RM${_budget.toStringAsFixed(0)}'),
              ]),
              input(
                attributes: {
                  'type': 'range',
                  'min': '1500',
                  'max': '12000',
                  'step': '500',
                  'value': _budget.toStringAsFixed(0),
                  'aria-label': 'Max budget',
                },
                events: events<String>(
                  onInput: (v) =>
                      setState(() => _budget = double.tryParse(v) ?? _budget),
                ),
              ),
              p(classes: 'body', [
                Component.text('Min size: ${_size.toStringAsFixed(0)} sq ft'),
              ]),
              input(
                attributes: {
                  'type': 'range',
                  'min': '200',
                  'max': '3000',
                  'step': '200',
                  'value': _size.toStringAsFixed(0),
                  'aria-label': 'Min size in square feet',
                },
                events: events<String>(
                  onInput: (v) =>
                      setState(() => _size = double.tryParse(v) ?? _size),
                ),
              ),
              ActionButton(
                'Save & see recommendations',
                icon: 'auto_awesome',
                onClick: _save,
              ),
              if (_saved)
                div(classes: 'card stack', [
                  span(classes: 'small text-success', [
                    Component.text(
                      'Preferences saved. Recommendations are now ranked with '
                      'your new criteria.',
                    ),
                  ]),
                  const ActionLink(
                    'See recommendations',
                    href: '/entrepreneur/recommendations',
                    variant: 'secondary',
                  ),
                ]),
            ]),
          ]),
          div(classes: 'w-35', [
            div(classes: 'card stack', [
              span(classes: 'title', [Component.text('How ranking works')]),
              p(classes: 'body', [
                Component.text(
                  'Sitewise scores every listing on population, accessibility, '
                  'transportation, competition, demand and rental fit — '
                  'then ranks the best matches for your concept, budget '
                  'and size.',
                ),
              ]),
            ]),
          ]),
        ],
      ),
    );
  }
}
