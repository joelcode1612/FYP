import 'package:flutter/material.dart';

import '../../../core/theme/sitewise_theme.dart';

/// The Home "featured action" banner.
///
/// Mirrors the reference pattern's large blue promotional card — headline,
/// supporting copy, a primary CTA — but carries a *role-specific* action
/// rather than an advertisement:
///
///  * Entrepreneur → find a fitting F&B location
///  * Owner        → showcase a commercial property
///  * Admin        → keep listings accurate / review the queue
///
/// A caller-supplied [leading] icon chip and [visual] sit on the right. The
/// banner is plain text + iconography on a blue gradient — no photographic
/// imagery — so it never implies content the data layer cannot back.

class MobileFeaturedBanner extends StatelessWidget {
  final String headline;
  final String supporting;
  final String ctaLabel;
  final VoidCallback onCta;
  final IconData icon;

  /// Optional secondary affordance (e.g. a small "3 pending" count chip).
  final Widget? trailingChip;

  const MobileFeaturedBanner({
    super.key,
    required this.headline,
    required this.supporting,
    required this.ctaLabel,
    required this.onCta,
    this.icon = Icons.location_on_rounded,
    this.trailingChip,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [SitewiseColors.action, SitewiseColors.accent],
        ),
        boxShadow: const [
          BoxShadow(
            color: Color(0x262F6FED),
            blurRadius: 18,
            offset: Offset(0, 8),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          // Soft geospatial arcs reinforcing the location-intelligence theme.
          const Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(painter: _BannerArcPainter()),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 18, 14, 18),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        headline,
                        style: const TextStyle(
                          fontFamily: kFontFamily,
                          fontSize: 18,
                          height: 1.2,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.4,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        supporting,
                        style: const TextStyle(
                          fontSize: 12,
                          height: 1.45,
                          color: Color(0xCCFFFFFF),
                        ),
                      ),
                      if (trailingChip != null) ...[
                        const SizedBox(height: 10),
                        trailingChip!,
                      ],
                      const SizedBox(height: 14),
                      _Cta(label: ctaLabel, onPressed: onCta),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                _Visual(icon: icon),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Cta extends StatelessWidget {
  final String label;
  final VoidCallback onPressed;

  const _Cta({required this.label, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: SitewiseColors.surface,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  color: SitewiseColors.action,
                ),
              ),
              const SizedBox(width: 6),
              const Icon(
                Icons.arrow_forward_rounded,
                size: 16,
                color: SitewiseColors.action,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The right-hand visual: a translucent geospatial tile with the role icon.
class _Visual extends StatelessWidget {
  final IconData icon;

  const _Visual({required this.icon});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 92,
      height: 104,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.13),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: Colors.white.withValues(alpha: 0.22)),
              ),
            ),
          ),
          Positioned(
            top: 16,
            left: 12,
            right: 12,
            bottom: 30,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
          const Positioned(
            bottom: 14,
            left: 16,
            right: 16,
            child: _GroundBars(),
          ),
          Positioned(
            top: 12,
            child: Container(
              width: 34,
              height: 34,
              decoration: const BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: Color(0x33000000),
                    blurRadius: 10,
                    offset: Offset(0, 4),
                  ),
                ],
              ),
              child: Icon(icon, size: 19, color: SitewiseColors.action),
            ),
          ),
        ],
      ),
    );
  }
}

/// Tiny skyline suggesting a commercial street.
class _GroundBars extends StatelessWidget {
  const _GroundBars();

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        for (final h in const [16.0, 26.0, 12.0, 21.0])
          Container(
            width: 9,
            height: h,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.30),
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(2),
              ),
            ),
          ),
      ],
    );
  }
}

/// Faint concentric location rings in the banner's lower-right.
class _BannerArcPainter extends CustomPainter {
  const _BannerArcPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = Colors.white.withValues(alpha: 0.10);
    final center = Offset(size.width * 0.92, size.height * 0.16);
    for (final r in const [46.0, 78.0, 112.0]) {
      canvas.drawCircle(center, r, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _BannerArcPainter oldDelegate) => false;
}
