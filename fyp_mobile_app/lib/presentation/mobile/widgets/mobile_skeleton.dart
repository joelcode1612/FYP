import 'package:flutter/material.dart';

import '../../../core/theme/sitewise_theme.dart';

/// Static grey block used to build loading placeholders.
///
/// Intentionally not animated: a looping shimmer schedules frames forever,
/// which stalls `pumpAndSettle` in widget tests. The layout still mirrors the
/// real cards so the transition into content is calm.

class MobileSkeletonBox extends StatelessWidget {
  final double? width;
  final double height;
  final BorderRadius? borderRadius;

  const MobileSkeletonBox({
    super.key,
    this.width,
    required this.height,
    this.borderRadius,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: const Color(0xFFEDF0F4),
        borderRadius: borderRadius ?? BorderRadius.circular(8),
      ),
    );
  }
}

/// Placeholder matching [MobilePropertyCard]'s horizontal layout.
class MobilePropertyCardSkeleton extends StatelessWidget {
  const MobilePropertyCardSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: SitewiseColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: SitewiseColors.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const MobileSkeletonBox(
            width: 104,
            height: 104,
            borderRadius: BorderRadius.all(Radius.circular(12)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const MobileSkeletonBox(width: 150, height: 14),
                const SizedBox(height: 8),
                const MobileSkeletonBox(width: 110, height: 11),
                const SizedBox(height: 14),
                const MobileSkeletonBox(width: 90, height: 14),
                const SizedBox(height: 12),
                Row(
                  children: const [
                    MobileSkeletonBox(width: 52, height: 22),
                    SizedBox(width: 8),
                    MobileSkeletonBox(width: 64, height: 22),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A short stack of card skeletons for list loading states.
class MobilePropertyListSkeleton extends StatelessWidget {
  final int count;
  final EdgeInsetsGeometry padding;

  const MobilePropertyListSkeleton({
    super.key,
    this.count = 4,
    this.padding = const EdgeInsets.symmetric(horizontal: 16),
  });

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: padding,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: count,
      separatorBuilder: (context, index) => const SizedBox(height: 12),
      itemBuilder: (context, index) => const MobilePropertyCardSkeleton(),
    );
  }
}
