import 'package:flutter/material.dart';

/// The reference pattern's horizontal card rail.
///
/// Owns its own height (derived from the tallest child via [itemHeight]) and
/// scales with the user's text setting, so the row can never be clipped or
/// overflow: the rail is a fixed-height [SizedBox] wrapping a horizontal
/// [ListView], and the height grows with large fonts.
///
/// Used by every role's Home for "recommended properties", "my properties",
/// "needs your review" and the secondary discovery/status rails.

class MobileCardRail extends StatelessWidget {
  final int itemCount;

  /// Base height of a rail item at 1.0 text scale.
  final double itemHeight;

  final Widget Function(BuildContext context, int index) itemBuilder;
  final EdgeInsetsGeometry padding;
  final double spacing;

  /// Center the items when they do not fill the viewport (short rails).
  final bool centerWhenShort;

  const MobileCardRail({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    required this.itemHeight,
    this.padding = const EdgeInsets.symmetric(horizontal: 16),
    this.spacing = 12,
    this.centerWhenShort = false,
  });

  @override
  Widget build(BuildContext context) {
    if (itemCount == 0) return const SizedBox.shrink();

    final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
    final height = (itemHeight * scale).clamp(itemHeight, itemHeight * 1.45);

    return SizedBox(
      height: height.toDouble(),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: padding,
        physics: const ClampingScrollPhysics(),
        itemCount: itemCount,
        separatorBuilder: (context, index) => SizedBox(width: spacing),
        itemBuilder: itemBuilder,
      ),
    );
  }
}
