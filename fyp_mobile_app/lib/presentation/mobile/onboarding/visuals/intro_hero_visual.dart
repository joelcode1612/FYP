import 'package:flutter/material.dart';

import '../../../../core/theme/sitewise_theme.dart';

/// Introduction hero visual: a soft geospatial wash behind a commercial F&B
/// property (shoplot / café frontage), with a Sitewise-blue location pin
/// anchoring the composition.
///
/// This is presentation-only placeholder art. It intentionally draws a
/// *commercial* unit — never a residential house — so the onboarding still
/// reads as Sitewise's F&B commercial property product. Replace the painted
/// unit with a real asset later without touching the page.

class IntroHeroVisual extends StatelessWidget {
  const IntroHeroVisual({super.key});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.bottomCenter,
          children: [
            // Soft pale-blue geospatial curve sitting behind the property.
            Positioned.fill(
              child: CustomPaint(painter: const _GeoWashPainter()),
            ),

            // The commercial property unit, grounded at the bottom so the
            // white overlay panel can overlap it cleanly.
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: AspectRatio(
                aspectRatio: 1.32,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: SitewiseColors.surface,
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x1410151F),
                        blurRadius: 22,
                        offset: Offset(0, 10),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(20),
                    child: const CustomPaint(painter: _FnbShoplotPainter()),
                  ),
                ),
              ),
            ),

            // Sitewise-blue location pin near the property.
            Positioned(
              left: 6,
              top: constraints.maxHeight * 0.10,
              child: const _LocationPin(),
            ),
          ],
        );
      },
    );
  }
}

/// Soft curved "geospatial" wash: two pale-blue radii plus a dashed map grid,
/// deliberately subtle so the screen stays mostly white.
class _GeoWashPainter extends CustomPainter {
  const _GeoWashPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final wash = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0xFFF4F8FF), Color(0xFFE3ECFD)],
      ).createShader(Offset.zero & size);

    // A wide ellipse whose top edge reads as the horizon of a soft map curve.
    final curve = Path()
      ..moveTo(0, size.height * 0.34)
      ..quadraticBezierTo(
        size.width * 0.5,
        size.height * 0.02,
        size.width,
        size.height * 0.34,
      )
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(curve, wash);

    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = SitewiseColors.geoBorder.withValues(alpha: 0.55);

    // Faint map grid, clipped to the wash so it reads as terrain, not UI.
    canvas.save();
    canvas.clipPath(curve);
    for (var i = 1; i < 5; i++) {
      final y = size.height * (0.42 + i * 0.12);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), line);
    }
    for (var i = 1; i < 4; i++) {
      final x = size.width * (i * 0.25);
      canvas.drawLine(
        Offset(x, size.height * 0.34),
        Offset(x, size.height),
        line,
      );
    }
    canvas.restore();

    // The prominent arc that frames the property.
    final arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..color = SitewiseColors.geoBorder;
    canvas.drawPath(
      Path()
        ..moveTo(-size.width * 0.1, size.height * 0.40)
        ..quadraticBezierTo(
          size.width * 0.5,
          size.height * 0.04,
          size.width * 1.1,
          size.height * 0.40,
        ),
      arc,
    );
  }

  @override
  bool shouldRepaint(covariant _GeoWashPainter oldDelegate) => false;
}

/// Sitewise-blue map pin with a soft shadow and a white core.
class _LocationPin extends StatelessWidget {
  const _LocationPin();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 42,
      height: 42,
      decoration: BoxDecoration(
        color: SitewiseColors.action,
        borderRadius: BorderRadius.circular(14),
        boxShadow: const [
          BoxShadow(
            color: Color(0x332F6FED),
            blurRadius: 16,
            offset: Offset(0, 7),
          ),
        ],
      ),
      child: const Icon(Icons.place_rounded, size: 22, color: Colors.white),
    );
  }
}

/// Two-storey commercial shoplot: glazed ground-floor frontage with an awning
/// and signage board — the visual language of an F&B unit, not a house.
class _FnbShoplotPainter extends CustomPainter {
  const _FnbShoplotPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final groundY = h * 0.80;

