import 'package:flutter/material.dart';

import '../../../../core/theme/sitewise_theme.dart';

/// Standard onboarding page frame: a header row plus a padded content column.
/// Every onboarding page composes its body inside this layout so the header,
/// margins and vertical rhythm stay identical across the flow.

class OnboardingBaseLayout extends StatelessWidget {
  final Widget header;
  final Widget child;

  const OnboardingBaseLayout({
    super.key,
    required this.header,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        header,
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 15, 20, 22),
            child: child,
          ),
        ),
      ],
    );
  }
}

/// Small uppercase section label (e.g. "01 — BUSINESS PREFERENCES").
class OnboardingKicker extends StatelessWidget {
  final String text;

  const OnboardingKicker(this.text, {super.key});

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: const TextStyle(
      fontSize: 10.5,
      fontWeight: FontWeight.w800,
      letterSpacing: 1.1,
      color: SitewiseColors.action,
    ),
  );
}

/// Display heading for an onboarding page.
class OnboardingTitle extends StatelessWidget {
  final String text;

  const OnboardingTitle(this.text, {super.key});

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: const TextStyle(
      fontFamily: 'Sora',
      fontSize: 28,
      height: 1.08,
      fontWeight: FontWeight.w800,
      color: SitewiseColors.ink,
      letterSpacing: -.7,
    ),
  );
}

/// Supporting body copy for an onboarding page.
class OnboardingBodyText extends StatelessWidget {
  final String text;

  const OnboardingBodyText(this.text, {super.key});

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: const TextStyle(
      fontSize: 13.5,
      height: 1.45,
      color: SitewiseColors.muted,
    ),
  );
}
