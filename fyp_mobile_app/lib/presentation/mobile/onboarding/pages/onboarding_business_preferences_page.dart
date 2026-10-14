import 'package:flutter/material.dart';

import '../../../../core/theme/sitewise_theme.dart';
import '../widgets/onboarding_base_layout.dart';
import '../widgets/onboarding_header.dart';
import '../widgets/onboarding_next_button.dart';
import '../widgets/onboarding_page_indicator.dart';

/// Onboarding step 2 of 5 — Business Preferences. Frames the F&B inputs
/// Sitewise uses (concept, budget, target customers, operating preference).

class OnboardingBusinessPreferencesPage extends StatelessWidget {
  final VoidCallback onSkip;
  final VoidCallback onNext;

  const OnboardingBusinessPreferencesPage({
    super.key,
    required this.onSkip,
    required this.onNext,
  });

  @override
  Widget build(BuildContext context) {
    return OnboardingBaseLayout(
      header: OnboardingHeader(onSkip: onSkip),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const OnboardingKicker('01 — BUSINESS PREFERENCES'),
          const SizedBox(height: 7),
          const OnboardingTitle('Tell us about\nyour business'),
          const SizedBox(height: 11),
          const OnboardingBodyText(
            'Sitewise uses your F&B concept, budget and target customers to '
            'personalise the locations you evaluate.',
          ),
          const SizedBox(height: 17),
          const _InfoCard(
            icon: Icons.restaurant_menu_rounded,
            title: 'F&B Concept',
            text: 'Café, Restaurant, Bubble Tea',
            color: Colors.orange,
          ),
          const SizedBox(height: 10),
          const _InfoCard(
            icon: Icons.account_balance_wallet_outlined,
            title: 'Budget Range',
            text: 'RM5,000 – RM15,000 / month',
            color: SitewiseColors.action,
          ),
          const SizedBox(height: 10),
          const _InfoCard(
            icon: Icons.groups_2_outlined,
            title: 'Target Customers',
            text: 'Students, Office Workers, Families',
            color: Color(0xFFEA580C),
          ),
          const SizedBox(height: 10),
          const _InfoCard(
            icon: Icons.storefront_outlined,
            title: 'Operating Preference',
            text: 'Dine-in, Takeaway, Both',
            color: SitewiseColors.success,
          ),
          const Spacer(),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const OnboardingPageIndicator(index: 1),
              OnboardingNextButton(onPressed: onNext),
            ],
          ),
        ],
      ),
    );
  }
}

/// A single business-preference row. Used only by this page, so it stays here
/// rather than becoming its own file.
class _InfoCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String text;
  final Color color;

  const _InfoCard({
    required this.icon,
    required this.title,
    required this.text,
    required this.color,
  });

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(13),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: SitewiseColors.border),
    ),
    child: Row(
      children: [
        Container(
          width: 39,
          height: 39,
          decoration: BoxDecoration(
            color: color.withValues(alpha: .11),
            borderRadius: BorderRadius.circular(11),
          ),
          child: Icon(icon, color: color, size: 19),
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
              const SizedBox(height: 3),
              Text(
                text,
                style: const TextStyle(
                  fontSize: 11,
                  color: SitewiseColors.muted,
                ),
              ),
            ],
          ),
        ),
        const Icon(Icons.chevron_right_rounded, color: SitewiseColors.overline),
      ],
    ),
  );
}