    // Sky / backdrop wash inside the card.
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFFFBFDFF), Color(0xFFEDF3FC)],
        ).createShader(Offset.zero & size),
    );

    // Distant neighbourhood blocks for depth.
    final distant = Paint()..color = const Color(0xFFE1E9F6);
    canvas.drawRect(
      Rect.fromLTWH(w * 0.04, h * 0.30, w * 0.16, h * 0.34),
      distant,
    );
    canvas.drawRect(
      Rect.fromLTWH(w * 0.82, h * 0.24, w * 0.13, h * 0.40),
      distant,
    );

    // Upper storey.
    final upper = Rect.fromLTWH(w * 0.16, h * 0.20, w * 0.68, h * 0.30);
    canvas.drawRect(upper, Paint()..color = const Color(0xFFF3F6FB));

    // Upper-storey glazing.
    final glass = Paint()..color = const Color(0xFFD8E5F8);
    for (var i = 0; i < 3; i++) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            upper.left + w * 0.05 + i * w * 0.20,
            upper.top + h * 0.06,
            w * 0.155,
            h * 0.18,
          ),
          const Radius.circular(2),
        ),
        glass,
      );
    }

    // Signage board (the F&B brand plate).
    final sign = RRect.fromRectAndRadius(
      Rect.fromLTWH(w * 0.22, h * 0.13, w * 0.56, h * 0.085),
      const Radius.circular(4),
    );
    canvas.drawRRect(sign, Paint()..color = SitewiseColors.action);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(w * 0.27, h * 0.155, w * 0.26, h * 0.035),
        const Radius.circular(2),
      ),
      Paint()..color = const Color(0x99FFFFFF),
    );

    // Ground floor frontage.
    final lower = Rect.fromLTWH(w * 0.16, h * 0.50, w * 0.68, h * 0.30);
    canvas.drawRect(lower, Paint()..color = const Color(0xFFF7FAFF));

    // Glazed shopfront mullions.
    final frame = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = const Color(0xFFC9D6EA);
    final front = Rect.fromLTWH(w * 0.21, h * 0.56, w * 0.58, h * 0.24);
    canvas.drawRRect(
      RRect.fromRectAndRadius(front, const Radius.circular(3)),
      Paint()..color = const Color(0xFFCBE0F5),
    );
    for (var i = 1; i < 4; i++) {
      final x = front.left + front.width * i / 4;
      canvas.drawLine(Offset(x, front.top), Offset(x, front.bottom), frame);
    }
    canvas.drawRRect(
      RRect.fromRectAndRadius(front, const Radius.circular(3)),
      frame,
    );

    // Awning above the shopfront.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(w * 0.19, h * 0.44, w * 0.62, h * 0.065),
        const Radius.circular(3),
      ),
      Paint()..color = const Color(0xFF2F6FED),
    );

    // Ground plane.
    canvas.drawRect(
      Rect.fromLTWH(0, groundY, w, h - groundY),
      Paint()..color = const Color(0xFFE8EEF8),
    );
    canvas.drawRect(
      Rect.fromLTWH(0, groundY, w, 1.2),
      Paint()..color = SitewiseColors.geoBorder,
    );

    // Paving + two planter boxes for a street-level feel.
    final paving = Paint()
      ..color = const Color(0xFFD9E3F3)
      ..strokeWidth = 1;
    for (var i = 1; i < 6; i++) {
      final x = w * (i / 6);
      canvas.drawLine(Offset(x, groundY + 2), Offset(x - w * 0.03, h), paving);
    }
    final planter = Paint()..color = const Color(0xFFBFD9C6);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(w * 0.20, h * 0.86, w * 0.10, h * 0.10),
        const Radius.circular(2),
      ),
      planter,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(w * 0.70, h * 0.86, w * 0.10, h * 0.10),
        const Radius.circular(2),
      ),
      planter,
    );
  }

  @override
  bool shouldRepaint(covariant _FnbShoplotPainter oldDelegate) => false;
}
