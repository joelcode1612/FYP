import 'package:flutter/material.dart';

import '../../../core/theme/sitewise_theme.dart';

/// Colour band for a 0–100 suitability score.
///
/// Delegates to [SitewiseScoreRamp] — the single source of truth shared with the
/// evidence ring and the progress bar. This function previously carried its own
/// copy of the thresholds, as did two other widgets, so a change to one band
/// could silently desync the others.
Color suitabilityColor(double score) => SitewiseScoreRamp.colorFor(score);

/// Compact "location suitability for your business" indicator.
///
/// Deliberately reads as a location-fit score, not a financial rating: a thin
/// ring, a plain number and the word *Suitability*.
class MobileSuitabilityBadge extends StatelessWidget {
  final double score;

  /// Compact drops the ring and the label (used inside tight list rows).
  final bool compact;

  const MobileSuitabilityBadge({
    super.key,
    required this.score,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = suitabilityColor(score);

    if (compact) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          score.toStringAsFixed(0),
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w800,
            color: color,
          ),
        ),
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 34,
          height: 34,
          child: Stack(
            alignment: Alignment.center,
            children: [
              CircularProgressIndicator(
                value: (score / 100).clamp(0.0, 1.0).toDouble(),
                strokeWidth: 3.5,
                backgroundColor: SitewiseColors.border,
                valueColor: AlwaysStoppedAnimation<Color>(color),
              ),
              Text(
                score.toStringAsFixed(0),
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  color: color,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              score.toStringAsFixed(0),
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w800,
                color: SitewiseColors.ink,
                height: 1.1,
              ),
            ),
            const Text(
              'Suitability',
              style: TextStyle(fontSize: 10, color: SitewiseColors.muted),
            ),
          ],
        ),
      ],
    );
  }
}
