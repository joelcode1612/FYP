import 'package:flutter/material.dart';

import '../../../../core/theme/sitewise_theme.dart';

/// Circular "continue" affordance used at the bottom-right of onboarding
/// pages. Purely visual — progression is owned by `OnboardingController`.

class OnboardingNextButton extends StatelessWidget {
  final VoidCallback onPressed;

  const OnboardingNextButton({super.key, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: SitewiseColors.action,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onPressed,
        child: const SizedBox(
          width: 58,
          height: 58,
          child: Icon(
            Icons.arrow_forward_rounded,
            color: Colors.white,
            size: 25,
          ),
        ),
      ),
    );
  }
}
