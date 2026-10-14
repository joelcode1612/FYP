import 'package:shared_logic/shared_logic.dart';
import 'package:flutter/material.dart';

import '../../../core/theme/sitewise_theme.dart';

/// Verification / generic status pill. Colours come from the theme tokens.

class SitewiseStatusBadge extends StatelessWidget {
  final String label;
  final Color color;
  final Color background;

  const SitewiseStatusBadge({
    super.key,
    required this.label,
    required this.color,
    required this.background,
  });

  factory SitewiseStatusBadge.forVerification(VerificationStatus status) {
    switch (status) {
      case VerificationStatus.verified:
        return const SitewiseStatusBadge(
          label: 'Verified',
          color: SitewiseColors.success,
          background: Color(0xFFD3F8DF),
        );
      case VerificationStatus.pending:
        return const SitewiseStatusBadge(
          label: 'Pending review',
          color: SitewiseColors.warning,
          background: Color(0xFFFEF0C7),
        );
      case VerificationStatus.rejected:
        return const SitewiseStatusBadge(
          label: 'Rejected',
          color: SitewiseColors.danger,
          background: Color(0xFFFEE4E2),
        );
      case VerificationStatus.draft:
        return const SitewiseStatusBadge(
          label: 'Draft',
          color: SitewiseColors.muted,
          background: Color(0xFFF2F4F7),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
