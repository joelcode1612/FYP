import 'package:flutter/material.dart';

import '../../../core/theme/sitewise_theme.dart';

/// A single read-only specification chip — icon plus label.
///
/// The reference mockup used "4 Bedrooms / 4 Bathrooms / A Kitchen". Sitewise
/// properties are commercial units, so the labels come from real
/// [CommercialProperty] fields: `sizeSqft`, `propertyType`, and the
/// `requirements` list ("Ground Floor", "F&B Suitable", …).
///
/// Display-only by design. [SitewiseFilterChip] is a *selection* control with a
/// selected/unselected state; reusing it here would imply these are tappable
/// filters. Flat: `surface` background, a single `1px --border`, `10px` radius
/// (the control radius from the ladder), `elevation: 0`.
class SitewiseSpecChip extends StatelessWidget {
  final IconData icon;
  final String label;

  const SitewiseSpecChip({super.key, required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: SitewiseSpacing.sm + 2,
        vertical: SitewiseSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: SitewiseColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: SitewiseColors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: SitewiseColors.muted),
          const SizedBox(width: 6),
          Text(
            label,
            style: const TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: SitewiseColors.ink,
            ),
          ),
        ],
      ),
    );
  }
}
