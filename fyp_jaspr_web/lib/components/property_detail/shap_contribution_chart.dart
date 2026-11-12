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
            [Component.text('Why this location received this score')],
          ),
          p(classes: 'sw-shap__lede', [
            Component.text(
              explanation == null
                  ? 'An explanation is not available for this property.'
                  : 'Each bar is one measured characteristic. Bars to the right '
                      'pushed the score up; bars to the left pulled it down.',
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
                '${explanation.explainer} over ${explanation.featureCount} '
                'measured features, compared with ${explanation.backgroundSize} '
                'similar analysed locations.',
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
                  showTechnical ? 'Hide technical detail' : 'Show technical detail',
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
      _summaryColumn('Factors supporting the result', supporting, true),
      _summaryColumn('Factors lowering the result', lowering, false),
    ]);
  }

  Component _summaryColumn(String title, List<InsightFactor> factors, bool positive) {
    return div(classes: 'sw-shap__col${positive ? ' is-up' : ' is-down'}', [
      h3(classes: 'sw-shap__col-title', [Component.text(title)]),
      if (factors.isEmpty)
        p(classes: 'sw-shap__col-empty', [
          Component.text(
            positive
                ? 'No measured factor pushed this score up.'
                : 'No measured factor pulled this score down.',
          ),
        ])
      else
        ul(classes: 'sw-shap__col-list', [
          for (final factor in factors)
            li([
              span(classes: 'sw-shap__col-label', [Component.text(factor.label)]),
              span(
                classes: 'sw-shap__col-value',
                attributes: {'title': 'Contribution ${_signed(factor.contribution)}'},
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
        Component.text('No factor contributions were returned for this property.'),
      ]);
    }
    final visible = showAll ? all : all.take(initialCount).toList();
    final maxAbs =
        all.fold<double>(0, (m, f) => f.contribution.abs() > m ? f.contribution.abs() : m);

    return div([
      div(classes: 'sw-shap__axis', attributes: const {'aria-hidden': 'true'}, [
        span(classes: 'sw-shap__axis-down', [Component.text('← lowers score')]),
        span(classes: 'sw-shap__axis-baseline', [Component.text('baseline')]),
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
                  ? 'Show the strongest $initialCount only'
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
        'title': '$spoken\nModel feature: ${factor.technical}',
      },
      [
        span(classes: 'sw-shap__label', [Component.text(factor.label)]),
        span(classes: 'sw-shap__track', attributes: const {'aria-hidden': 'true'}, [
          span(classes: 'sw-shap__bar', attributes: {'style': '--w:$width'}, const []),
        ]),
        span(classes: 'sw-shap__amount', [Component.text(_signed(factor.contribution))]),
        if (showTechnical) span(classes: 'sw-shap__code', [Component.text(factor.technical)]),
      ],
    );
  }

  // ---------------------------------------------------------------- technical

  Component _technical(InsightExplanation explanation) {
    final total =
        explanation.factors.fold<double>(0, (sum, f) => sum + f.contribution);
    return div(classes: 'sw-shap__tech', [
      h3([Component.text('Technical detail')]),
      dl([
        dt([Component.text('Model output (positive-label association)')]),
        dd([Component.text(explanation.output.toStringAsFixed(6))]),
        dt([Component.text('Baseline (background mean)')]),
        dd([Component.text(explanation.baseValue.toStringAsFixed(6))]),
        dt([Component.text('Baseline + contributions')]),
        dd([
          Component.text(
            '${(explanation.baseValue + total).toStringAsFixed(6)} '
            '${explanation.additivityOk ? '(reconciles)' : '(does not reconcile)'}',
          ),
        ]),
        dt([Component.text('Model version')]),
        dd([Component.text(explanation.modelVersion ?? insights.modelName)]),
        dt([Component.text('Explainer')]),
        dd([Component.text(explanation.explainer)]),
        dt([Component.text('Background rows')]),
        dd([Component.text('${explanation.backgroundSize}')]),
      ]),
      p(classes: 'sw-shap__tech-note', [
        Component.text(
          'Contributions are in the model output\'s own units, not points out of '
          '100. They sum with the baseline to the output shown above.',
        ),
      ]),
    ]);
  }

  static String _signed(double value) {
    final rounded = value.toStringAsFixed(3);
    return value > 0 ? '+$rounded' : rounded;
  }
}
