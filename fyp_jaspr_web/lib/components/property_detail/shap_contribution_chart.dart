import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import '../../data/property_insights_api.dart';

/// "Why this location received this score" — a horizontal contribution chart.
///
/// Bars grow right for factors that **raise** the model output and left for
/// factors that **lower** it, measured from a centre baseline. Labels are the
/// backend's plain-English names; the raw model column is available only behind
/// the optional technical toggle, because `population_500m` means nothing to an
/// entrepreneur.
///
/// Bar length is each contribution's share of the largest absolute
/// contribution in the set. That makes the *relative* influence readable; the
/// absolute numbers stay in the tooltip and the accessible label so the chart
/// cannot be mistaken for a percentage.
///
/// Stateless by design: the disclosure state lives in the page, because Jaspr's
/// `@client` boundary (the page) is the only component allowed to hold
/// interaction state.
class ShapContributionChart extends StatelessComponent {
  final PropertyInsights insights;

  /// How many factors are shown before "show all" is offered.
  final int initialCount;

  final bool showAll;
  final bool showTechnical;
  final void Function() onToggleAll;
  final void Function() onToggleTechnical;

  const ShapContributionChart({
    super.key,
    required this.insights,
    required this.showAll,
    required this.showTechnical,
    required this.onToggleAll,
    required this.onToggleTechnical,
    this.initialCount = 10,
  });

  @override
  Component build(BuildContext context) {
    final explanation = insights.explanation;

    return section(
      classes: 'sw-shap',
      attributes: const {'aria-labelledby': 'sw-shap-title'},
      [
        header(classes: 'sw-shap__head', [
          h2(
            classes: 'sw-shap__title',
            attributes: const {'id': 'sw-shap-title'},
            [Component.text('What affects this location score?')],
          ),
          p(classes: 'sw-shap__lede', [
            Component.text(
              explanation == null
                  ? 'An explanation is not available for this property.'
                  : 'Each bar shows something about the area. Bars on the right '
                      'raised the score; bars on the left lowered it.',
            ),
          ]),
        ]),
        if (explanation == null)
          div(classes: 'sw-shap__empty', [
            Component.text(
              insights.reason?.message ??
                  'The explanation could not be produced, so none is shown.',
            ),
          ])
        else ...[
          _summary(explanation),
          _chart(explanation),
          footer(classes: 'sw-shap__foot', [
            p(classes: 'sw-shap__method', [
              Component.text(
                'This explanation uses ${explanation.featureCount} measurements '
                'of the surrounding area.',
              ),
            ]),
            button(
              classes: 'sw-shap__toggle',
              attributes: {
                'type': 'button',
                'aria-pressed': showTechnical ? 'true' : 'false',
              },
              events: events(onClick: onToggleTechnical),
              [
                Component.text(
                  showTechnical ? 'Hide score details' : 'See score details',
                ),
              ],
            ),
          ]),
          if (showTechnical) _technical(explanation),
        ],
      ],
    );
  }

  // ------------------------------------------------------------------ summary

  Component _summary(InsightExplanation explanation) {
    final supporting = explanation.strongestSupporting;
    final lowering = explanation.strongestLowering;
    if (supporting.isEmpty && lowering.isEmpty) return const Component.fragment([]);

    return div(classes: 'sw-shap__summary', [
      _summaryColumn('What helped the score', supporting, true),
      _summaryColumn('What lowered the score', lowering, false),
    ]);
  }

  Component _summaryColumn(String title, List<InsightFactor> factors, bool positive) {
    return div(classes: 'sw-shap__col${positive ? ' is-up' : ' is-down'}', [
      h3(classes: 'sw-shap__col-title', [Component.text(title)]),
      if (factors.isEmpty)
        p(classes: 'sw-shap__col-empty', [
          Component.text(
            positive
                ? 'No measured factor increased this score.'
                : 'No measured factor reduced this score.',
          ),
        ])
      else
        ul(classes: 'sw-shap__col-list', [
          for (final factor in factors)
            li([
              span(classes: 'sw-shap__col-label', [Component.text(factor.label)]),
              span(
                classes: 'sw-shap__col-value',
                attributes: {'title': 'Effect on score: ${_signed(factor.contribution)}'},
                [Component.text(_signed(factor.contribution))],
              ),
            ]),
        ]),
    ]);
  }

