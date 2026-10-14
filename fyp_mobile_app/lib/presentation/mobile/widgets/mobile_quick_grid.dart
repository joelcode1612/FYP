import 'package:flutter/material.dart';

import '../../../core/theme/sitewise_theme.dart';

/// One tappable discovery action (icon + label + route).

class MobileQuickAction {
  final IconData icon;
  final String label;
  final String route;

  const MobileQuickAction({
    required this.icon,
    required this.label,
    required this.route,
  });
}

/// Horizontal row of discovery actions.
///
/// Built with [Row] + [Expanded] rather than a fixed-aspect [GridView] so the
/// tiles size to their content and can never overflow on narrow phones or with
/// large text scaling.
class MobileQuickGrid extends StatelessWidget {
  final List<MobileQuickAction> actions;

  const MobileQuickGrid({super.key, required this.actions});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < actions.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          Expanded(child: _QuickTile(action: actions[i])),
        ],
      ],
    );
  }
}

class _QuickTile extends StatelessWidget {
  final MobileQuickAction action;

  const _QuickTile({required this.action});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () => Navigator.of(context).pushNamed(action.route),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: SitewiseColors.geoWash,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Icon(action.icon, size: 24, color: SitewiseColors.action),
            ),
            const SizedBox(height: 8),
            Text(
              action.label,
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
    );
  }
}
