import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import '../../data/property_insights_api.dart';

/// "How well this location matches your selected business type."
///
/// This is the Stage-2 (54-feature) block. It is deliberately separate from
/// [LocationFitScore] (the 64-feature general PU association) and from the
/// saved preference match:
///
/// * the number is the category classifier's output for the entrepreneur's
///   OWN selection, expressed on the model's 0–1 association scale;
/// * the factors are genuine permutation-SHAP contributions for that same
///   class — selecting Café explains Café even when the classifier ranks
///   Restaurant higher;
/// * the model's own top class is shown separately and never substituted for
///   the selection;
/// * the documented weak validation travels with the block, so it reads as
///   exploratory evidence rather than a recommendation of what to open.
class BusinessTypeFitPanel extends StatelessComponent {
  final PropertyInsights insights;

  const BusinessTypeFitPanel({super.key, required this.insights});

  @override
  Component build(BuildContext context) {
    final fit = insights.categoryFit;

    if (fit == null || !fit.available) {
      return section(classes: 'sw-bizfit sw-bizfit--empty', [
        h2(classes: 'sw-bizfit__title', [
          Component.text('How well this location matches your business type'),
        ]),
        p(classes: 'sw-bizfit__note', [
          Component.text(
            fit?.unavailableReason ??
                'Business-type matching is not available for this property yet. '
                    'No estimate is shown rather than an invented one.',
          ),
        ]),
      ]);
    }

    final selected = fit.selectedCategory;
    final explained = fit.explanation;
    final explainedType = explained?.businessType ?? '';
    final modelTop = fit.topCategory ?? '';
    final shownType = (selected?.businessType ?? '').isNotEmpty
        ? selected!.businessType
        : (explainedType.isNotEmpty ? explainedType : modelTop);
    final score = selected?.score ?? fit.topScore;
    final differsFromModelTop =
        modelTop.isNotEmpty && shownType.isNotEmpty && modelTop != shownType;

    return section(
      classes: 'sw-bizfit',
      attributes: const {'aria-labelledby': 'sw-bizfit-title'},
      [
        div(classes: 'sw-bizfit__head', [
          div(classes: 'sw-bizfit__eyebrow', [
            Component.text(
              selected == null
                  ? 'Model\'s strongest match here'
                  : 'Your selected business type',
            ),
          ]),
          h2(
            classes: 'sw-bizfit__title',
            attributes: const {'id': 'sw-bizfit-title'},
            [
              Component.text(
                shownType.isEmpty
                    ? 'How well this location matches your business type'
                    : 'How well this location matches $shownType',
              ),
            ],
          ),
          if (score != null)
            div(classes: 'sw-bizfit__score', [
              strong([Component.text(score.toStringAsFixed(2))]),
              span([Component.text('of 1.00')]),
              if (selected?.rank != null)
                span(classes: 'sw-bizfit__rank', [
                  Component.text('rank ${selected!.rank} of 4 types'),
                ]),
            ]),
          p(classes: 'sw-bizfit__lede', [
            Component.text(
              'This is how closely the area\'s measured characteristics resemble '
              'the places where ${shownType.isEmpty ? 'this type of' : shownType} '
              'businesses already operate. It is an association index, not the '
              'chance of success or a profit forecast.',
            ),
          ]),
        ]),

        if (differsFromModelTop)
          div(classes: 'sw-bizfit__alt', [
            Component.text(
              'The model\'s highest-ranked type at this location is $modelTop. '
              'Your selection ($shownType) is scored and explained on its own '
              'terms; it is not replaced by the model\'s preference.',
            ),
          ]),

        if (explained != null) ...[
          div(classes: 'sw-bizfit__meta', [
            span([
              Component.text(
                'Baseline ${explained.baseValue.toStringAsFixed(2)} + '
                'contributions = ${explained.reconstructed.toStringAsFixed(2)} '
                '(matches the model output)',
              ),
            ]),
            span([
              Component.text(
                '${explained.factors.length} measured factors · '
                '${explained.backgroundSize} reference locations',
              ),
            ]),
          ]),
          if (explained.factors.isEmpty)
            p(classes: 'sw-bizfit__note', [
              Component.text(
                'No factor moved this result materially, so no driver is listed.',
              ),
            ])
          else ...[
            h3(classes: 'sw-bizfit__sub', [
              Component.text('What pushes this match up or down'),
            ]),
            div(classes: 'sw-bizfit__rows', attributes: const {'role': 'list'}, [
              for (final factor in _ranked(explained.factors))
                _row(factor, explained.factors),
            ]),
          ],
        ] else
          div(classes: 'sw-bizfit__note', [
            Component.text(
              'The match value is available, but its factor breakdown is not. '
              'No explanation is invented to fill the gap.',
            ),
          ]),

        if (fit.reliability != null) _reliability(fit.reliability!),
      ],
    );
  }

  /// Strongest contributions first, in either direction.
  static List<InsightFactor> _ranked(List<InsightFactor> factors) {
    final sorted = [...factors]
      ..sort((left, right) => right.contribution.abs().compareTo(left.contribution.abs()));
    return sorted.take(8).toList();
  }

  Component _row(InsightFactor factor, List<InsightFactor> all) {
    final positive = factor.increases;
    final maxAbs = all.fold<double>(
      0,
      (m, f) => f.contribution.abs() > m ? f.contribution.abs() : m,
    );
    final share = maxAbs == 0
        ? 0.0
        : (factor.contribution.abs() / maxAbs * 100).clamp(0.0, 100.0);

    return div(
      classes: 'sw-bizfit__row${positive ? ' is-up' : ' is-down'}',
      attributes: {'role': 'listitem'},
      [
        span(classes: 'sw-bizfit__row-label', [Component.text(factor.label)]),
        span(classes: 'sw-bizfit__row-value', [
          Component.text(factor.valueDisplay),
        ]),
        span(
          classes: 'sw-bizfit__row-track',
          attributes: const {'aria-hidden': 'true'},
          [
            span(
              classes: 'sw-bizfit__row-bar',
              attributes: {'style': '--w:${share.toStringAsFixed(1)}%'},
              const [],
            ),
          ],
        ),
        span(classes: 'sw-bizfit__row-effect', [
          Component.text(
            '${positive ? '+' : ''}${factor.contribution.toStringAsFixed(2)}',
          ),
        ]),
      ],
    );
  }

  Component _reliability(CategoryReliability reliability) {
    final f1 = reliability.macroF1;
    final balanced = reliability.balancedAccuracy;
    final chance = reliability.chanceBalancedAccuracy;
    return div(classes: 'sw-bizfit__caveat', [
      Component.text(
        'Research use only. This model distinguishes four business types only '
        'weakly: on held-out areas it reached '
        '${f1 == null ? 'a low' : '${f1.toStringAsFixed(2)} macro-F1'} and '
        '${balanced == null ? 'a low' : '${balanced.toStringAsFixed(2)} balanced accuracy'}'
        '${chance == null ? '' : ' against ${chance.toStringAsFixed(2)} for random guessing'}. '
        'Treat the ranking as one piece of evidence, not as proof that this is '
        'the best business to open here.',
      ),
    ]);
  }
}
