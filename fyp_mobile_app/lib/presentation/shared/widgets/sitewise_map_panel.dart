import 'package:flutter/material.dart';

import '../../../core/theme/sitewise_theme.dart';

/// Stylised map placeholder panel (pins rendered from lat/lng proportions).
/// Swap the body for a real map SDK later — the contract (pins + onPinTap)
/// stays the same so pages are unaffected.

class SitewiseMapPanel extends StatelessWidget {
  final List<MapPin> pins;
  final double height;
  final ValueChanged<MapPin>? onPinTap;

  const SitewiseMapPanel({
    super.key,
    required this.pins,
    this.height = 220,
    this.onPinTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      width: double.infinity,
      decoration: BoxDecoration(
        color: SitewiseColors.geoWash,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: SitewiseColors.geoBorder),
      ),
      child: Stack(
        children: [
          CustomPaint(size: Size.infinite, painter: _GridPainter()),
          for (final pin in pins)
            Align(
              alignment: Alignment(
                ((pin.longitude - 100.3) / 3.5).clamp(-0.9, 0.9),
                -((pin.latitude - 1.5) / 4.0).clamp(-0.9, 0.9),
              ),
              child: IconButton(
                tooltip: pin.label,
                icon: Icon(
                  Icons.location_pin,
                  color: pin.highlighted
                      ? SitewiseColors.danger
                      : SitewiseColors.action,
                  size: pin.highlighted ? 34 : 26,
                ),
                onPressed: onPinTap == null ? null : () => onPinTap!(pin),
              ),
            ),
          Positioned(
            right: 8,
            bottom: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: SitewiseColors.surface,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: SitewiseColors.border),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.map_outlined, size: 14),
                  SizedBox(width: 4),
                  Text('Klang Valley & beyond', style: TextStyle(fontSize: 11)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class MapPin {
  final String id;
  final String label;
  final double latitude;
  final double longitude;
  final bool highlighted;

  const MapPin({
    required this.id,
    required this.label,
    required this.latitude,
    required this.longitude,
    this.highlighted = false,
  });
}

class _GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = SitewiseColors.geoBorder.withValues(alpha: 0.6)
      ..strokeWidth = 1;
    for (var x = 0.0; x < size.width; x += 28) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (var y = 0.0; y < size.height; y += 28) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
    final road = Paint()
      ..color = Colors.white
      ..strokeWidth = 6;
    canvas.drawLine(
      Offset(0, size.height * 0.6),
      Offset(size.width, size.height * 0.45),
      road,
    );
    canvas.drawLine(
      Offset(size.width * 0.35, 0),
      Offset(size.width * 0.5, size.height),
      road,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
