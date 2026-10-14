import 'package:flutter/material.dart';

import '../../../../core/theme/sitewise_theme.dart';

/// Progress indicator for the onboarding flow.
///
/// [stages] is the number of *onboarding* steps before authentication
/// (Introduction, Business Preferences, Location Intelligence, 360°
/// Exploration, Get Started) — authentication is intentionally excluded.
/// The original monolith drew only 3 dots for this 5-step flow; the indicator
/// now always reflects the real stage count.

class OnboardingPageIndicator extends StatelessWidget {
  static const int stages = 5;

  final int index;
  final int count;

  const OnboardingPageIndicator({
    super.key,
    required this.index,
    this.count = stages,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(count, (i) {
        final active = i == index;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          margin: const EdgeInsets.symmetric(horizontal: 3),
          width: active ? 24 : 7,
          height: 6,
          decoration: BoxDecoration(
            color: active ? SitewiseColors.action : const Color(0xFFD7DEE8),
            borderRadius: BorderRadius.circular(99),
          ),
        );
      }),
    );
  }
}
