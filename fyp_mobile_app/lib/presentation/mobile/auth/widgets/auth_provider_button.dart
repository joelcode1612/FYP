import 'package:shared_logic/shared_logic.dart';
import 'package:flutter/material.dart';

import '../../../../core/theme/sitewise_theme.dart';

/// Federated sign-in button (Apple / Google).

class AuthProviderButton extends StatelessWidget {
  final AuthProvider provider;
  final VoidCallback? onPressed;

  const AuthProviderButton({
    super.key,
    required this.provider,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final apple = provider == AuthProvider.apple;
    return SizedBox(
      width: double.infinity,
      height: 49,
      child: OutlinedButton.icon(
        onPressed: onPressed,
        icon: apple
            ? const Icon(Icons.apple, size: 21, color: Colors.black)
            : const Text(
                'G',
                style: TextStyle(
                  color: Color(0xFF4285F4),
                  fontWeight: FontWeight.w900,
                  fontSize: 19,
                ),
              ),
        label: Text(
          apple ? 'Continue with Apple' : 'Continue with Google',
          style: const TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w700,
            color: SitewiseColors.ink,
          ),
        ),
        style: OutlinedButton.styleFrom(
          backgroundColor: Colors.white,
          side: const BorderSide(color: SitewiseColors.border),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
      ),
    );
  }
}

/// "Or continue with" rule between the primary form and the provider buttons.
class AuthDividerText extends StatelessWidget {
  const AuthDividerText({super.key});

  @override
  Widget build(BuildContext context) => const Row(
    children: [
      Expanded(child: Divider(color: SitewiseColors.border)),
      Padding(
        padding: EdgeInsets.symmetric(horizontal: 11),
        child: Text(
          'Or continue with',
          style: TextStyle(
            fontSize: 11.5,
            color: SitewiseColors.muted,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      Expanded(child: Divider(color: SitewiseColors.border)),
    ],
  );
}
