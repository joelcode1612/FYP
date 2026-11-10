import 'package:flutter/material.dart';

import '../../../core/theme/sitewise_m3.dart';
import '../../../core/theme/sitewise_theme.dart';

/// One of the four discovery tiles on the Listing screen.
///
/// A tile is a *summary of an applied criterion*, not a control with its own
/// private state: the value shown is always derived from the filter the page
/// holds, so it cannot drift from the results. Tapping opens the shared filter
/// sheet scrolled to this criterion.
///
/// Fixed height (rather than intrinsic) keeps the 2×2 grid aligned on narrow
/// devices where one helper line wraps and another does not.
class MobileFilterTile extends StatelessWidget {
  final IconData icon;

  /// Short uppercase caption, e.g. "MONTHLY RENT".
  final String title;

  /// The current selection, e.g. "Any budget" or "RM 3,000–8,000".
  final String value;

  /// One-line explanation of what the criterion does.
  final String helper;

  final bool active;
  final VoidCallback onTap;

  /// Height chosen so a wrapped helper line never clips at 320 dp width while
  /// the whole 2×2 block still leaves the first listing card visible on a
  /// 640 dp-tall phone without scrolling.
  static const double height = 96;

  const MobileFilterTile({
    super.key,
    required this.icon,
    required this.title,
    required this.value,
    required this.helper,
    required this.onTap,
    this.active = false,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      // The screen reader gets the full state in one utterance instead of
      // three disconnected labels.
      label: '$title. $value. $helper',
      excludeSemantics: true,
      child: Material(
        color: active ? SitewiseM3.quiet : SitewiseColors.surface,
        borderRadius: BorderRadius.circular(SitewiseSpacing.radiusLg),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(SitewiseSpacing.radiusLg),
          child: Container(
            height: height,
            padding: const EdgeInsets.fromLTRB(11, 9, 11, 9),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(SitewiseSpacing.radiusLg),
              border: Border.all(
                color: active ? SitewiseColors.action : SitewiseColors.border,
                width: active ? 1.4 : 1,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      icon,
                      size: 15,
                      color: active
                          ? SitewiseColors.action
                          : SitewiseColors.muted,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        title.toUpperCase(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.5,
                          color: active
                              ? SitewiseColors.action
                              : SitewiseColors.overline,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 5),
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    color: SitewiseM3.ink,
                    letterSpacing: -0.2,
                  ),
                ),
                const SizedBox(height: 3),
                Expanded(
                  child: Text(
                    helper,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 10.5,
                      height: 1.25,
                      color: SitewiseColors.muted,
                    ),
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

/// The 2×2 tile grid.
///
/// Built from two [Row]s of [Expanded] rather than a [GridView] so the tiles
/// size to the available width without a nested scroll viewport — the whole
/// header block lives inside the page's single scroll view.
class MobileFilterTileGrid extends StatelessWidget {
  final List<MobileFilterTile> tiles;

  const MobileFilterTileGrid({super.key, required this.tiles})
    : assert(tiles.length == 4, 'the grid is defined as 2×2');

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: tiles[0]),
            const SizedBox(width: 10),
            Expanded(child: tiles[1]),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: tiles[2]),
            const SizedBox(width: 10),
            Expanded(child: tiles[3]),
          ],
        ),
      ],
    );
  }
}

/// Compact toggle used for the secondary criteria row
/// (Verified / 360° tour / All filters).
///
/// [enabled] is false when the criterion provably cannot change the current
/// result set (for example "360° tour" while the dataset holds no published
/// tours). A disabled chip still reports *why* through [onDisabledTap] instead
/// of swallowing the tap, so the control is informative rather than decorative.
class MobileToggleChip extends StatelessWidget {
  final String label;
  final IconData? icon;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;
  final VoidCallback? onDisabledTap;
  final String? semanticHint;

  const MobileToggleChip({
    super.key,
    required this.label,
    required this.onTap,
    this.icon,
    this.selected = false,
    this.enabled = true,
    this.onDisabledTap,
    this.semanticHint,
  });

  @override
  Widget build(BuildContext context) {
    final fg = !enabled
        ? SitewiseColors.overline
        : selected
        ? Colors.white
        : SitewiseColors.ink;
    final bg = !enabled
        ? SitewiseColors.background
        : selected
        ? SitewiseColors.action
        : SitewiseColors.surface;
    final border = !enabled
        ? SitewiseColors.border
        : selected
        ? SitewiseColors.action
        : SitewiseColors.border;

    return Semantics(
      button: true,
      toggled: selected,
      enabled: enabled,
      label: label,
      hint: semanticHint,
      excludeSemantics: true,
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(999),
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: enabled ? onTap : onDisabledTap,
          child: Container(
            constraints: const BoxConstraints(minHeight: 40),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: border),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 14, color: fg),
                  const SizedBox(width: 5),
                ],
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: fg,
                  ),
                ),
                if (!enabled) ...[
                  const SizedBox(width: 4),
                  Icon(Icons.info_outline_rounded, size: 12, color: fg),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
