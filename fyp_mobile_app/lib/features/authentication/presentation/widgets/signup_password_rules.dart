import 'package:flutter/material.dart';

import 'package:fyp/features/authentication/domain/signup_password_policy.dart';
import 'package:fyp/core/theme/sitewise_theme.dart';

/// Live password requirement indicators for Step 2.
///
/// The rules come from [SignupPasswordPolicy] — the same object the
/// registration repository validates against — so a green tick is a real
/// statement about what will be accepted, not a decorative mock.
class SignupPasswordRules extends StatelessWidget {
  const SignupPasswordRules({super.key, required this.password});

  final String password;

  @override
  Widget build(BuildContext context) {
    final rules = SignupPasswordPolicy.evaluate(password);
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: SitewiseColors.border.withValues(alpha: .32),
        borderRadius: BorderRadius.circular(SitewiseSpacing.radiusSm),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          for (final rule in rules)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2.5),
              child: Row(
                children: <Widget>[
                  Icon(
                    rule.met
                        ? Icons.check_circle_rounded
                        : Icons.radio_button_unchecked_rounded,
                    size: 15,
                    color: rule.met
                        ? SitewiseColors.success
                        : SitewiseColors.overline,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      rule.label,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: rule.met
                            ? SitewiseColors.text
                            : SitewiseColors.muted,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
