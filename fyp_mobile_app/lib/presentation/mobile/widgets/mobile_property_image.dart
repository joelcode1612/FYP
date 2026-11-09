import 'package:shared_logic/shared_logic.dart';
import 'package:flutter/material.dart';

import '../../../core/theme/sitewise_theme.dart';
import 'sitewise_network_image.dart';

/// Property imagery for the mobile tree.
///
/// When the property record carries a backend image URL (live Explore mode,
/// catalogue `image_url` or `fyp.property_photos`), it renders through
/// [SitewiseNetworkImage] — placeholder while loading, bounded backoff
/// retries, and the on-brand painted shoplot as the permanent fallback. The
/// painted placeholder is also the loading surface, so a slow network never
/// collapses the card layout.
///
/// Demo-data records carry no URL and render the deterministic shoplot
/// exactly as before — never a broken-image icon.

class MobilePropertyImage extends StatelessWidget {
  final CommercialProperty property;
  final double? width;
  final double? height;
  final BorderRadius? borderRadius;

  /// Small label chip in the corner (e.g. "360° tour").
  final String? badge;

  const MobilePropertyImage({
    super.key,
    required this.property,
    this.width,
    this.height,
    this.borderRadius,
    this.badge,
  });

  static const List<List<Color>> _palettes = [
    [Color(0xFFDCE8FB), Color(0xFFB9CFF5)],
    [Color(0xFFE3EAF2), Color(0xFFC2D2E4)],
    [Color(0xFFD9E7E4), Color(0xFFB6D2CC)],
  ];

  List<Color> get _palette =>
      _palettes[property.id.hashCode.abs() % _palettes.length];

  @override
  Widget build(BuildContext context) {
    final radius = borderRadius ?? BorderRadius.circular(12);
    // First backend-served URL wins: the detail photo list (primary first),
    // then the row's own primary image, then the catalogue's single URL.
    String? networkUrl;
    for (final candidate in property.imageUrls) {
      if (candidate.trim().isNotEmpty) {
        networkUrl = candidate;
        break;
      }
    }
    networkUrl ??= property.imageUrl?.trim().isNotEmpty == true
        ? property.imageUrl
        : null;
    final painted = _paintedSurface(badge);
    return ClipRRect(
      borderRadius: radius,
      child: SizedBox(
        width: width,
        height: height,
        child: networkUrl == null
            ? painted
            : SitewiseNetworkImage(
                url: networkUrl,
                width: width,
                height: height,
                semanticLabel: property.title,
                // The painted shoplot doubles as the loading placeholder and
                // the permanent fallback, so the card never flashes empty.
                placeholder: painted,
                fallback: painted,
              ),
      ),
    );
  }

  Widget _paintedSurface(String? badge) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: _palette,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          CustomPaint(painter: _ShopfrontPainter(_palette.last)),
          if (badge != null)
            Positioned(
              left: 8,
              bottom: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: SitewiseColors.surface.withValues(alpha: 0.92),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.threesixty_rounded,
                      size: 12,
                      color: SitewiseColors.action,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      badge,
                      style: const TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: SitewiseColors.ink,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Stylised commercial shoplot elevation — a light, geometric stand-in for a
/// listing photo.
class _ShopfrontPainter extends CustomPainter {
  final Color groundTint;

  const _ShopfrontPainter(this.groundTint);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    // Ground plane.
    canvas.drawRect(
      Rect.fromLTWH(0, h * 0.78, w, h * 0.22),
      Paint()..color = groundTint.withValues(alpha: 0.55),
    );

    // Main facade block.
    final facade = Rect.fromLTWH(w * 0.14, h * 0.26, w * 0.72, h * 0.52);
    canvas.drawRRect(
      RRect.fromRectAndRadius(facade, const Radius.circular(6)),
      Paint()..color = Colors.white.withValues(alpha: 0.92),
    );

    // Awning stripe.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(w * 0.11, h * 0.20, w * 0.78, h * 0.09),
        const Radius.circular(4),
      ),
      Paint()..color = SitewiseColors.action.withValues(alpha: 0.85),
    );

    // Glazing.
    final glass = Paint()..color = SitewiseColors.geoBorder;
    for (var i = 0; i < 3; i++) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(w * 0.20 + i * w * 0.20, h * 0.36, w * 0.14, h * 0.22),
          const Radius.circular(3),
        ),
        glass,
      );
    }

    // Entrance.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(w * 0.44, h * 0.58, w * 0.14, h * 0.20),
        const Radius.circular(3),
      ),
      Paint()..color = SitewiseColors.ink.withValues(alpha: 0.75),
    );

    // Signboard.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(w * 0.34, h * 0.62, w * 0.32, h * 0.07),
        const Radius.circular(2),
      ),
      Paint()..color = SitewiseColors.ink.withValues(alpha: 0.18),
    );

    // Two street trees for depth.
    final foliage = Paint()
      ..color = SitewiseColors.success.withValues(alpha: 0.55);
    canvas.drawCircle(Offset(w * 0.09, h * 0.66), h * 0.075, foliage);
    canvas.drawCircle(Offset(w * 0.92, h * 0.68), h * 0.06, foliage);
  }

  @override
  bool shouldRepaint(covariant _ShopfrontPainter oldDelegate) =>
      oldDelegate.groundTint != groundTint;
}
