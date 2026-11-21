import 'package:flutter/material.dart';

import 'package:fyp/core/theme/sitewise_theme.dart';
import 'package:fyp/shared/presentation/widgets/sitewise_brand.dart';

/// Back arrow + the untouched SiteWise wordmark.
///
/// Mirrors the existing Forgot Password header so the registration funnel
/// keeps the same 40px control, centring and spacing as the rest of the
/// pre-login screens. The arrow is handled by the caller for all three steps.
class SignupHeader extends StatelessWidget {
  const SignupHeader({super.key, required this.onBack});

  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 4, 12, 2),
    child: Row(
      children: <Widget>[
        Material(
          color: SitewiseColors.surface,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onBack,
            child: const SizedBox(
              width: 40,
              height: 40,
              child: Icon(Icons.arrow_back_rounded, size: 19),
            ),
          ),
        ),
        const Spacer(),
        const SitewiseBrand(),
        const Spacer(),
        const SizedBox(width: 40),
      ],
    ),
  );
}

/// Decorative light-blue city band at the foot of Step 1.
///
/// Drawn rather than bundled as a bitmap so it scales to any Android width,
/// adds no asset and introduces no third-party image dependency. It is
/// excluded from the semantics tree: it carries no information.
class SignupCityscape extends StatelessWidget {
  const SignupCityscape({super.key});

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: ClipRRect(
      borderRadius: const BorderRadius.vertical(
        top: Radius.circular(SitewiseSpacing.radiusLg),
      ),
      child: SizedBox(
        height: 104,
        width: double.infinity,
        child: CustomPaint(painter: _SkylinePainter()),
      ),
    ),
  );
}

class _SkylinePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final ground = h - 10;

    final wash = Paint()
      ..color = SitewiseColors.infoWash.withValues(alpha: .85);
    canvas.drawRect(Rect.fromLTWH(0, 0, w, h), wash);
    canvas.drawRect(
      Rect.fromLTWH(0, ground, w, h - ground),
      Paint()..color = SitewiseColors.accent.withValues(alpha: .16),
    );

    // (horizontal position, width, height) as fractions of the band.
    const buildings = <(double, double, double)>[
      (0.04, 0.15, 0.42),
      (0.20, 0.12, 0.60),
      (0.33, 0.14, 0.36),
      (0.53, 0.13, 0.66),
      (0.68, 0.11, 0.45),
      (0.81, 0.16, 0.55),
    ];
    for (var i = 0; i < buildings.length; i++) {
      final (x, width, height) = buildings[i];
      final left = w * x;
      final right = w * (x + width);
      final top = ground - h * height;
      final body = RRect.fromRectAndRadius(
        Rect.fromLTRB(left, top, right, ground),
        const Radius.circular(4),
      );
      canvas.drawRRect(
        body,
        Paint()
          ..color = SitewiseColors.accent.withValues(
            alpha: i.isEven ? .24 : .34,
          ),
      );
      // Two columns of windows, kept well inside the building outline.
      final windowPaint = Paint()
        ..color = SitewiseColors.surface.withValues(alpha: .78);
      final columnWidth = (right - left) / 5;
      for (var row = 0; row < 3; row++) {
        final wy = top + 9 + row * 14.0;
        if (wy > ground - 8) break;
        for (var col = 0; col < 2; col++) {
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromLTWH(
                left + columnWidth * (1 + col * 2),
                wy,
                columnWidth,
                7,
              ),
              const Radius.circular(1.5),
            ),
            windowPaint,
          );
        }
      }
    }

    // Trees: simple canopies on either side of the centre.
    final treePaint = Paint()
      ..color = SitewiseColors.success.withValues(alpha: .45);
    for (final x in <double>[0.31, 0.73]) {
      canvas.drawCircle(Offset(w * x, ground - 12), 9, treePaint);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(w * x - 1.5, ground - 12, 3, 12),
          const Radius.circular(1.5),
        ),
        Paint()..color = SitewiseColors.muted.withValues(alpha: .45),
      );
    }

    // The storefront at the centre of the band, with an awning.
    final centre = w / 2;
    final shopTop = ground - 34;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(centre - 26, shopTop, 52, 34),
        const Radius.circular(4),
      ),
      Paint()..color = SitewiseColors.surface,
    );
    final awning = Path()
      ..moveTo(centre - 31, shopTop)
      ..lineTo(centre + 31, shopTop)
      ..lineTo(centre + 26, shopTop + 11)
      ..lineTo(centre - 26, shopTop + 11)
      ..close();
    canvas.drawPath(
      awning,
      Paint()..color = SitewiseColors.action.withValues(alpha: .85),
    );

    // Location pin above the storefront.
    final pin = Paint()..color = SitewiseColors.action;
    canvas.drawCircle(Offset(centre, shopTop - 24), 8, pin);
    canvas.drawPath(
      Path()
        ..moveTo(centre - 5, shopTop - 20)
        ..lineTo(centre, shopTop - 11)
        ..lineTo(centre + 5, shopTop - 20)
        ..close(),
      pin,
    );
    canvas.drawCircle(
      Offset(centre, shopTop - 24),
      3,
      Paint()..color = SitewiseColors.surface,
    );
  }

  @override
  bool shouldRepaint(covariant _SkylinePainter oldDelegate) => false;
}

/// Email-verification illustration: a mail glyph in a pale-blue tile with a
/// green "sent" badge. Uses the shared design tokens only.
class SignupVerificationIllustration extends StatelessWidget {
  const SignupVerificationIllustration({super.key});

  @override
  Widget build(BuildContext context) => Center(
    child: SizedBox(
      width: 108,
      height: 108,
      child: Stack(
        children: <Widget>[
          Container(
            decoration: BoxDecoration(
              color: SitewiseColors.infoWash,
              borderRadius: BorderRadius.circular(SitewiseSpacing.radiusXl),
            ),
            alignment: Alignment.center,
            child: const Icon(
              Icons.mark_email_unread_outlined,
              size: 48,
              color: SitewiseColors.action,
            ),
          ),
          Positioned(
            right: 4,
            bottom: 4,
            child: Container(
              width: 30,
              height: 30,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: SitewiseColors.success,
              ),
              child: const Icon(
                Icons.check_rounded,
                size: 18,
                color: SitewiseColors.surface,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

/// User-facing error banner. Never renders raw exceptions, endpoints or
/// provider text — the caller passes an already-safe sentence.
class SignupErrorBanner extends StatelessWidget {
  const SignupErrorBanner({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: SitewiseColors.dangerWash,
        borderRadius: BorderRadius.circular(SitewiseSpacing.radius),
        border: Border.all(
          color: SitewiseColors.danger.withValues(alpha: .35),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Icon(
            Icons.error_outline_rounded,
            size: 17,
            color: SitewiseColors.danger,
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                fontSize: 12,
                height: 1.4,
                color: SitewiseColors.danger,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
