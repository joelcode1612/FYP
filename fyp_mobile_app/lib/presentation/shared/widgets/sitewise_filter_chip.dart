import 'package:flutter/material.dart';

import '../../../core/theme/sitewise_theme.dart';

/// Single-select filter chip.

class SitewiseFilterChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const SitewiseFilterChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onTap(),
      selectedColor: SitewiseColors.action,
      labelStyle: TextStyle(
        color: selected ? Colors.white : SitewiseColors.ink,
        fontWeight: FontWeight.w500,
      ),
      backgroundColor: SitewiseColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(
          color: selected ? SitewiseColors.action : SitewiseColors.border,
        ),
      ),
    );
  }
}
