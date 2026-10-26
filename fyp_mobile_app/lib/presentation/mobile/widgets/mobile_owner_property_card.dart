import 'package:shared_logic/shared_logic.dart';
import 'package:flutter/material.dart';

import '../../../core/theme/sitewise_theme.dart';
import '../../shared/widgets/sitewise_status_badge.dart';
import 'mobile_property_image.dart';

/// Owner-facing compact property card for horizontal rails on Home.
///
/// Same visual rhythm as the discovery cards, but the information is what an
/// *owner* needs: listing status, 360° tour availability and verification —
/// deliberately **not** the entrepreneur's suitability score, which is
/// meaningless to the person listing the unit.
///
/// Fixed width keeps every card in a rail identical; the containing
/// [MobileCardRail] supplies the height.

class MobileOwnerPropertyCard extends StatelessWidget {
  final CommercialProperty property;
  final VoidCallback? onTap;

  static const double width = 216;

  const MobileOwnerPropertyCard({
    super.key,
    required this.property,
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
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: SitewiseColors.border),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                MobilePropertyImage(
                  property: property,
                  height: 104,
                  width: double.infinity,
                  borderRadius: BorderRadius.zero,
                  badge: property.hasTour ? '360°' : null,
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
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
                        '${property.city}, ${property.state}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11,
                          color: SitewiseColors.muted,
                        ),
                      ),
                      const SizedBox(height: 7),
                      Text(
                        '${property.rentalDisplay} / month',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                          color: SitewiseColors.action,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          _verificationPill(property.verification),
                          const Spacer(),
                          if (property.hasTour)
                            const Icon(
                              Icons.threesixty_rounded,
                              size: 18,
                              color: SitewiseColors.action,
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _verificationPill(VerificationStatus status) {
    // Delegates to the shared badge. This widget used to carry its own copy of
    // the status → (label, colour, wash) mapping with inline hexes, which is the
    // second duplicate of the same table in the codebase.
    return SitewiseStatusBadge.forVerification(status);
  }
}
