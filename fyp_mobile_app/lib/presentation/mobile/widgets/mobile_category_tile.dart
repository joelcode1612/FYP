import 'package:flutter/material.dart';

import '../../../core/theme/sitewise_theme.dart';

/// A discovery category tile ("Shop lots", "Corner units", …).
///
/// Replaces the photographic category cards in the reference mockup. The design
/// system forbids assumed imagery (DESIGN.md §8, Don't #13: "no photographic
/// placeholders that imply data the layer cannot support"), so the visual is the
/// same gradient-and-geometry treatment [MobilePropertyImage] uses, with a
/// centred Material Symbols icon and a `surface` pill carrying the label.
///
/// Flat by construction: `elevation: 0`, a single `1px --border`, and the
/// standard `16px` card radius. No shadow.
class MobileCategoryTile extends StatelessWidget {
  final String label;

  /// Optional secondary line — e.g. a real listing count.
  final String? caption;

  final IconData icon;
  final VoidCallback onTap;

  /// Optional badge in the top-right, e.g. "12 listings".
  final String? badge;

  const MobileCategoryTile({
    super.key,
    required this.label,
    required this.icon,
    required this.onTap,
    this.caption,
    this.badge,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: SitewiseColors.surface,
      borderRadius: BorderRadius.circular(SitewiseSpacing.md),
      child: InkWell(
        borderRadius: BorderRadius.circular(SitewiseSpacing.md),
        onTap: onTap,
        child: Container(
          height: 132,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(SitewiseSpacing.md),
            border: Border.all(color: SitewiseColors.border),
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // The brand-derived wash, not a photo. Same family as the map
              // panel gradient (surface → geo-wash).
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [SitewiseColors.surface, SitewiseColors.geoWash],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
              ),
              Center(child: Icon(icon, size: 20, color: SitewiseColors.action)),
              if (badge != null)
                Positioned(
                  top: SitewiseSpacing.sm,
                  right: SitewiseSpacing.sm,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: SitewiseSpacing.sm,
                      vertical: SitewiseSpacing.xs,
                    ),
                    decoration: BoxDecoration(
                      color: SitewiseColors.surface.withValues(alpha: 0.92),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: SitewiseColors.border),
                    ),
                    child: Text(
                      badge!,
                      style: const TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: SitewiseColors.ink,
                      ),
                    ),
                  ),
                ),
              // Label pill, bottom-left — a surface pill so it reads against the
              // wash without needing a shadow.
              Positioned(
                left: SitewiseSpacing.sm,
                right: SitewiseSpacing.sm,
                bottom: SitewiseSpacing.sm,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: SitewiseSpacing.sm + 2,
                    vertical: SitewiseSpacing.xs + 2,
                  ),
                  decoration: BoxDecoration(
                    color: SitewiseColors.surface.withValues(alpha: 0.92),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: SitewiseColors.border),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: SitewiseColors.ink,
                        ),
                      ),
                      if (caption != null)
                        Text(
                          caption!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 10,
                            color: SitewiseColors.muted,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
