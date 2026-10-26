import 'package:shared_logic/shared_logic.dart';
import 'package:flutter/material.dart';

import '../../../core/theme/sitewise_theme.dart';
import '../../shared/widgets/sitewise_status_badge.dart';
import 'mobile_property_image.dart';

/// Compact review row for the Admin Home "needs your review" rail.
///
/// Deliberately shows *only* what an admin needs to triage a submission —
/// property, location, verification status and a timestamp slot. It never
/// renders the entrepreneur's suitability score: that is a buyer-facing signal
/// and has no place in a moderation surface.

class MobileReviewRow extends StatelessWidget {
  final CommercialProperty property;
  final VoidCallback? onTap;

  /// Optional trailing meta line (e.g. "Submitted 2 days ago").
  final String? meta;

  const MobileReviewRow({
    super.key,
    required this.property,
    this.onTap,
    this.meta,
  });

  @override
  Widget build(BuildContext context) {
    final status = property.verification;
    return Material(
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
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  MobilePropertyImage(
                    property: property,
                    width: 76,
                    height: 62,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          property.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            height: 1.2,
                            color: SitewiseColors.ink,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Row(
                          children: [
                            const Icon(
                              Icons.place_outlined,
                              size: 12,
                              color: SitewiseColors.muted,
                            ),
                            const SizedBox(width: 3),
                            Expanded(
                              child: Text(
                                '${property.city}, ${property.state}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: SitewiseColors.muted,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  _statusPill(status),
                  const Spacer(),
                  if (meta != null || onTap != null) ...[
                    Flexible(
                      child: Text(
                        meta ?? 'Review',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.right,
                        style: const TextStyle(
                          fontSize: 11,
                          color: SitewiseColors.muted,
                        ),
                      ),
                    ),
                    const SizedBox(width: 2),
                    const Icon(
                      Icons.chevron_right_rounded,
                      size: 17,
                      color: SitewiseColors.overline,
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _statusPill(VerificationStatus status) {
    // Delegates to the shared badge. This widget used to carry its own copy of
    // the status → (label, colour, wash) mapping with inline hexes, which is the
    // third duplicate of the same table in the codebase.
    return SitewiseStatusBadge.forVerification(status);
  }
}

/// One line of a role-specific activity feed (Owner / Admin Home).
class MobileActivityItem {
  final IconData icon;
  final String title;

  /// Plain, human-readable time label supplied by the caller — never a raw
  /// timestamp.
  final String when;
  final Color color;

  const MobileActivityItem({
    required this.icon,
    required this.title,
    required this.when,
    this.color = SitewiseColors.action,
  });
}

/// Compact activity list. Kept short on Home (a handful of entries) so the
/// screen stays action-oriented rather than becoming an enterprise dashboard.
class MobileActivityList extends StatelessWidget {
  final List<MobileActivityItem> items;

  const MobileActivityList({super.key, required this.items});

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: SitewiseColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: SitewiseColors.border),
        ),
        child: const Text(
          'No recent activity.',
          style: TextStyle(fontSize: 12.5, color: SitewiseColors.muted),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: SitewiseColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: SitewiseColors.border),
      ),
      child: Column(
        children: [
          for (var i = 0; i < items.length; i++) ...[
            if (i > 0)
              const Divider(
                height: 1,
                thickness: 1,
                color: SitewiseColors.border,
              ),
            _ActivityRow(item: items[i]),
          ],
        ],
      ),
    );
  }
}

class _ActivityRow extends StatelessWidget {
  final MobileActivityItem item;

  const _ActivityRow({required this.item});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: item.color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(11),
            ),
            child: Icon(item.icon, size: 18, color: item.color),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  item.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    height: 1.3,
                    color: SitewiseColors.ink,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  item.when,
                  style: const TextStyle(
                    fontSize: 11,
                    color: SitewiseColors.muted,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
