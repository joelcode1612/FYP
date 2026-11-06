import 'package:flutter/material.dart';

import '../../../core/theme/sitewise_theme.dart';
import '../../shared/widgets/sitewise_icon_tile.dart';

/// One circular quick action. Unlike [MobileQuickAction] (route-only), this
/// carries a callback so the same component serves navigation *and* in-place
/// actions (e.g. "Saved", "Compare", "Shortlist next").

class MobileQuickActionItem {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  /// Optional count bubble (e.g. pending items) — omit to keep the icon plain.
  final int? count;

  const MobileQuickActionItem({
    required this.icon,
    required this.label,
    required this.onTap,
    this.count,
  });
}

/// The reference pattern's circular quick-action row: light circular icon
/// container, short label underneath, evenly distributed and tappable.
///
/// Uses [Row] + [Expanded] so tiles size to their content and cannot overflow
/// on narrow phones or with large text scaling.
class MobileQuickActions extends StatelessWidget {
  final List<MobileQuickActionItem> actions;

  const MobileQuickActions({super.key, required this.actions});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < actions.length; i++) ...[
          if (i > 0) const SizedBox(width: 6),
          Expanded(child: _QuickActionTile(item: actions[i])),
        ],
      ],
    );
  }
}

class _QuickActionTile extends StatelessWidget {
  final MobileQuickActionItem item;

  const _QuickActionTile({required this.item});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: item.label,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: item.onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  SitewiseIconTile.glyph(
                    item.icon,
                    semanticLabel: item.label,
                  ),
                  if (item.count != null && item.count! > 0)
                    Positioned(
                      top: -2,
                      right: -2,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 1,
                        ),
                        constraints: const BoxConstraints(minWidth: 18),
                        decoration: BoxDecoration(
                          color: SitewiseColors.action,
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(
                            color: SitewiseColors.background,
                            width: 1.5,
                          ),
                        ),
                        child: Text(
                          item.count! > 9 ? '9+' : '${item.count}',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 9.5,
                            fontWeight: FontWeight.w800,
                            height: 1.3,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                item.label,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  height: 1.25,
                  color: SitewiseColors.ink,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
