import 'package:flutter/material.dart';

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
        if (icon != null) ...[Icon(icon, size: 18), const SizedBox(width: 8)],
        Text(label),
      ],
    );
    final btn = ElevatedButton(onPressed: onPressed, child: child);
    if (!expanded) return btn;
    return SizedBox(width: double.infinity, child: btn);
  }
}
