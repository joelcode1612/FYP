import 'package:flutter/material.dart';

import '../../../core/theme/sitewise_theme.dart';

/// A navigational hotspot for the 360° tour viewer — the "Attic ›" affordance
/// in the reference mockup.
///
/// This is the first hotspot control in the codebase. Hotspots are what let a
/// multi-station tour link one panorama to the next, so the widget takes a
/// destination rather than hardcoding a direction: [onTap] is supplied by the
/// viewer, which owns the station graph.
///
/// Shape and surface follow the pill register (`--radius-pill`, 999) with a
/// `--surface` background at 92% so it reads against a photographic or
/// gradient panorama without a heavy shadow — DESIGN.md §5 permits exactly one
/// black shadow in the system and this deliberately does not use it. A 1px
/// border does the separating instead.
class MobileHotspotChip extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  /// Shows a trailing chevron. Use for "go to another station" hotspots;
  /// omit for informational labels.
  final bool forward;

  const MobileHotspotChip({
    super.key,
    required this.label,
    required this.onTap,
    this.forward = true,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: SitewiseColors.surface.withValues(alpha: 0.92),
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: SitewiseSpacing.sm + 4,
            vertical: SitewiseSpacing.sm,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: SitewiseColors.border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: SitewiseColors.ink,
                ),
              ),
              if (forward) ...[
                const SizedBox(width: 4),
                const Icon(
                  Icons.chevron_right_rounded,
                  size: 16,
                  color: SitewiseColors.action,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
