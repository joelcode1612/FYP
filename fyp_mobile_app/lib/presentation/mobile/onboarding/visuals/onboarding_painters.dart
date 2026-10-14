import 'package:flutter/material.dart';

import '../../../../core/theme/sitewise_theme.dart';

/// CustomPainter illustrations for the onboarding flow.
///
/// These are lightweight placeholders (no bundled image assets yet). They are
/// deliberately isolated here so they can later be swapped for real Sitewise
/// property imagery without touching any page or controller code.
///
/// Theme colours come from [SitewiseColors]; the remaining literals are
/// illustration-only tints (roads, furniture, glass) with no theme meaning.

/// Street-grid map with geospatial interest points.

class OnboardingMapPainter extends CustomPainter {
  const OnboardingMapPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = const Color(0x224B78B8)
      ..strokeWidth = .7;
    for (double x = 0; x < size.width; x += 23) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
    }
    for (double y = 0; y < size.height; y += 23) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    final road = Paint()
      ..color = const Color(0x5594A3B8)
      ..strokeWidth = 3;
    canvas.drawLine(
      Offset(0, size.height * .72),
      Offset(size.width, size.height * .28),
      road,
    );
    canvas.drawLine(
      Offset(size.width * .66, 0),
      Offset(size.width * .18, size.height),
      road,
    );
    for (final p in [
      Offset(size.width * .36, size.height * .36),
      Offset(size.width * .66, size.height * .26),
      Offset(size.width * .54, size.height * .53),
      Offset(size.width * .74, size.height * .67),
    ]) {
      canvas.drawCircle(p, 5, Paint()..color = SitewiseColors.action);
      canvas.drawCircle(
        p,
        10,
        Paint()
          ..color = SitewiseColors.action.withValues(alpha: .15)
          ..style = PaintingStyle.stroke,
      );
    }
  }

  @override
  bool shouldRepaint(covariant OnboardingMapPainter oldDelegate) => false;
}

/// Simple commercial building elevation.
class OnboardingBuildingPainter extends CustomPainter {
  const OnboardingBuildingPainter();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = SitewiseColors.geoWash,
    );
    final b = Rect.fromLTWH(
      size.width * .12,
      size.height * .25,
      size.width * .76,
      size.height * .5,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(b, const Radius.circular(9)),
      Paint()..color = Colors.white,
    );
    final outline = Paint()
      ..color = SitewiseColors.ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawRRect(
      RRect.fromRectAndRadius(b, const Radius.circular(9)),
      outline,
    );
    final w = Paint()..color = const Color(0xFFBFDBFE);
    for (int row = 0; row < 2; row++) {
      for (int col = 0; col < 4; col++) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(
              b.left + 15 + col * 31,
              b.top + 15 + row * 30,
              19,
              20,
            ),
            const Radius.circular(4),
          ),
          w,
        );
      }
    }
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(size.width * .44, b.bottom - 42, size.width * .13, 42),
        const Radius.circular(5),
      ),
      Paint()..color = SitewiseColors.accent,
    );
    canvas.drawCircle(
      Offset(size.width * .13, size.height * .67),
      14,
      Paint()..color = SitewiseColors.success,
    );
    canvas.drawCircle(
      Offset(size.width * .87, size.height * .66),
      14,
      Paint()..color = SitewiseColors.success,
    );
  }

  @override
  bool shouldRepaint(covariant OnboardingBuildingPainter oldDelegate) => false;
}

/// F&B interior scene used behind the 360° tour visual.
class OnboardingInteriorPainter extends CustomPainter {
  const OnboardingInteriorPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final wall = Paint()
      ..shader = const LinearGradient(
        colors: [Color(0xFF52627A), Color(0xFF172232)],
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
      ).createShader(Offset.zero & size);
    canvas.drawRect(Offset.zero & size, wall);

    final floor = Paint()..color = const Color(0xFF8A725E);
    final path = Path()
      ..moveTo(0, size.height * .72)
      ..lineTo(size.width, size.height * .57)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(path, floor);

    final window = Paint()..color = const Color(0xFF9ED5F9);
    canvas.drawRect(
      Rect.fromLTWH(
        size.width * .12,
        size.height * .16,
        size.width * .24,
        size.height * .38,
      ),
      window,
    );
    canvas.drawRect(
      Rect.fromLTWH(
        size.width * .64,
        size.height * .12,
        size.width * .22,
        size.height * .36,
      ),
      window,
    );

    final table = Paint()..color = const Color(0xFFDAB68A);
    canvas.drawOval(
      Rect.fromLTWH(
        size.width * .30,
        size.height * .65,
        size.width * .40,
        size.height * .13,
      ),
      table,
    );

    final chair = Paint()..color = const Color(0xFFC7D0DB);
    for (final o in [
      Offset(size.width * .28, size.height * .70),
      Offset(size.width * .68, size.height * .69),
      Offset(size.width * .48, size.height * .84),
    ]) {
      canvas.drawCircle(o, 17, chair);
    }
    canvas.drawCircle(
      Offset(size.width * .50, size.height * .16),
      13,
      Paint()..color = const Color(0xFFF4F0DE),
    );
  }

  @override
  bool shouldRepaint(covariant OnboardingInteriorPainter oldDelegate) => false;
}
