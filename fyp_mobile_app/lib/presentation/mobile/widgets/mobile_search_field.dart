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
  final ValueChanged<String>? onSubmitted;
  final VoidCallback? onTap;

  /// Clears the query. When supplied alongside [controller], a clear button
  /// appears as soon as the field holds text — the only way to get back to the
  /// unfiltered list without deleting characters one at a time.
  final VoidCallback? onClear;
  final bool readOnly;
  final Widget? trailing;

  const MobileSearchField({
    super.key,
    this.hint = 'Search property, area or location',
    this.controller,
    this.onChanged,
    this.onSubmitted,
    this.onTap,
    this.onClear,
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
            onSubmitted: onSubmitted,
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
              suffixIcon: _clearButton(),
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

  /// Rebuilds only the suffix, so typing does not rebuild the whole row.
  Widget? _clearButton() {
    final controller = this.controller;
    final onClear = this.onClear;
    if (controller == null || onClear == null || readOnly) return null;
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        if (value.text.isEmpty) return const SizedBox.shrink();
        return IconButton(
          icon: const Icon(Icons.close_rounded, size: 18),
          color: SitewiseColors.muted,
          tooltip: 'Clear search',
          onPressed: onClear,
        );
      },
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
