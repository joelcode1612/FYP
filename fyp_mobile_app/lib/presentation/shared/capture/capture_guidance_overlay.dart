import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/theme/sitewise_theme.dart';

/// Centred AR guidance reticle: compass circle rotating with the yaw offset,
/// live yaw/pitch readout, and an aligned-to-capture badge.
///
/// Pure display — all alignment math lives in the view model / `ar_math`.

class CaptureGuidanceOverlay extends StatelessWidget {
  final double yawDeg;
  final double pitchDeg;
  final bool aligned;

  const CaptureGuidanceOverlay({
    super.key,
    required this.yawDeg,
    required this.pitchDeg,
    required this.aligned,
  });

  @override
  Widget build(BuildContext context) {
    final ringColor = aligned ? SitewiseColors.success : Colors.white;
    final iconColor = aligned ? SitewiseColors.success : Colors.amberAccent;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 120,
          height: 120,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.black26,
            border: Border.all(color: ringColor, width: 3),
          ),
          child: Transform.rotate(
            angle: yawDeg * math.pi / 180,
            child: Icon(Icons.navigation, size: 70, color: iconColor),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'Yaw ${yawDeg.toStringAsFixed(1)}°  /  Pitch ${pitchDeg.toStringAsFixed(1)}°',
          style: const TextStyle(
            color: Colors.white70,
            fontSize: 14,
            shadows: [Shadow(blurRadius: 4, color: Colors.black54)],
          ),
        ),
        if (aligned)
          Container(
            margin: const EdgeInsets.only(top: 8),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            decoration: BoxDecoration(
              color: SitewiseColors.success,
              borderRadius: BorderRadius.circular(20),
            ),
            child: const Text(
              'ALIGNED - CAPTURE',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 14,
              ),
            ),
          ),
      ],
    );
  }
}
