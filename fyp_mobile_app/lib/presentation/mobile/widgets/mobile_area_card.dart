import 'package:flutter/material.dart';

import '../../../core/theme/sitewise_theme.dart';

/// Small pill used inside the featured banner (e.g. "3 awaiting review").
/// Rendered on the blue banner, so it uses a translucent white treatment.

class MobileBannerChip extends StatelessWidget {
  final IconData icon;
  final String label;

  const MobileBannerChip({super.key, required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.28)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: Colors.white),
          const SizedBox(width: 6),
          Text(
            label,
            style: const TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
  }
}

/// Compact "area / location" card for the entrepreneur's secondary discovery
/// rail. Shows the city/area and how many real listings sit there — the count
/// is always supplied by the caller from the repository.
class MobileAreaCard extends StatelessWidget {
  final String area;
  final String state;
  final int listingCount;
  final VoidCallback? onTap;

  static const double width = 156;

  const MobileAreaCard({
    super.key,
    required this.area,
    required this.state,
    required this.listingCount,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: Material(
        color: SitewiseColors.surface,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: SitewiseColors.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: SitewiseColors.geoWash,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(
                        Icons.location_on_rounded,
                        size: 17,
                        color: SitewiseColors.action,
                      ),
                    ),
                    const Spacer(),
                    const Icon(
                      Icons.arrow_outward_rounded,
                      size: 15,
                      color: SitewiseColors.overline,
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  area,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    color: SitewiseColors.ink,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  state,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11,
                    color: SitewiseColors.muted,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '$listingCount ${listingCount == 1 ? 'listing' : 'listings'}',
                  style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    color: SitewiseColors.action,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
