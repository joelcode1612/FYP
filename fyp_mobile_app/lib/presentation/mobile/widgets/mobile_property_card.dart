import 'package:shared_logic/shared_logic.dart';
import 'package:flutter/material.dart';

import '../../../core/theme/sitewise_theme.dart';
import '../../shared/widgets/sitewise_status_badge.dart';
import 'mobile_property_image.dart';
import 'mobile_suitability_badge.dart';

/// The single property-card system for the mobile tree.
///
/// Three genuine layout variants (not boolean flags) cover every list context:
///  * [MobilePropertyCard]        — horizontal row, the default for lists
///  * [MobileFeaturedPropertyCard]— large hero card for Home
///  * [MobileCompactPropertyCard] — narrow card for horizontal discovery rails
///
/// All three read the same [CommercialProperty] and use the real verification
/// state; nothing is mocked here.

class MobilePropertyCard extends StatelessWidget {
  final CommercialProperty property;
  final VoidCallback? onTap;
  final bool saved;
  final VoidCallback? onToggleSaved;
  final bool compared;
  final VoidCallback? onToggleCompare;
  final String? rankBanner;

  const MobilePropertyCard({
    super.key,
    required this.property,
    this.onTap,
    this.saved = false,
    this.onToggleSaved,
    this.compared = false,
    this.onToggleCompare,
    this.rankBanner,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: SitewiseColors.surface,
        borderRadius: BorderRadius.circular(SitewiseSpacing.radiusLg),
        border: Border.all(color: SitewiseColors.border),
        boxShadow: SitewiseShadows.cardSm,
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (rankBanner != null)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
                color: SitewiseColors.geoWash,
                child: Text(
                  rankBanner!,
                  style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: SitewiseColors.accent,
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  MobilePropertyImage(
                    property: property,
                    width: 108,
                    height: 112,
                    borderRadius: BorderRadius.circular(
                      SitewiseSpacing.radius,
                    ),
                    badge: property.hasTour ? '360°' : null,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Text(
                                property.title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                  color: SitewiseColors.ink,
                                  height: 1.2,
                                ),
                              ),
                            ),
                            if (onToggleSaved != null)
                              _IconAction(
                                icon: saved
                                    ? Icons.bookmark_rounded
                                    : Icons.bookmark_border_rounded,
                                active: saved,
                                tooltip: saved
                                    ? 'Remove from saved'
                                    : 'Save property',
                                onTap: onToggleSaved!,
                              ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        _locationRow(),
                        const SizedBox(height: 8),
                        // The explore projection maps SQL NULL rent/size to
                        // 0; a real listing never rents for RM 0, so zero is
                        // rendered as "not listed" rather than a fake price.
                        Text(
                          property.rentalRm > 0
                              ? '${property.rentalDisplay} / month'
                              : 'Rent on request',
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                            color: SitewiseColors.action,
                          ),
                        ),
                        const SizedBox(height: 3),
                        _metaRow(),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            if (property.hasSuitabilityScore) ...[
                              MobileSuitabilityBadge(
                                score: property.suitabilityScore,
                                compact: true,
                              ),
                              const SizedBox(width: 5),
                              const Expanded(
                                child: Text(
                                  'Suitability',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 10.5,
                                    color: SitewiseColors.muted,
                                  ),
                                ),
                              ),
                            ] else
                              const Expanded(
                                child: Text(
                                  'Suitability: not scored yet',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 10.5,
                                    color: SitewiseColors.muted,
                                  ),
                                ),
                              ),
                            if (property.verification ==
                                VerificationStatus.verified)
                              SitewiseStatusBadge.forVerification(
                                property.verification,
                              ),
                            if (onToggleCompare != null) ...[
                              const SizedBox(width: 4),
                              _IconAction(
                                icon: compared
                                    ? Icons.compare_arrows_rounded
                                    : Icons.compare_arrows,
                                active: compared,
                                tooltip: compared
                                    ? 'Remove from compare'
                                    : 'Add to compare',
                                onTap: onToggleCompare!,
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _locationRow() => Row(
    children: [
      const Icon(Icons.place_outlined, size: 13, color: SitewiseColors.muted),
      const SizedBox(width: 3),
      Expanded(
        child: Text(
          '${property.city}, ${property.state}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 11.5, color: SitewiseColors.muted),
        ),
      ),
    ],
  );

  Widget _metaRow() => Row(
    children: [
      const Icon(
        Icons.crop_square_rounded,
        size: 12,
        color: SitewiseColors.overline,
      ),
      const SizedBox(width: 3),
      Text(
        property.sizeSqft > 0
            ? '${property.sizeSqft.toStringAsFixed(0)} sq ft'
            : 'Size not listed',
        style: const TextStyle(fontSize: 11.5, color: SitewiseColors.muted),
      ),
      const Padding(
        padding: EdgeInsets.symmetric(horizontal: 6),
        child: Text('·', style: TextStyle(color: SitewiseColors.overline)),
      ),
      Flexible(
        child: Text(
          property.propertyType,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 11.5, color: SitewiseColors.muted),
        ),
      ),
    ],
  );
}

/// Large hero card for the Home screen: full-bleed imagery, overlay copy and a
/// single primary CTA.
class MobileFeaturedPropertyCard extends StatelessWidget {
  final CommercialProperty property;
  final VoidCallback? onTap;
  final bool saved;
  final VoidCallback? onToggleSaved;

