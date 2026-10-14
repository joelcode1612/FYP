import 'package:flutter/material.dart';

import '../../../core/theme/sitewise_theme.dart';

/// Prominent, mobile-native search field.
///
/// Set [readOnly] + [onTap] to use it as a "tap to search" entry point (Home),
/// or pass [onChanged] to drive the existing ViewModel search directly
/// (Explore).

class MobileSearchField extends StatelessWidget {
  final String hint;
  final TextEditingController? controller;
  final ValueChanged<String>? onChanged;
  final VoidCallback? onTap;
  final bool readOnly;
  final Widget? trailing;

  const MobileSearchField({
    super.key,
    this.hint = 'Search property, area or location',
    this.controller,
    this.onChanged,
    this.onTap,
    this.readOnly = false,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: controller,
            onChanged: onChanged,
            readOnly: readOnly,
            onTap: onTap,
            textInputAction: TextInputAction.search,
            style: const TextStyle(fontSize: 14, color: SitewiseColors.ink),
            decoration: InputDecoration(
              hintText: hint,
              hintStyle: const TextStyle(
                fontSize: 13.5,
                color: SitewiseColors.overline,
              ),
              prefixIcon: const Icon(
                Icons.search_rounded,
                size: 20,
                color: SitewiseColors.muted,
              ),
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(vertical: 14),
              filled: true,
              fillColor: SitewiseColors.surface,
              border: _border(SitewiseColors.border),
              enabledBorder: _border(SitewiseColors.border),
              focusedBorder: _border(SitewiseColors.action, width: 1.4),
            ),
          ),
        ),
        if (trailing != null) ...[const SizedBox(width: 8), trailing!],
      ],
    );
  }

  OutlineInputBorder _border(Color color, {double width = 1}) =>
      OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: color, width: width),
      );
}

/// Square icon button used beside the search field (filter / map toggle).
class MobileIconAction extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool active;

  const MobileIconAction({
    super.key,
    required this.icon,
    required this.tooltip,
    this.onPressed,
    this.active = false,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: active ? SitewiseColors.action : SitewiseColors.surface,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onPressed,
          child: Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: active ? SitewiseColors.action : SitewiseColors.border,
              ),
            ),
            child: Icon(
              icon,
              size: 20,
              color: active ? Colors.white : SitewiseColors.ink,
            ),
          ),
        ),
      ),
    );
  }
}
