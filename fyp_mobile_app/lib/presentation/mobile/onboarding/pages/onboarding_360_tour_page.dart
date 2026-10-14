import 'package:flutter/material.dart';

import '../../../../core/theme/sitewise_theme.dart';
import '../visuals/tour_visual.dart';
import '../widgets/onboarding_base_layout.dart';
import '../widgets/onboarding_header.dart';
import '../widgets/onboarding_next_button.dart';
import '../widgets/onboarding_page_indicator.dart';

/// Onboarding step 4 of 5 — 360° Exploration. Presents the immersive tour of
/// exterior, frontage and interior before a physical site visit.

class Onboarding360TourPage extends StatelessWidget {
  final VoidCallback onSkip;
  final VoidCallback onNext;

  const Onboarding360TourPage({
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
          const OnboardingKicker('03 — 360° EXPLORATION'),
          const SizedBox(height: 7),
          const OnboardingTitle('Explore the space\nbefore you visit'),
          const SizedBox(height: 11),
          const OnboardingBodyText(
            'View the property layout, frontage and interior through an '
            'immersive 360° experience before arranging a physical visit.',
          ),
          const SizedBox(height: 15),
          const Expanded(child: TourVisual()),
          const SizedBox(height: 10),
          const Row(
            children: [
              Expanded(
                child: _TourMini(
                  label: 'Exterior',
                  icon: Icons.storefront_outlined,
                ),
              ),
              SizedBox(width: 8),
              Expanded(
                child: _TourMini(
                  label: 'Dining area',
                  icon: Icons.table_restaurant_outlined,
                ),
              ),
              SizedBox(width: 8),
              Expanded(
                child: _TourMini(
                  label: 'Street view',
                  icon: Icons.directions_car_outlined,
                ),
              ),
            ],
          ),
          const SizedBox(height: 13),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const OnboardingPageIndicator(index: 3),
              OnboardingNextButton(onPressed: onNext),
            ],
          ),
        ],
      ),
    );
  }
}

/// Small labelled tile under the tour visual. Page-local.
class _TourMini extends StatelessWidget {
  final String label;
  final IconData icon;

  const _TourMini({required this.label, required this.icon});

  @override
  Widget build(BuildContext context) => Container(
    height: 72,
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(13),
      border: Border.all(color: SitewiseColors.border),
    ),
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, size: 21, color: SitewiseColors.action),
        const SizedBox(height: 5),
        Text(
          label,
          style: const TextStyle(fontSize: 9.5, fontWeight: FontWeight.w700),
        ),
      ],
    ),
  );
}
