import 'package:flutter/material.dart';

import '../../../../core/theme/sitewise_theme.dart';
import 'onboarding_painters.dart';

/// Introduction illustration: a map with a property card, an area label and a
/// location-suitability score. Placeholder art — replace with real Sitewise
/// assets later without touching the page.

class IntroVisual extends StatelessWidget {
  const IntroVisual({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: const LinearGradient(
          colors: [Color(0xFFF7FBFF), Color(0xFFEAF1FE)],
        ),
        border: Border.all(color: SitewiseColors.border),
      ),
      child: Stack(
        children: [
          const Positioned.fill(
            child: CustomPaint(painter: OnboardingMapPainter()),
          ),
          Positioned(
            left: 16,
            bottom: 25,
            child: Container(
              width: 190,
              height: 140,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(18),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x180F172A),
                    blurRadius: 18,
                    offset: Offset(0, 8),
                  ),
                ],
              ),
              child: const CustomPaint(painter: OnboardingBuildingPainter()),
            ),
          ),
          Positioned(
            top: 20,
            right: 15,
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: SitewiseColors.border),
              ),
              child: const Text(
                'Bukit Bintang, KL\nHigh potential',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  height: 1.35,
                ),
              ),
            ),
          ),
          Positioned(
            right: 15,
            bottom: 22,
            child: Container(
              width: 132,
              padding: const EdgeInsets.all(11),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(15),
                border: Border.all(color: SitewiseColors.border),
              ),
              child: const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Location suitability',
                    style: TextStyle(
                      fontSize: 9.5,
                      color: SitewiseColors.muted,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  SizedBox(height: 7),
                  Row(
                    children: [
                      SizedBox(
                        width: 44,
                        height: 44,
                        child: CircularProgressIndicator(
                          value: .91,
                          strokeWidth: 5,
                          color: SitewiseColors.action,
                          backgroundColor: SitewiseColors.geoBorder,
                        ),
                      ),
                      SizedBox(width: 9),
                      Expanded(
                        child: Text(
                          '91/100\nHigh potential',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w800,
                            color: SitewiseColors.success,
                            height: 1.35,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
