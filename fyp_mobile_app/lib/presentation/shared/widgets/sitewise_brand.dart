import 'package:flutter/material.dart';

import '../../../core/theme/sitewise_theme.dart';

/// The official SiteWise wordmark: the real app mark
/// (`assets/sitewise-mark-64.png`, already declared in pubspec.yaml) plus the
/// product name. Shared by the mobile pre-login screens.
///
/// The supplied cropped icon was verified byte-identical to that existing
/// asset, so no duplicate image was added to the bundle. The square image is
/// rendered at a fixed 1:1 size and is never stretched.
class SitewiseBrand extends StatelessWidget {
  final double fontSize;
  final double markSize;
  final bool showTagline;

  const SitewiseBrand({
    super.key,
    this.fontSize = 18,
    this.markSize = 32,
    this.showTagline = false,
  });

  static const String markAsset = 'assets/sitewise-mark-64.png';

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Semantics(
          label: 'SiteWise logo',
          image: true,
          child: Image.asset(
            markAsset,
            width: markSize,
            height: markSize,
            fit: BoxFit.contain,
            filterQuality: FilterQuality.high,
            errorBuilder: (_, _, _) => Container(
              width: markSize,
              height: markSize,
              decoration: BoxDecoration(
                color: SitewiseColors.action,
                borderRadius: BorderRadius.circular(markSize / 4),
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'SITEWISE',
              style: TextStyle(
                fontFamily: kFontFamily,
                fontSize: fontSize,
                fontWeight: FontWeight.w900,
                letterSpacing: .4,
                color: SitewiseColors.ink,
              ),
            ),
            if (showTagline)
              Text(
                'F&B LOCATION INTELLIGENCE',
                style: TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: fontSize * .5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: .9,
                  color: SitewiseColors.muted,
                ),
              ),
          ],
        ),
      ],
    );
  }
}
