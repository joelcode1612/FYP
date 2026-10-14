import 'package:flutter/material.dart';

import '../../../core/theme/sitewise_theme.dart';

/// Hero suitability score ring + label.

class SitewiseEvidenceScore extends StatelessWidget {
  final double score;
  final String label;

  const SitewiseEvidenceScore({
    super.key,
    required this.score,
    this.label = 'Suitability',
  });

  /// Reads the shared ramp rather than re-deriving the thresholds, so this ring
  /// and every other score display stay in step (DESIGN.md §7.10).
  Color get _color => SitewiseScoreRamp.colorFor(score);

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 72,
          height: 72,
          child: Stack(
            alignment: Alignment.center,
            children: [
              CircularProgressIndicator(
                value: score / 100,
                strokeWidth: 8,
                backgroundColor: SitewiseColors.border,
                valueColor: AlwaysStoppedAnimation(_color),
              ),
              Text(
                score.toStringAsFixed(0),
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 18,
                  color: _color,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
              Text(
                'Evidence-weighted score from foot traffic, competition, '
                'accessibility and rental efficiency.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ],
    );
  }
}
