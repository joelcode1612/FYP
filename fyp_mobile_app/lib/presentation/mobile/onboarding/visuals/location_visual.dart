import 'package:flutter/material.dart';

import '../../../../core/theme/sitewise_theme.dart';
import 'onboarding_painters.dart';

/// Location-intelligence illustration: the geospatial map with floating
/// signal chips (population, accessibility, competition, demand).

class LocationVisual extends StatelessWidget {
  const LocationVisual({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        gradient: const LinearGradient(
          colors: [Color(0xFFEAF1FE), Color(0xFFDDE9FA)],
        ),
        border: Border.all(color: SitewiseColors.border),
      ),
      child: const Stack(
        children: [
          Positioned.fill(child: CustomPaint(painter: OnboardingMapPainter())),
          Positioned(
            top: 18,
            left: 15,
            child: _MapChip(label: 'Population', icon: Icons.groups_rounded),
          ),
          Positioned(
            top: 63,
            right: 14,
            child: _MapChip(label: 'Accessibility', icon: Icons.route_rounded),
          ),
          Positioned(
            bottom: 70,
            left: 14,
            child: _MapChip(
              label: 'Competition',
              icon: Icons.storefront_rounded,
            ),
          ),
          Positioned(
            bottom: 28,
            right: 14,
            child: _MapChip(label: 'Demand', icon: Icons.trending_up_rounded),
          ),
        ],
      ),
    );
  }
}

class _MapChip extends StatelessWidget {
  final String label;
  final IconData icon;

  const _MapChip({required this.label, required this.icon});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: .93),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: SitewiseColors.border),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: SitewiseColors.action),
        const SizedBox(width: 5),
        Text(
          label,
          style: const TextStyle(fontSize: 9.5, fontWeight: FontWeight.w700),
        ),
      ],
    ),
  );
}
