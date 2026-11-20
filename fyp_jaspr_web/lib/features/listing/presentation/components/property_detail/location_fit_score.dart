import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import 'package:sitewise_jaspr_web/features/listing/data/property_insights_api.dart';

/// The prominent "Location similarity" score for one property.
///
/// The number comes from the backend's deployed-model output, rescaled to
/// 0-100. It is a *relative association index*: how closely this location
/// resembles the operating F&B sites the model learned from. The block carries
/// the score, one short explanation, and a demoted audit line — model
/// provenance and feature coverage are kept for auditability but out of the
/// entrepreneur's reading path. When the backend cannot produce a score the
/// block says so instead of showing a placeholder, and when the artifact is
/// not marked production-ready a research-status warning stays visible.
class LocationFitScore extends StatelessComponent {
  final PropertyInsights insights;

  const LocationFitScore({super.key, required this.insights});

  @override
  Component build(BuildContext context) {
    final score = insights.score;

    return section(
      classes: 'sw-fit${score == null ? ' sw-fit--empty' : ''}',
      attributes: const {'aria-labelledby': 'sw-fit-title'},
      [
        div(
          classes: 'sw-fit__dial',
          attributes: {
            // Drives the conic-gradient sweep in CSS; absent when there is no
            // score so the dial renders empty rather than at zero.
            if (score != null) 'style': '--fit:${score.value}',
            'aria-hidden': 'true',
          },
          [
            div(classes: 'sw-fit__dial-inner', [
              strong([Component.text(score == null ? '—' : '${score.value}')]),
              span([Component.text(score == null ? '' : '/ ${score.scale}')]),
            ]),
          ],
        ),
        div(classes: 'sw-fit__body', [
          div(classes: 'sw-fit__eyebrow', [Component.text('Location similarity')]),
          h2(
            classes: 'sw-fit__title',
            attributes: const {'id': 'sw-fit-title'},
            [
              Component.text(
                score == null
                    ? 'Score not available'
                    : '${score.value} / ${score.scale}',
              ),
            ],
          ),
          if (score != null)
            p(classes: 'sw-fit__explain', [
              Component.text(
                // One short explanation: the backend's own band sentence when
                // it supplies one, otherwise the static similarity summary —
                // never both, which would read as a repeated summary.
                score.band.trim().isEmpty
                    ? 'This area has several characteristics similar to '
                        'locations where food businesses already operate.'
                    : score.band.trim(),
              ),
            ])
          else
            p(classes: 'sw-fit__explain', [
              Component.text(
                'A location score is not available for this property yet.',
              ),
            ]),
          if (insights.modelProductionReady == false)
            div(classes: 'sw-fit__warn', [
              Component.text(
                'Research status: this model is not marked production-ready, '
                'so treat this score as a research output.',
              ),
            ]),
          if (score != null)
            p(classes: 'sw-fit__audit', [Component.text(_auditLine())]),
        ]),
      ],
    );
  }

  /// Which artifact produced the number and how complete its input row was.
  /// Kept small and last so the page can still be audited against the
  /// research artifact without the provenance dominating the block.
  String _auditLine() {
    final version = insights.modelVersion ?? '';
    final sha = insights.modelArtifactSha256 ?? '';
    final coverage = insights.featureCoverage;
    final parts = [
      'Model ${insights.modelName}',
      if (version.isNotEmpty) version,
      if (sha.length >= 12) 'artifact ${sha.substring(0, 12)}…',
      if (coverage != null && coverage.featureCount > 0)
        'features resolved ${coverage.availableFeatures}/${coverage.featureCount}',
    ];
    return parts.join(' · ');
  }
}
