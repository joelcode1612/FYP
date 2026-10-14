import 'package:flutter/material.dart';

import '../../../core/theme/sitewise_theme.dart';

/// Score bar used for suitability + evidence scores.

class SitewiseProgressIndicator extends StatelessWidget {
  final double value; // 0–100
  final bool compact;

  const SitewiseProgressIndicator({
    super.key,
    required this.value,
    this.compact = false,
  });

  /// Reads the shared ramp so the bar and the evidence ring can never disagree
  /// about a band boundary (DESIGN.md §7.10).
  Color get _color => SitewiseScoreRamp.colorFor(value);

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: value / 100,
              minHeight: compact ? 6 : 8,
              backgroundColor: SitewiseColors.border,
              valueColor: AlwaysStoppedAnimation(_color),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          value.toStringAsFixed(0),
          style: TextStyle(
            fontWeight: FontWeight.w700,
            color: _color,
            fontSize: compact ? 12 : 14,
          ),
        ),
      ],
    );
  }
}
