import 'package:flutter/material.dart';

import '../../../../core/theme/sitewise_theme.dart';
import '../visuals/location_visual.dart';
import '../widgets/onboarding_base_layout.dart';
import '../widgets/onboarding_header.dart';
import '../widgets/onboarding_next_button.dart';
import '../widgets/onboarding_page_indicator.dart';

/// Onboarding step 3 of 5 — Location Intelligence. Shows the four geospatial
/// signals Sitewise evaluates: population, accessibility, competition, demand.

class OnboardingLocationIntelligencePage extends StatelessWidget {
  final VoidCallback onSkip;
  final VoidCallback onNext;

  const OnboardingLocationIntelligencePage({
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
          const OnboardingKicker('02 — LOCATION INTELLIGENCE'),
          const SizedBox(height: 7),
          const OnboardingTitle('See the location,\nnot just the property'),
          const SizedBox(height: 11),
          const OnboardingBodyText(
            'Analyse population, accessibility, competition and nearby demand '
            'generators to understand each location.',
          ),
          const SizedBox(height: 15),
          const SizedBox(height: 270, child: LocationVisual()),
          const SizedBox(height: 11),
          const Row(
            children: [
              Expanded(
                child: _Signal(
                  title: 'Population',
                  value: 'Strong',
                  icon: Icons.groups_rounded,
                ),
              ),
              SizedBox(width: 8),
              Expanded(
                child: _Signal(
                  title: 'Accessibility',
                  value: 'Good',
                  icon: Icons.route_rounded,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Row(
            children: [
              Expanded(
                child: _Signal(
                  title: 'Competition',
                  value: 'Moderate',
                  icon: Icons.storefront_outlined,
                ),
              ),
              SizedBox(width: 8),
              Expanded(
                child: _Signal(
                  title: 'Demand',
                  value: 'Strong',
                  icon: Icons.trending_up_rounded,
                ),
              ),
            ],
          ),
          const Spacer(),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const OnboardingPageIndicator(index: 2),
              OnboardingNextButton(onPressed: onNext),
            ],
          ),
        ],
      ),
    );
  }
}

/// A compact location-signal readout. Page-local — not shared elsewhere.
class _Signal extends StatelessWidget {
  final String title;
  final String value;
  final IconData icon;

  const _Signal({required this.title, required this.value, required this.icon});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(10),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: SitewiseColors.border),
    ),
    child: Row(
      children: [
        Icon(icon, size: 17, color: SitewiseColors.action),
        const SizedBox(width: 7),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 9.5,
                  color: SitewiseColors.muted,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                value,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  color: SitewiseColors.ink,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}
