import 'package:flutter/material.dart';
import 'sitewise_icon.dart';

/// Primary action button.

class SitewiseButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool expanded;

  const SitewiseButton({
    super.key,
    required this.label,
    this.onPressed,
    this.icon,
    this.expanded = true,
  });

  @override
  Widget build(BuildContext context) {
    final child = Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (icon != null) ...[
          SitewiseIcon(icon!, intent: SitewiseIconIntent.button),
          const SizedBox(width: 8),
        ],
        // The label yields under width pressure (narrow viewports, large text
        // scale) instead of pushing the row past the button's bounds.
        Flexible(
          child: Text(
            label,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
    final btn = ElevatedButton(onPressed: onPressed, child: child);
    if (!expanded) return btn;
    return SizedBox(width: double.infinity, child: btn);
  }
}
