import 'package:flutter/material.dart';

import '../../../core/theme/sitewise_theme.dart';

/// One status count chip (e.g. "Verified 3").

class MobileStatusCount {
  final String label;
  final int count;
  final Color color;

  const MobileStatusCount({
    required this.label,
    required this.count,
    required this.color,
  });
}

/// Compact status-count row used on the Owner and Admin Home screens.
///
/// Counts are always derived from the ViewModel's real state by the caller —
/// this widget never invents a number. Rendered as a horizontally scrollable
/// row of pills so it cannot overflow with four statuses on a narrow phone.
class MobileStatusCountRow extends StatelessWidget {
  final List<MobileStatusCount> counts;
  final ValueChanged<MobileStatusCount>? onTap;

  const MobileStatusCountRow({super.key, required this.counts, this.onTap});

  @override
  Widget build(BuildContext context) {
    if (counts.isEmpty) return const SizedBox.shrink();
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      physics: const ClampingScrollPhysics(),
      child: Row(
        children: [
          for (var i = 0; i < counts.length; i++) ...[
            if (i > 0) const SizedBox(width: 8),
            _CountPill(
              item: counts[i],
              onTap: onTap == null ? null : () => onTap!(counts[i]),
            ),
          ],
        ],
      ),
    );
  }
}

class _CountPill extends StatelessWidget {
  final MobileStatusCount item;
  final VoidCallback? onTap;

  const _CountPill({required this.item, this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: SitewiseColors.surface,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: SitewiseColors.border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: item.color,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${item.count}',
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                  color: SitewiseColors.ink,
                  height: 1,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                item.label,
                style: const TextStyle(
                  fontSize: 12,
                  color: SitewiseColors.muted,
                  height: 1,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