  // -------------------------------------------------------------------- chart

  Component _chart(InsightExplanation explanation) {
    final all = explanation.factors;
    if (all.isEmpty) {
      return div(classes: 'sw-shap__empty', [
        Component.text('We do not have enough information to show which factors affected this score.'),
      ]);
    }
    final visible = showAll ? all : all.take(initialCount).toList();
    final maxAbs =
        all.fold<double>(0, (m, f) => f.contribution.abs() > m ? f.contribution.abs() : m);

    return div([
      div(classes: 'sw-shap__axis', attributes: const {'aria-hidden': 'true'}, [
        span(classes: 'sw-shap__axis-down', [Component.text('← lowers score')]),
        span(classes: 'sw-shap__axis-baseline', [Component.text('starting point')]),
        span(classes: 'sw-shap__axis-up', [Component.text('raises score →')]),
      ]),
      div(classes: 'sw-shap__rows', attributes: const {'role': 'list'}, [
        for (final factor in visible) _row(factor, maxAbs),
      ]),
      if (all.length > initialCount)
        button(
          classes: 'sw-shap__more',
          attributes: {'type': 'button', 'aria-expanded': showAll ? 'true' : 'false'},
          events: events(onClick: onToggleAll),
          [
            Component.text(
              showAll
                  ? 'Show top $initialCount factors'
                  : 'Show all ${all.length} factors',
            ),
          ],
        ),
    ]);
  }

  Component _row(InsightFactor factor, double maxAbs) {
    final share = (factor.shareOf(maxAbs) * 100).clamp(0.6, 100.0);
    final positive = factor.increases;
    final width = '${share.toStringAsFixed(2)}%';
    final spoken = '${factor.label}: ${factor.valueDisplay}. '
        '${positive ? 'Raises' : 'Lowers'} the score by '
        '${factor.contribution.abs().toStringAsFixed(3)}. '
        'Category: ${factor.categoryLabel}.';

    return div(
      classes: 'sw-shap__row${positive ? ' is-up' : ' is-down'}',
      attributes: {
        'role': 'listitem',
        'aria-label': spoken,
        'title': spoken,
      },
      [
        span(classes: 'sw-shap__label', [Component.text(factor.label)]),
        span(classes: 'sw-shap__track', attributes: const {'aria-hidden': 'true'}, [
          span(classes: 'sw-shap__bar', attributes: {'style': '--w:$width'}, const []),
        ]),
        span(classes: 'sw-shap__amount', [Component.text(_signed(factor.contribution))]),
      ],
    );
  }

  // ---------------------------------------------------------------- technical

  Component _technical(InsightExplanation explanation) {
    final total =
        explanation.factors.fold<double>(0, (sum, f) => sum + f.contribution);
    return div(classes: 'sw-shap__tech', [
      h3([Component.text('How the score is calculated')]),
      dl([
        dt([Component.text('Calculation result')]),
        dd([Component.text(explanation.output.toStringAsFixed(6))]),
        dt([Component.text('Starting value for comparison')]),
        dd([Component.text(explanation.baseValue.toStringAsFixed(6))]),
        dt([Component.text('Value after the changes shown above')]),
        dd([
          Component.text(
            '${(explanation.baseValue + total).toStringAsFixed(6)} '
            '${explanation.additivityOk ? '(reconciles)' : '(does not reconcile)'}',
          ),
        ]),
        dt([Component.text('Locations used for comparison')]),
        dd([Component.text('${explanation.backgroundSize}')]),
      ]),
      p(classes: 'sw-shap__tech-note', [
        Component.text(
          'These detailed values use a different scale from the 0–100 score '
          'above. They explain the calculation, not your chances of success.',
        ),
      ]),
    ]);
  }

  static String _signed(double value) {
    final rounded = value.toStringAsFixed(3);
    return value > 0 ? '+$rounded' : rounded;
  }
}
