import 'package:flutter/material.dart';

import '../../../core/theme/sitewise_theme.dart';

/// Where an icon is used, so its size and colour come from one place.
///
/// The bands follow the Entrepreneur mobile screens, which are the visual
/// reference for the whole app: bottom navigation and app-bar actions are 24,
/// input-field and button glyphs are 20, feature-card glyphs are 24, section
/// illustrations are 32, and dense metadata stays at 16. Sizes are not
/// collapsed into a single value — a glyph is sized by its context.
enum SitewiseIconIntent {
  nav(24, SitewiseColors.muted),
  appBarAction(24, SitewiseColors.muted),
  field(20, SitewiseColors.muted),
  button(20, SitewiseColors.action),
  card(24, SitewiseColors.action),
  illustration(32, SitewiseColors.action),
  inline(16, SitewiseColors.muted);

  const SitewiseIconIntent(this.size, this.tokenColor);

  final double size;
  final Color tokenColor;
}

/// A themed Material glyph.
///
/// Wraps the existing `Icons.*` artwork unchanged: it only standardises size,
/// colour token and the accessibility label. Pass [color] when a glyph carries
/// brand artwork that must keep its own colour (Apple, Google), or when a
/// success/warning/danger tint is the correct semantic. Tap targets stay with
/// the interactive ancestor (`IconButton`, `InkWell`), which already enforces
/// Flutter's 48dp minimum — sizing the glyph larger would not make it easier
/// to hit and would inflate dense rows.
class SitewiseIcon extends StatelessWidget {
  final IconData icon;
  final SitewiseIconIntent intent;
  final Color? color;
  final bool selected;
  final String? semanticLabel;

  const SitewiseIcon(
    this.icon, {
    super.key,
    this.intent = SitewiseIconIntent.inline,
    this.color,
    this.selected = false,
    this.semanticLabel,
  });

  @override
  Widget build(BuildContext context) {
    return Icon(
      icon,
      size: intent.size,
      color: color ?? (selected ? SitewiseColors.action : intent.tokenColor),
      semanticLabel: semanticLabel,
    );
  }
}
