import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import '../../data/property_insights_api.dart';

/// The five location-analysis categories, each explaining its own SHAP
/// contributions.
///
/// The tabs are the brief's five questions — People Nearby, Other Food
/// Businesses, Nearby Places, Getting There, Parking Nearby — and the panel
/// below shows only the contributions that belong to the selected one. The
/// grouping is the backend's feature registry, so a category can never borrow
/// another category's factors.
///
/// When a category has no valid contributions it says so. Nothing is padded
/// with zeroes or a generic sentence.
///
/// Stateless by design: the selected tab lives in the page.
class CategoryExplanationPanel extends StatelessComponent {
  final PropertyInsights insights;

  /// The explicitly selected category key, or null to auto-open the most
  /// influential one.
  final String? selectedKey;
  final void Function(String key) onSelect;

  const CategoryExplanationPanel({
    super.key,
    required this.insights,
    required this.selectedKey,
    required this.onSelect,
  });

  /// Open on the category that moved the score most, so the first thing the
  /// entrepreneur reads is the most informative one.
  String? get _activeKey {
    if (selectedKey != null) return selectedKey;
    final lead = insights.leadCategory;
    if (lead != null) return lead.key;
    return insights.categories.isEmpty ? null : insights.categories.first.key;
  }

  InsightCategory? get _active {
    final key = _activeKey;
    for (final category in insights.categories) {
      if (category.key == key) return category;
    }
    return null;
  }

  @override
  Component build(BuildContext context) {
    final categories = insights.categories;
    if (categories.isEmpty) {
      return section(classes: 'sw-cats sw-cats--empty', [
        h2([Component.text('Location analysis')]),
        p([
          Component.text(
            insights.reason?.message ??
                'Location analysis is not available for this property.',
          ),
        ]),
      ]);
    }

    final active = _active;

    return section(
      classes: 'sw-cats',
      attributes: const {'aria-labelledby': 'sw-cats-title'},
      [
        header(classes: 'sw-cats__head', [
          h2(
            classes: 'sw-cats__title',
            attributes: const {'id': 'sw-cats-title'},
            [Component.text('What is around this location')],
          ),
          p(classes: 'sw-cats__lede', [
            Component.text(
              'Pick a category to see which measurements sit behind the score, '
              'and whether they raised or lowered it.',
            ),
          ]),
        ]),
        div(
          classes: 'sw-cats__nav',
          attributes: const {'role': 'tablist', 'aria-label': 'Location categories'},
          [
            for (final category in categories)
              button(
                classes: 'sw-cats__tab'
                    '${category.key == _activeKey ? ' is-active' : ''}'
                    '${category.available ? '' : ' is-empty'}',
                attributes: {
                  'type': 'button',
                  'role': 'tab',
                  'aria-selected': category.key == _activeKey ? 'true' : 'false',
                  'aria-controls': 'sw-cat-panel',
                  'id': 'sw-cat-tab-${category.key}',
                },
                events: events(onClick: () => onSelect(category.key)),
                [
                  span(classes: 'sw-cats__tab-label', [Component.text(category.label)]),
                  if (category.available)
                    span(
                      classes: 'sw-cats__tab-pip'
                          '${category.contribution >= 0 ? ' is-up' : ' is-down'}',
                      attributes: const {'aria-hidden': 'true'},
                      const [],
                    ),
                ],
              ),
          ],
        ),
        if (active != null) _panel(active),
      ],
    );
  }

  Component _panel(InsightCategory category) {
    final directionWord = category.contribution > 0
        ? 'raised'
        : (category.contribution < 0 ? 'lowered' : 'had no net effect on');

    return div(
      classes: 'sw-cats__panel',
      attributes: {
        'id': 'sw-cat-panel',
        'role': 'tabpanel',
        'aria-labelledby': 'sw-cat-tab-${category.key}',
      },
      [
        h3(classes: 'sw-cats__panel-title', [Component.text(category.label)]),
        p(classes: 'sw-cats__question', [Component.text(category.question)]),
        p(classes: 'sw-cats__why', [Component.text(category.why)]),
        if (!category.available)
          div(classes: 'sw-cats__unavailable', [
            Component.text(
              category.note ??
                  'No model features are grouped under this category for this '
                      'property, so there is nothing to explain here.',
            ),
          ])
        else ...[
          p(classes: 'sw-cats__verdict', [
            Component.text(
              'Together, the ${category.featureCount} '
              '${category.featureCount == 1 ? 'measurement' : 'measurements'} in '
              'this category $directionWord the score.',
            ),
          ]),
          div(classes: 'sw-cats__list', attributes: const {'role': 'list'}, [
            for (final factor in category.factors) _factorRow(factor, category),
          ]),
          p(classes: 'sw-cats__caveat', [
            Component.text(
              'Contributions are relative to this model and this property. They '
              'describe how the measurements moved the index, not what will '
              'happen at the shop.',
            ),
          ]),
        ],
      ],
    );
  }

  Component _factorRow(InsightFactor factor, InsightCategory category) {
    final positive = factor.increases;
    final maxAbs = category.factors.fold<double>(
      0,
      (m, f) => f.contribution.abs() > m ? f.contribution.abs() : m,
    );
    final share = (factor.shareOf(maxAbs) * 100).clamp(0.0, 100.0);

    return div(
      classes: 'sw-cats__row${positive ? ' is-up' : ' is-down'}',
      attributes: {
        'role': 'listitem',
        'title': '${factor.label}: ${factor.valueDisplay}. '
            'Contribution ${positive ? '+' : ''}${factor.contribution.toStringAsFixed(3)}.',
      },
      [
        span(classes: 'sw-cats__row-label', [Component.text(factor.label)]),
        span(classes: 'sw-cats__row-value', [Component.text(factor.valueDisplay)]),
        span(classes: 'sw-cats__row-track', attributes: const {'aria-hidden': 'true'}, [
          span(
            classes: 'sw-cats__row-bar',
            attributes: {'style': '--w:${share.toStringAsFixed(2)}%'},
            const [],
          ),
        ]),
        span(classes: 'sw-cats__row-effect', [
          Component.text(
            '${positive ? '+' : ''}${factor.contribution.toStringAsFixed(3)}',
          ),
        ]),
      ],
    );
  }
}