  const MobileFeaturedPropertyCard({
    super.key,
    required this.property,
    this.onTap,
    this.saved = false,
    this.onToggleSaved,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(SitewiseSpacing.radiusXl),
      child: AspectRatio(
        aspectRatio: 1.22,
        child: Stack(
          fit: StackFit.expand,
          children: [
            MobilePropertyImage(
              property: property,
              borderRadius: BorderRadius.zero,
            ),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Color(0x00000000),
                    Color(0x33000000),
                    Color(0xCC0F172A),
                  ],
                  stops: [0.35, 0.6, 1],
                ),
              ),
            ),
            if (onToggleSaved != null)
              Positioned(
                top: 12,
                right: 12,
                child: Material(
                  color: SitewiseColors.surface.withValues(alpha: 0.92),
                  shape: const CircleBorder(),
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: onToggleSaved,
                    child: SizedBox(
                      width: 38,
                      height: 38,
                      child: Icon(
                        saved
                            ? Icons.bookmark_rounded
                            : Icons.bookmark_border_rounded,
                        size: 19,
                        color: saved
                            ? SitewiseColors.action
                            : SitewiseColors.ink,
                      ),
                    ),
                  ),
                ),
              ),
            Positioned(
              left: 16,
              right: 16,
              bottom: 16,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (property.verification == VerificationStatus.verified)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 8),
                      child: SitewiseStatusBadge(
                        label: 'Verified',
                        color: SitewiseColors.success,
                        background: SitewiseColors.successWash,
                      ),
                    ),
                  Text(
                    property.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      // Was the literal 'Sora', which was never bundled and so
                      // fell back to the platform default. Now the design's
                      // single family, which *is* bundled.
                      fontFamily: kFontFamily,
                      fontSize: 21,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                      height: 1.15,
                      letterSpacing: -0.4,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      const Icon(
                        Icons.place_outlined,
                        size: 14,
                        color: Colors.white70,
                      ),
                      const SizedBox(width: 3),
                      Expanded(
                        child: Text(
                          '${property.city}, ${property.state}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.white70,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${property.rentalDisplay} / month',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                            color: Colors.white,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: SitewiseColors.surface.withValues(alpha: 0.92),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              property.suitabilityScore.toStringAsFixed(0),
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w800,
                                color: suitabilityColor(
                                  property.suitabilityScore,
                                ),
                              ),
                            ),
                            const SizedBox(width: 4),
                            const Text(
                              'suitability',
                              style: TextStyle(
                                fontSize: 10,
                                color: SitewiseColors.muted,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    height: 46,
                    child: ElevatedButton(
                      onPressed: onTap,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: SitewiseColors.surface,
                        foregroundColor: SitewiseColors.action,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(
                            SitewiseSpacing.radiusLg,
                          ),
                        ),
                      ),
                      child: const Text(
                        'View property',
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 13.5,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Narrow card for horizontal discovery rails on Home.
class MobileCompactPropertyCard extends StatelessWidget {
  final CommercialProperty property;
  final VoidCallback? onTap;

  static const double width = 204;

  const MobileCompactPropertyCard({
    super.key,
    required this.property,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(SitewiseSpacing.radiusLg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            MobilePropertyImage(
              property: property,
              height: 112,
              width: double.infinity,
              borderRadius: BorderRadius.circular(SitewiseSpacing.radiusLg),
              badge: property.hasTour ? '360°' : null,
            ),
            const SizedBox(height: 8),
            Text(
              property.title,
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
              '${property.city} · ${property.sizeSqft.toStringAsFixed(0)} sq ft',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, color: SitewiseColors.muted),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'RM${property.rentalRm.toStringAsFixed(0)}/mo',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                      color: SitewiseColors.action,
                    ),
                  ),
                ),
                MobileSuitabilityBadge(
                  score: property.suitabilityScore,
                  compact: true,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Small circular icon button used inside cards.
class _IconAction extends StatelessWidget {
  final IconData icon;
  final bool active;
  final String tooltip;
  final VoidCallback onTap;

  const _IconAction({
    required this.icon,
    required this.active,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(SitewiseSpacing.radiusLg),
      child: Padding(
        padding: const EdgeInsets.all(5),
        child: Icon(
          icon,
          size: 20,
          color: active ? SitewiseColors.action : SitewiseColors.muted,
        ),
      ),
    ),
  );
}
