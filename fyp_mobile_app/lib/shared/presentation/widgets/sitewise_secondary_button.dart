import 'package:flutter/material.dart';

/// Secondary (outlined) action button.

class SitewiseSecondaryButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool expanded;

  const SitewiseSecondaryButton({
    super.key,
    required this.label,
    this.onPressed,
    this.icon,
    this.expanded = true,
  });

  @override
  Widget build(BuildContext context) {
    final labelWidget = Text(label);
    final child = Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (icon != null) ...[Icon(icon, size: 18), const SizedBox(width: 8)],
        // Only the expanded (bounded-width) layout can flex safely.
        if (expanded) Flexible(child: labelWidget) else labelWidget,
      ],
    );
    final btn = OutlinedButton(onPressed: onPressed, child: child);
    if (!expanded) return btn;
    return SizedBox(width: double.infinity, child: btn);
  }
}
