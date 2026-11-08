import 'package:flutter/material.dart';

import '../../../core/theme/sitewise_theme.dart';

/// Full-width primary call-to-action used by the mobile pre-login screens
/// (Get Started, Log In / Sign Up). Slightly heavier than [SitewiseButton]
/// to match the pre-login visual language, but consumes the same
/// [SitewiseColors] tokens.

class SitewiseCtaButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;

  /// Shows an inline progress indicator and keeps the button's 52px height, so
  /// a pending request never collapses the layout or invites a second tap.
  final bool busy;

  const SitewiseCtaButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.busy = false,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: onPressed != null,
      label: label,
      child: SizedBox(
        width: double.infinity,
        height: 52,
        child: ElevatedButton(
          onPressed: busy ? null : onPressed,
          style: ElevatedButton.styleFrom(
            elevation: 0,
            backgroundColor: SitewiseColors.action,
            foregroundColor: Colors.white,
            disabledBackgroundColor: SitewiseColors.action.withValues(
              alpha: .55,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(SitewiseSpacing.radiusLg),
            ),
          ),
          child: busy
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.2,
                    color: Colors.white,
                  ),
                )
              : Text(
                  label,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 15,
                  ),
                ),
        ),
      ),
    );
  }
}
