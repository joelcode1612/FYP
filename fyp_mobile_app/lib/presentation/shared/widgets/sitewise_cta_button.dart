import 'package:flutter/material.dart';

import '../../../core/theme/sitewise_theme.dart';

/// Full-width primary call-to-action used by the mobile pre-login screens
/// (Get Started, Log In / Sign Up). Slightly heavier than [SitewiseButton]
/// to match the pre-login visual language, but consumes the same
/// [SitewiseColors] tokens.

class SitewiseCtaButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;

  const SitewiseCtaButton({
    super.key,
    required this.label,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 52,
      child: ElevatedButton(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          elevation: 0,
          backgroundColor: SitewiseColors.accent,
          foregroundColor: Colors.white,
          disabledBackgroundColor: SitewiseColors.accent.withValues(alpha: .5),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
        child: Text(
          label,
          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
        ),
      ),
    );
  }
}
