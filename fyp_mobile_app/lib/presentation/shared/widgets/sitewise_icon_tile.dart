import 'package:flutter/material.dart';

import '../../../core/theme/sitewise_theme.dart';
import 'sitewise_icon.dart';

/// The tinted container behind an icon, taken from the Entrepreneur quick
/// actions: a soft circular wash with a hairline border and the glyph centred
/// inside it. It accepts any child (an `Icon`, an asset image, an existing
/// widget) so the artwork itself is never changed, only the framing.
class SitewiseIconTile extends StatelessWidget {
  final Widget child;
  final SitewiseIconTileSize size;
  final Color? background;
  final Color? borderColor;

  const SitewiseIconTile({
    super.key,
    required this.child,
    this.size = SitewiseIconTileSize.feature,
    this.background,
    this.borderColor,
  });

  /// Convenience for a Material glyph sized to this tile's band.
  SitewiseIconTile.glyph(
    IconData icon, {
    super.key,
    this.size = SitewiseIconTileSize.feature,
    this.background,
    this.borderColor,
    String? semanticLabel,
  }) : child = SitewiseIcon(
         icon,
         intent: size.intent,
         semanticLabel: semanticLabel,
       );

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size.box,
      height: size.box,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: background ?? SitewiseColors.geoWash,
        shape: size.circular ? BoxShape.circle : BoxShape.rectangle,
        borderRadius: size.circular ? null : BorderRadius.circular(size.radius),
        border: Border.all(color: borderColor ?? SitewiseColors.geoBorder),
      ),
      child: child,
    );
  }
}

/// Tile bands. `feature` is the Entrepreneur quick-action reference and the
/// default: a 54pt circle with a 24pt glyph. `card` is the feature-card band
/// from the icon table (24pt glyph), `compact` serves dense rows, and
/// `illustration` serves section artwork.
enum SitewiseIconTileSize {
  compact(40, 10, SitewiseIconIntent.button),
  card(48, 12, SitewiseIconIntent.card),
  feature(54, 16, SitewiseIconIntent.card, circular: true),
  illustration(64, 20, SitewiseIconIntent.illustration);

  const SitewiseIconTileSize(this.box, this.radius, this.intent, {
    this.circular = false,
  });

  final double box;
  final double radius;
  final SitewiseIconIntent intent;
  final bool circular;
}
