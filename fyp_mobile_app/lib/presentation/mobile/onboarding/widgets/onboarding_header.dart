import 'package:flutter/material.dart';

import '../../../../core/theme/sitewise_theme.dart';
import '../../../shared/widgets/sitewise_brand.dart';

/// Onboarding top bar: the Sitewise wordmark on the left, a Skip action on
/// the right. Skipping is handled by the flow controller (it marks onboarding
/// complete before opening authentication).

class OnboardingHeader extends StatelessWidget {
  final VoidCallback onSkip;

  const OnboardingHeader({super.key, required this.onSkip});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 6, 20, 0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const SitewiseBrand(),
          TextButton(
            onPressed: onSkip,
            style: TextButton.styleFrom(foregroundColor: SitewiseColors.muted),
            child: const Text('Skip', style: TextStyle(fontSize: 12.5)),
          ),
        ],
      ),
    );
  }
}
