import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/ui.dart';
import '../../data/app_locator.dart';
import '../../layouts/app_layout.dart';

/// Web evaluation report: centred document-style card.
///
/// Ported from `entrepreneur_report_web_page.dart` in the Flutter web tree.
/// The property id travels as `?id=` instead of `settings.arguments`, and the
/// two nested FutureBuilders (property detail, then location analysis) are
/// kept exactly as the Flutter page structured them. "Back to property" is an
/// anchor back to the detail route instead of `Navigator.pop`.
class ReportPage extends StatelessComponent {
  /// The property id from the `?id=` query param.
  final String id;

  const ReportPage({super.key, required this.id});

  @override
  Component build(BuildContext context) {
    return AppLayout(
      role: AppRole.entrepreneur,
      currentRoute: '/entrepreneur/report',
      title: 'Evaluation report',
      subtitle: AppRole.entrepreneur.label,
      child: div(
        attributes: const {'style': 'max-width:900px'},
        classes: 'stack',
        [
          if (id.isEmpty)
            const _NotFound()
          else
            FutureBuilder<CommercialProperty?>(
              future: AppLocator.properties.detail(id),
              builder: (ctx, propSnap) {
                if (!propSnap.hasData) {
                  return const _Loading(message: 'Generating report…');
                }
                final p = propSnap.data!;
                return FutureBuilder<LocationAnalysis>(
                  future: AppLocator.recommendations.analysis(id),
                  builder: (c2, aSnap) {
                    if (!aSnap.hasData) {
                      return const _Loading(message: 'Generating report…');
                    }
                    return _ReportCard(property: p, analysis: aSnap.data!);
                  },
                );
              },
            ),
        ],
      ),
    );
  }
}

class _ReportCard extends StatelessComponent {
  final CommercialProperty property;
  final LocationAnalysis analysis;
  const _ReportCard({required this.property, required this.analysis});

  @override
  Component build(BuildContext context) {
    final a = analysis;
    return div(classes: 'card stack', [
      h1(classes: 'title-lg', [
        Component.text('Site evaluation — ${property.title}'),
      ]),
      p(classes: 'body', [
        Component.text(
          '${property.address}, ${property.city} · '
          'RM${property.rentalRm.toStringAsFixed(0)} · '
          '${property.sizeSqft.toStringAsFixed(0)} sq ft',
        ),
      ]),
      div(classes: 'divider', []),
      _EvidenceScore(score: a.suitabilityScore),
      div(classes: 'divider', []),
      p(classes: 'body', [Component.text(a.demandSummary)]),
      div(classes: 'divider', []),
      for (final f in a.factors) _FactorRow(factor: f),
      div(classes: 'divider', []),
      p(classes: 'body', [
        Component.text(
          'Recommendation: shortlist this unit if evening footfall and '
          'rental efficiency match your concept margins.',
        ),
      ]),
      ActionLink(
        'Back to property',
        href: '/entrepreneur/property-detail?id=${property.id}',
      ),
    ]);
  }
}

class _EvidenceScore extends StatelessComponent {
  final double score;
  const _EvidenceScore({required this.score});

  String get _toneClass => score >= 75
      ? 'text-success'
      : score >= 55
      ? 'text-action'
      : score >= 40
      ? 'text-warning'
      : 'text-danger';

  @override
  Component build(BuildContext context) {
    return div(
      attributes: const {'style': 'gap:12px'},
      classes: 'row row--top',
      [
        div(classes: 'metric $_toneClass', [
          Component.text(score.toStringAsFixed(0)),
        ]),
        div(classes: 'grow stack', [
          span(classes: 'title', [Component.text('Suitability')]),
          p(classes: 'small', [
            Component.text(
              'Evidence-weighted score from foot traffic, competition, '
              'accessibility and rental efficiency.',
            ),
          ]),
        ]),
      ],
    );
  }
}

class _FactorRow extends StatelessComponent {
  final LocationFactor factor;
  const _FactorRow({required this.factor});

  @override
  Component build(BuildContext context) {
    final tone = switch (factor.impact) {
      'Positive' => 'success',
      'Risk' => 'warning',
      _ => 'neutral',
    };
    final bucket = (((factor.score / 5).round()).clamp(1, 20)) * 5;
    return div(classes: 'stack', [
      div(
        attributes: const {'style': 'gap:8px'},
        classes: 'row',
        [
          span(classes: 'small grow', [Component.text(factor.name)]),
          Pill(factor.impact, tone: tone),
        ],
      ),
      span(classes: 'weights__track', [
        span(classes: 'weights__fill w-$bucket', []),
      ]),
      p(classes: 'small', [Component.text(factor.evidence)]),
    ]);
  }
}

class _Loading extends StatelessComponent {
  final String message;
  const _Loading({this.message = 'Loading…'});

  @override
  Component build(BuildContext context) {
    return div(classes: 'card', [
      p(classes: 'body muted', [Component.text(message)]),
    ]);
  }
}

class _NotFound extends StatelessComponent {
  const _NotFound();

  @override
  Component build(BuildContext context) {
    return div(classes: 'card stack', [
      span(classes: 'overline', [Component.text('Report')]),
      h2(classes: 'title-lg', [Component.text('Record not found')]),
      p(classes: 'body', [
        Component.text(
          'This report could not be generated — the property id is missing '
          'or the listing is unavailable.',
        ),
      ]),
      const ActionLink(
        'Back to explore',
        href: '/entrepreneur/explore',
        variant: 'secondary',
      ),
    ]);
  }
}
