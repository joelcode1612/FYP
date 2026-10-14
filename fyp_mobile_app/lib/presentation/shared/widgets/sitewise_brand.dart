import 'package:flutter/material.dart';

import '../../../core/theme/sitewise_theme.dart';

/// The Sitewise wordmark (gradient mark + name). Shared by the mobile
/// pre-login screens (onboarding header, auth screen). Colours come from the
/// central [SitewiseColors] design system.

class SitewiseBrand extends StatelessWidget {
  final double fontSize;

  const SitewiseBrand({super.key, this.fontSize = 18});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(9),
            gradient: const LinearGradient(
              colors: [SitewiseColors.action, SitewiseColors.accent],
            ),
          ),
          child: const Icon(
            Icons.location_city_rounded,
            size: 17,
            color: Colors.white,
          ),
        ),
        const SizedBox(width: 9),
        Text(
          'Sitewise',
          style: TextStyle(
            fontFamily: 'Sora',
            fontSize: fontSize,
            fontWeight: FontWeight.w800,
            letterSpacing: -.5,
            color: SitewiseColors.ink,
          ),
        ),
      ],
    );
  }
}
