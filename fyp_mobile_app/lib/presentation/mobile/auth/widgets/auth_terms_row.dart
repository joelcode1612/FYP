import 'package:flutter/material.dart';

import '../../../../core/theme/sitewise_theme.dart';

/// Terms of Service / Privacy Policy consent row for Sign Up.

class AuthTermsRow extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;

  const AuthTermsRow({super.key, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Checkbox(
        value: value,
        onChanged: (v) => onChanged(v ?? false),
        activeColor: SitewiseColors.action,
        visualDensity: VisualDensity.compact,
      ),
      const Expanded(
        child: Padding(
          padding: EdgeInsets.only(top: 8),
          child: Text.rich(
            TextSpan(
              style: TextStyle(
                fontSize: 11.3,
                height: 1.35,
                color: SitewiseColors.muted,
              ),
              children: [
                TextSpan(text: 'I agree to the '),
                TextSpan(
                  text: 'Terms of Service',
                  style: TextStyle(
                    color: SitewiseColors.action,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                TextSpan(text: ' and '),
                TextSpan(
                  text: 'Privacy Policy',
                  style: TextStyle(
                    color: SitewiseColors.action,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ],
  );
}
