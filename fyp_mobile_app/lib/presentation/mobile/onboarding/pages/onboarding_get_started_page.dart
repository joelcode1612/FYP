import 'package:flutter/material.dart';

import '../../../../core/theme/sitewise_theme.dart';
import '../../../shared/widgets/sitewise_cta_button.dart';
import '../widgets/onboarding_base_layout.dart';
import '../widgets/onboarding_header.dart';
import '../widgets/onboarding_page_indicator.dart';

/// Onboarding step 5 of 5 — Get Started. Summarises the value and hands off.
/// When the visitor is already signed in the hand-off enters the workspace, so
/// the copy asks them to continue instead of to register. This page owns no
/// auth logic.

class OnboardingGetStartedPage extends StatelessWidget {
  final VoidCallback onSkip;
  final VoidCallback onLogin;
  final VoidCallback onSignUp;

  /// True when a verified session already exists on this device.
  final bool signedIn;

  const OnboardingGetStartedPage({
    super.key,
    required this.onSkip,
    required this.onLogin,
    required this.onSignUp,
    this.signedIn = false,
  });

  @override
  Widget build(BuildContext context) {
    return OnboardingBaseLayout(
      header: OnboardingHeader(onSkip: onSkip),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const OnboardingKicker('04 — YOUR NEXT DECISION'),
          const SizedBox(height: 7),
          const OnboardingTitle('Ready to find your\nnext F&B location?'),
          const SizedBox(height: 11),
          OnboardingBodyText(
            signedIn
                ? 'Your Sitewise account is ready. Explore commercial '
                      'properties, compare locations and understand the '
                      'factors behind each result.'
                : 'Create a Sitewise account to explore commercial '
                      'properties, compare locations and understand the '
                      'factors behind each result.',
          ),
          const SizedBox(height: 19),
          const _Benefit(
            icon: Icons.auto_awesome_rounded,
            title: 'Personalised recommendations',
            text: 'Based on your business needs.',
          ),
          const SizedBox(height: 10),
          const _Benefit(
            icon: Icons.verified_outlined,
            title: 'Verified commercial properties',
            text: 'Review property information and 360° tours.',
          ),
          const SizedBox(height: 10),
          const _Benefit(
            icon: Icons.insights_rounded,
            title: 'Clear location insights',
            text: 'Understand population, access, competition and demand.',
          ),
          const Spacer(),
          // Both hand-offs mark onboarding complete; the host decides whether
          // that means the workspace (already signed in) or the auth screen.
          SitewiseCtaButton(
            label: signedIn ? 'Enter Sitewise' : 'Get started',
            onPressed: onSignUp,
          ),
          if (!signedIn)
            Center(
              child: TextButton(
                onPressed: onLogin,
                child: const Text(
                  'Already have an account?  Log in',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: SitewiseColors.action,
                  ),
                ),
              ),
            ),
          const SizedBox(height: 8),
          const Center(child: OnboardingPageIndicator(index: 4)),
        ],
      ),
    );
  }
}

/// A single value proposition row. Page-local.
class _Benefit extends StatelessWidget {
  final IconData icon;
  final String title;
  final String text;

  const _Benefit({required this.icon, required this.title, required this.text});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(13),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: SitewiseColors.border),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: SitewiseColors.geoWash,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(icon, size: 19, color: SitewiseColors.action),
        ),
        const SizedBox(width: 11),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w800,
                  color: SitewiseColors.ink,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                text,
                style: const TextStyle(
                  fontSize: 10.7,
                  height: 1.3,
                  color: SitewiseColors.muted,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}
