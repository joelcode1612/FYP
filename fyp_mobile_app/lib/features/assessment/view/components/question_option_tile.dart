import 'package:flutter/material.dart';
import '../../../../core/theme/sitewise_theme.dart';

class QuestionOptionTile extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback? onPressed;
  const QuestionOptionTile({
    super.key,
    required this.label,
    required this.selected,
    this.onPressed,
  });
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Material(
      color: selected ? SitewiseColors.infoWash : SitewiseColors.surface,
      borderRadius: BorderRadius.circular(13),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(13),
        child: Container(
          constraints: const BoxConstraints(minHeight: 66),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(13),
            border: Border.all(
              color: selected
                  ? SitewiseColors.action
                  : SitewiseColors.borderStrong,
              width: selected ? 2 : 1,
            ),
          ),
          child: Row(
            children: [
              Icon(
                selected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                color: selected ? SitewiseColors.action : SitewiseColors.muted,
              ),
              const SizedBox(width: 15),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                    color: SitewiseColors.ink,
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
