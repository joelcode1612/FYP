import 'package:flutter/material.dart';

import 'package:fyp/core/theme/sitewise_m3.dart';
import 'package:fyp/core/theme/sitewise_theme.dart';

/// Visual priority of an action inside an Owner/Agent property card.
///
/// This affects layout and styling only. Callers still decide exactly which
/// actions exist and whether each callback is enabled.
enum ProviderCardActionEmphasis { primary, secondary, quiet }

/// One existing property-card action, wrapped with consistent sizing metadata.
@immutable
class ProviderCardAction {
  const ProviderCardAction({
    required this.label,
    required this.onPressed,
    this.icon,
    this.emphasis = ProviderCardActionEmphasis.secondary,
    this.tooltip,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final ProviderCardActionEmphasis emphasis;
  final String? tooltip;
}

/// Responsive action row for Owner and Agent property cards.
///
/// Layout rules:
/// * one action — full width;
/// * two actions — side by side only when each can keep a comfortable width,
///   otherwise stacked full width;
/// * three or more — primary action full width first, remaining actions share
///   a row only when they fit, otherwise stack.
///
/// Sizing is deliberately independent of the label length: text is never
/// shrunk to force actions into a row.
class ProviderCardActions extends StatelessWidget {
  const ProviderCardActions({
    super.key,
    required this.actions,
  });

  /// Minimum height for non-primary actions.
  static const double minActionHeight = 48;

  /// Preferred height for the card's primary action.
  static const double primaryActionHeight = 52;

  /// Minimum gap between adjacent or stacked actions.
  static const double gap = 12;

  static const double horizontalPadding = 16;

  final List<ProviderCardAction> actions;

  @override
  Widget build(BuildContext context) {
    if (actions.isEmpty) return const SizedBox.shrink();
    if (actions.length == 1) {
      return _fullWidth(_button(actions.single));
    }

    // Two actions are peers: show them side by side when both labels fit, and
    // stack them otherwise. Neither is promoted to a full-width row first.
    if (actions.length == 2) {
      return LayoutBuilder(
        builder: (context, constraints) => _rowOrColumn(
          context,
          constraints,
          actions,
        ),
      );
    }

    final primary = actions.first;
    final remaining = actions.sublist(1);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _fullWidth(_button(primary)),
        SizedBox(height: gap),
        LayoutBuilder(
          builder: (context, constraints) =>
              _rowOrColumn(context, constraints, remaining),
        ),
      ],
    );
  }

  Widget _rowOrColumn(
    BuildContext context,
    BoxConstraints constraints,
    List<ProviderCardAction> items,
  ) {
    // Compare against the real rendered label width instead of a magic
    // breakpoint, so a long action ("Propose a change") stacks rather than
    // truncating on a narrow phone.
    final widest = items
        .map((action) => _intrinsicWidth(context, action))
        .reduce((a, b) => a > b ? a : b);
    final requiredWidth = widest * items.length + gap * (items.length - 1);
    if (constraints.maxWidth >= requiredWidth) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          for (var i = 0; i < items.length; i++) ...[
            if (i > 0) SizedBox(width: gap),
            Expanded(child: _button(items[i])),
          ],
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < items.length; i++) ...[
          if (i > 0) SizedBox(height: gap),
          _fullWidth(_button(items[i])),
        ],
      ],
    );
  }

  double _intrinsicWidth(BuildContext context, ProviderCardAction action) {
    final painter = TextPainter(
      text: TextSpan(
        text: action.label,
        style: const TextStyle(
          fontFamily: kFontFamily,
          fontSize: 14,
          fontWeight: FontWeight.w700,
        ),
      ),
      maxLines: 1,
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    final iconWidth = action.icon == null ? 0.0 : 26.0;
    return painter.width + iconWidth + horizontalPadding * 2 + 8;
  }

  Widget _fullWidth(Widget child) =>
      SizedBox(width: double.infinity, child: child);

  Widget _button(ProviderCardAction action) {
    final style = _buttonStyle(action.emphasis);
    final icon = action.icon;
    final content = Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 18),
          const SizedBox(width: 8),
        ],
        Flexible(
          child: Text(
            action.label,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
    final Widget button = switch (action.emphasis) {
      ProviderCardActionEmphasis.primary => FilledButton(
        onPressed: action.onPressed,
        style: style,
        child: content,
      ),
      ProviderCardActionEmphasis.secondary => OutlinedButton(
        onPressed: action.onPressed,
        style: style,
        child: content,
      ),
      ProviderCardActionEmphasis.quiet => TextButton(
        onPressed: action.onPressed,
        style: style,
        child: content,
      ),
    };
    final tooltip = action.tooltip;
    if (tooltip == null) return button;
    return Tooltip(
      message: tooltip,
      triggerMode: TooltipTriggerMode.longPress,
      child: button,
    );
  }

  ButtonStyle _buttonStyle(ProviderCardActionEmphasis emphasis) {
    final height = emphasis == ProviderCardActionEmphasis.primary
        ? primaryActionHeight
        : minActionHeight;
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(SitewiseM3.radiusPill),
    );
    final textStyle = const TextStyle(
      fontFamily: kFontFamily,
      fontSize: 14,
      fontWeight: FontWeight.w700,
      height: 1.15,
    );
    return switch (emphasis) {
      ProviderCardActionEmphasis.primary => FilledButton.styleFrom(
        backgroundColor: SitewiseColors.action,
        foregroundColor: SitewiseM3.surface,
        minimumSize: Size.fromHeight(height),
        padding: const EdgeInsets.symmetric(horizontal: horizontalPadding),
        shape: shape,
        textStyle: textStyle,
      ),
      ProviderCardActionEmphasis.secondary => OutlinedButton.styleFrom(
        foregroundColor: SitewiseColors.action,
        side: const BorderSide(color: SitewiseColors.action),
        minimumSize: Size.fromHeight(height),
        padding: const EdgeInsets.symmetric(horizontal: horizontalPadding),
        shape: shape,
        textStyle: textStyle,
      ),
      ProviderCardActionEmphasis.quiet => TextButton.styleFrom(
        foregroundColor: SitewiseColors.action,
        minimumSize: Size.fromHeight(height),
        padding: const EdgeInsets.symmetric(horizontal: horizontalPadding),
        shape: shape,
        textStyle: textStyle,
      ),
    };
  }
}
