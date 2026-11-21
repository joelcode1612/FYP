import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import 'package:sitewise_jaspr_web/features/listing/data/property_insights_api.dart';

/// The compact entrepreneur-facing SHAP explanation for the location score.
///
/// Shows at most the two strongest supporting and two strongest lowering
/// factors, taken from the backend's ranked SHAP response — nothing is
/// recomputed, renamed or invented client-side. Each factor carries its
/// plain-English label, its recorded measurement, a directional bar on a
/// shared centre line scaled by relative magnitude, and one business-relevant
/// sentence. Raw SHAP numbers stay in the data model and are never printed.
///
/// Missing-data states are honest: fewer factors are shown when fewer exist,
/// an empty side says so rather than showing zeroes, and an unavailable
/// explanation shows the backend's reason instead of a fabricated breakdown.
///
/// Stateless by design: there is no interaction state to hold.
class CompactLocationExplanation extends StatelessComponent {
  final PropertyInsights insights;

  const CompactLocationExplanation({super.key, required this.insights});

  @override
  Component build(BuildContext context) {
    final explanation = insights.explanation;

    return section(
      classes: 'sw-explain',
      attributes: const {'aria-labelledby': 'sw-explain-title'},
      [
        h2(
          classes: 'sw-explain__title',
          attributes: const {'id': 'sw-explain-title'},
          [Component.text('Why this area received its score')],
        ),
        if (explanation == null)
          div(classes: 'sw-explain__empty', [
            Component.text(
              insights.reason?.message ??
                  'An explanation is not available for this property.',
            ),
          ])
        else ...[
          p(classes: 'sw-explain__lede', [
            Component.text(
              'The measurements that moved the score most, in each direction.',
            ),
          ]),
          _columns(explanation),
        ],
      ],
    );
  }

  Component _columns(InsightExplanation explanation) {
    final supporting = _strongest(
      explanation.strongestSupporting,
      explanation.factors,
      (f) => f.increases,
    );
    final lowering = _strongest(
      explanation.strongestLowering,
      explanation.factors,
      (f) => f.decreases,
    );

    if (supporting.isEmpty && lowering.isEmpty) {
      return div(classes: 'sw-explain__empty', [
        Component.text(
          'No measured factor clearly raised or lowered the score for this '
          'property.',
        ),
      ]);
    }

    // The four visible bars share one scale: each width is its contribution's
    // share of the largest displayed one, so relative magnitude stays
    // comparable without printing a single number.
    final maxAbs = [
      ...supporting,
      ...lowering,
    ].fold<double>(0, (m, f) => f.contribution.abs() > m ? f.contribution.abs() : m);

    return div(classes: 'sw-explain__cols', [
      _column(
        title: 'What to check',
        arrow: '←',
        positive: false,
        note: 'These measurements pulled the score down. They are worth '
            'checking on site — they are not proof of a problem.',
        factors: lowering,
        maxAbs: maxAbs,
      ),
      _column(
        title: 'What supports the score',
        arrow: '→',
        positive: true,
        note: 'These measurements raised the score against typical areas in '
            'the model.',
        factors: supporting,
        maxAbs: maxAbs,
      ),
    ]);
  }

  /// The two strongest factors on one side: the backend's ranked list when it
  /// has one, otherwise the full factor list sorted by contribution size.
  List<InsightFactor> _strongest(
    List<InsightFactor> ranked,
    List<InsightFactor> all,
    bool Function(InsightFactor factor) side,
  ) {
    final fromRanked = [for (final f in ranked) if (side(f)) f];
    if (fromRanked.isNotEmpty) return fromRanked.take(2).toList();
    final fallback = [for (final f in all) if (side(f)) f]
      ..sort((x, y) => y.contribution.abs().compareTo(x.contribution.abs()));
    return fallback.take(2).toList();
  }

  Component _column({
    required String title,
    required String arrow,
    required bool positive,
    required String note,
    required List<InsightFactor> factors,
    required double maxAbs,
  }) {
    return div(classes: 'sw-explain__col${positive ? ' is-up' : ' is-down'}', [
      h3(classes: 'sw-explain__col-title', [
        span(
          classes: 'sw-explain__col-arrow',
          attributes: const {'aria-hidden': 'true'},
          [Component.text(arrow)],
        ),
        Component.text(title),
      ]),
      p(classes: 'sw-explain__col-note', [Component.text(note)]),
      if (factors.isEmpty)
        div(classes: 'sw-explain__empty sw-explain__empty--col', [
          Component.text(
            positive
                ? 'No measured factor raised the score.'
                : 'No measured factor lowered the score.',
          ),
        ])
      else
        div(classes: 'sw-explain__items', attributes: const {'role': 'list'}, [
          for (final factor in factors) _factor(factor, positive, maxAbs),
        ]),
    ]);
  }

  Component _factor(InsightFactor factor, bool positive, double maxAbs) {
    final share = (factor.shareOf(maxAbs) * 100).clamp(2.0, 100.0);
    final measured = factor.valueDisplay.trim();
    final hasMeasured = measured.isNotEmpty && measured != 'not measured';
    final spoken = '${factor.label}'
        '${hasMeasured ? ', measured $measured' : ''}. '
        '${positive ? 'Raised' : 'Lowered'} the score.';

    return div(
      classes: 'sw-explain__item is-${positive ? 'up' : 'down'}',
      attributes: {'role': 'listitem', 'aria-label': spoken},
      [
        span(classes: 'sw-explain__item-label', [Component.text(factor.label)]),
        span(
          classes: 'sw-explain__track',
          attributes: const {'aria-hidden': 'true'},
          [
            span(
              classes: 'sw-explain__bar',
              attributes: {'style': '--w:${share.toStringAsFixed(2)}%'},
              const [],
            ),
          ],
        ),
        p(classes: 'sw-explain__item-why', [
          Component.text([
            if (hasMeasured) 'Measured: $measured.',
            _angle(factor, positive),
          ].join(' ')),
        ]),
      ],
    );
  }

  /// One business-relevant sentence per factor topic, hedged so it explains
  /// why the topic matters without claiming a guaranteed outcome or turning a
  /// negative contribution into a statement about the site itself.
  String _angle(InsightFactor factor, bool positive) => switch (factor.category) {
    'population' => positive
        ? 'More people living nearby can mean more potential customers.'
        : 'Fewer people living nearby may mean a smaller local customer base.',
    'competitors' => positive
        ? 'Food businesses nearby can draw hungry visitors to the area.'
        : 'Competing food businesses nearby may take a share of the same customers.',
    'demand_generators' => positive
        ? 'Nearby shops, offices and schools bring regular foot traffic.'
        : 'Fewer nearby destinations can mean less passing foot traffic.',
    'accessibility' => positive
        ? 'Good road and transport links make the site easier to reach.'
        : 'Weaker transport links can make the site harder to reach.',
    'parking' => positive
        ? 'Nearby parking makes visits easier for customers who drive.'
        : 'Less parking nearby may put off customers who drive.',
    'housing' => positive
        ? 'Residents nearby can support regular repeat visits.'
        : 'Fewer homes nearby may mean fewer repeat local customers.',
    _ => positive
        ? 'The model found this measurement helpful for the score.'
        : 'The model read this measurement as pulling the score down.',
  };
}
