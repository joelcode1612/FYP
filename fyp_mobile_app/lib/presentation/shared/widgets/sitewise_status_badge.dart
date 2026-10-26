import 'package:shared_logic/shared_logic.dart';
import 'package:flutter/material.dart';

import '../../../core/theme/sitewise_theme.dart';

/// Verification / generic status pill.
///
/// Restyled to the new design's status pill (`owner.css` `.st`): a full pill, a
/// leading dot in the status colour, 11.5px/800 type. The wash colours now come
/// from [SitewiseColors] rather than inline hexes, so the four states can be
/// retinted centrally.
class SitewiseStatusBadge extends StatelessWidget {
  final String label;
  final Color color;
  final Color background;

  /// Show the leading dot. On by default — it is the new design's convention.
  final bool dot;

  const SitewiseStatusBadge({
    super.key,
    required this.label,
    required this.color,
    required this.background,
    this.dot = true,
  });

  factory SitewiseStatusBadge.forVerification(VerificationStatus status) {
    switch (status) {
      case VerificationStatus.verified:
        return const SitewiseStatusBadge(
          label: 'Verified',
          color: SitewiseColors.success,
          background: SitewiseColors.successWash,
        );
      case VerificationStatus.pending:
        return const SitewiseStatusBadge(
          label: 'Pending review',
          color: SitewiseColors.warning,
          background: SitewiseColors.warningWash,
        );
      case VerificationStatus.rejected:
        return const SitewiseStatusBadge(
          label: 'Rejected',
          color: SitewiseColors.danger,
          background: SitewiseColors.dangerWash,
        );
      case VerificationStatus.draft:
        return const SitewiseStatusBadge(
          label: 'Draft',
          color: SitewiseColors.muted,
          background: SitewiseColors.paper,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 4),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (dot) ...[
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 6),
          ],
          Text(
            label,
            style: TextStyle(
              fontFamily: kFontFamily,
              color: color,
              fontSize: 11.5,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}
