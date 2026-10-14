import 'package:flutter/material.dart';

import '../../../../core/theme/sitewise_theme.dart';
import 'onboarding_painters.dart';

/// 360° exploration illustration: an F&B interior with a virtual-tour badge
/// and a "drag to look around" affordance.

class TourVisual extends StatelessWidget {
  const TourVisual({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: SitewiseColors.border),
        color: SitewiseColors.ink,
      ),
      child: Stack(
        children: [
          const Positioned.fill(
            child: CustomPaint(painter: OnboardingInteriorPainter()),
          ),
          Positioned(
            top: 13,
            left: 13,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: .88),
                borderRadius: BorderRadius.circular(999),
              ),
              child: const Row(
                children: [
                  Icon(
                    Icons.threesixty_rounded,
                    size: 14,
                    color: SitewiseColors.action,
                  ),
                  SizedBox(width: 4),
                  Text(
                    '360° virtual tour',
                    style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800),
                  ),
                ],
              ),
            ),
          ),
          const Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 88,
                  height: 88,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.fromBorderSide(
                        BorderSide(color: Colors.white, width: 2),
                      ),
                      color: Color(0x1FFFFFFF),
                    ),
                    child: Center(
                      child: Text(
                        '360°',
                        style: TextStyle(
                          color: Colors.white,
                          fontFamily: 'Sora',
                          fontSize: 21,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
                ),
                SizedBox(height: 8),
                Text(
                  'Drag to look around',
                  style: TextStyle(color: Colors.white70, fontSize: 11),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
