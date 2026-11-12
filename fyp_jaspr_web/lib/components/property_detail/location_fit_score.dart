import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import '../../data/property_insights_api.dart';

/// The prominent "Location Fit" index for one property.
///
/// The number comes from the backend's deployed-model output, rescaled to
/// 0-100. It is a *relative association index*: how closely this location
/// resembles the operating F&B sites the model learned from. It is never
/// presented as a probability of success, and when the backend cannot produce
/// one the block says so instead of showing a placeholder.
class LocationFitScore extends StatelessComponent {
  final PropertyInsights insights;

  const LocationFitScore({super.key, required this.insights});

  @override
  Component build(BuildContext context) {
    final score = insights.score;
    final digest = insights.modelArtifactSha256;
    final digestPrefix = digest == null || digest.length < 12
        ? digest
        : digest.substring(0, 12);

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
          div(classes: 'sw-fit__eyebrow', [Component.text('Location suitability')]),
          h2(
            classes: 'sw-fit__title',
            attributes: const {'id': 'sw-fit-title'},
            [
              Component.text(
                score == null ? 'Score not available' : '${score.value} / ${score.scale}',
              ),
            ],
          ),
          p(classes: 'sw-fit__band', [
            Component.text(
              score?.band ??
                  'A location score is not available for this property yet.',
            ),
          ]),
          if (score != null) ...[
            div(classes: 'sw-fit__meta', [
              span(classes: 'sw-fit__kind', [Component.text('How similar this area is to other food-business locations')]),
              if (insights.modelArtifact != null) ...[
                span(classes: 'sw-fit__dot', attributes: const {'aria-hidden': 'true'}, const []),
                span([
                  Component.text(
                    '${insights.modelArtifact}'
                    '${digestPrefix == null ? '' : ' · SHA-256 $digestPrefix'}',
                  ),
                ]),
              ],
              span(classes: 'sw-fit__dot', attributes: const {'aria-hidden': 'true'}, const []),
              span([Component.text(score.sourceLabel)]),
            ]),
            p(classes: 'sw-fit__note', [Component.text(
              'This score compares the area with places where food businesses operate. '
              'It does not predict sales or guarantee success.',
            )]),
            if (insights.modelNotes.isNotEmpty)
              p(classes: 'sw-fit__note', [
                Component.text(insights.modelNotes.join(' ')),
              ]),
          ],
        ]),
      ],
    );
  }
}
