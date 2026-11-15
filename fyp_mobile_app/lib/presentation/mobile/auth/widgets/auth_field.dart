import 'package:flutter/material.dart';

import '../../../../core/theme/sitewise_theme.dart';
import '../../../shared/widgets/sitewise_icon.dart';

/// Labelled text field used across the Log In / Sign Up forms.

class AuthField extends StatelessWidget {
  final String label;
  final String hint;
  final TextEditingController controller;
  final IconData icon;
  final bool obscure;
  final Widget? suffix;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final void Function(String)? onSubmitted;
  final Iterable<String>? autofillHints;

  /// Renders a red asterisk after the label for mandatory fields.
  final bool required;

  const AuthField({
    super.key,
    required this.label,
    required this.controller,
    required this.hint,
    required this.icon,
    this.obscure = false,
    this.suffix,
    this.keyboardType,
    this.textInputAction,
    this.onSubmitted,
    this.autofillHints,
    this.required = false,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text.rich(
          TextSpan(
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: SitewiseColors.ink,
            ),
            children: <InlineSpan>[
              TextSpan(text: label),
              if (required)
                const TextSpan(
                  text: ' *',
                  style: TextStyle(color: SitewiseColors.danger),
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          obscureText: obscure,
          keyboardType: keyboardType,
          textInputAction: textInputAction,
          onSubmitted: onSubmitted,
          autofillHints: autofillHints,
          // Lets the framework scroll the focused field above the keyboard.
          scrollPadding: const EdgeInsets.all(24),
          style: const TextStyle(fontSize: 15, color: SitewiseColors.ink),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: const TextStyle(
              fontSize: 13,
              color: SitewiseColors.overline,
            ),
            prefixIcon: SitewiseIcon(
              icon,
              intent: SitewiseIconIntent.field,
              semanticLabel: label,
            ),
            suffixIcon: suffix,
            filled: true,
            fillColor: SitewiseColors.surface,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 16,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(SitewiseSpacing.radiusLg),
              borderSide: const BorderSide(color: SitewiseColors.border),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(SitewiseSpacing.radiusLg),
              borderSide: const BorderSide(color: SitewiseColors.border),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(SitewiseSpacing.radiusLg),
              borderSide: const BorderSide(
                color: SitewiseColors.action,
                width: 1.2,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
