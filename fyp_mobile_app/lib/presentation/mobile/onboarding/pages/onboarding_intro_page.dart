import 'package:flutter/material.dart';

import '../../../../core/theme/sitewise_theme.dart';
import '../../../shared/widgets/sitewise_brand.dart';
import '../visuals/intro_hero_visual.dart';
import '../widgets/onboarding_page_indicator.dart';

/// Onboarding step 1 of 5 — Introduction.
///
/// Presentation only: progression and completion are owned by
/// `OnboardingController`. [onNext] and [onSkip] are wired by the host
/// (`OnboardingFlowPage`) to the controller, so the labels here are purely
/// visual and the navigation semantics are unchanged.

class OnboardingIntroPage extends StatelessWidget {
  final VoidCallback onSkip;
  final VoidCallback onNext;

  const OnboardingIntroPage({
    super.key,
    required this.onSkip,
    required this.onNext,
  });

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: SitewiseColors.surface,
      child: Stack(
        children: [
          // Hero area: centred brand + copy on top, property visual below.
          Column(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  physics: const ClampingScrollPhysics(),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 22, 24, 0),
                    child: Column(
                      children: [
                        const _BrandLockup(),
                        const SizedBox(height: 26),
                        const _Headline(),
                        const SizedBox(height: 12),
                        const _Subcopy(),
                        const SizedBox(height: 8),
                        // The visual is the focal point: give it generous room.
                        const SizedBox(height: 320, child: IntroHeroVisual()),
                      ],
                    ),
                  ),
                ),
              ),
              // Reserve the height the overlay panel consumes so the hero is
              // never hidden behind it on short screens.
              const _OverlaySpacer(),
            ],
          ),

          // White rounded bottom overlay panel, pinned to the bottom edge.
          Align(
            alignment: Alignment.bottomCenter,
            child: _BottomPanel(onNext: onNext, onSkip: onSkip),
          ),
        ],
      ),
    );
  }
}

/// Height of the bottom overlay panel, expressed as a function of the hero
/// area so short and tall phones both reserve enough room.
class _OverlaySpacer extends StatelessWidget {
  const _OverlaySpacer();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(height: _BottomPanel.contentHeight);
  }
}

/// Centred logo mark + app name.
class _BrandLockup extends StatelessWidget {
  const _BrandLockup();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          width: 62,
          height: 62,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(19),
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [SitewiseColors.action, SitewiseColors.accent],
            ),
            boxShadow: const [
              BoxShadow(
                color: Color(0x2E2F6FED),
                blurRadius: 20,
                offset: Offset(0, 9),
              ),
            ],
          ),
          child: const Icon(
            Icons.storefront_rounded,
            size: 31,
            color: Colors.white,
          ),
        ),
        const SizedBox(height: 12),
        const SitewiseBrand(fontSize: 23),
      ],
    );
  }
}

/// Centred multi-line headline with the key phrase in Sitewise blue.
class _Headline extends StatelessWidget {
  const _Headline();

  static const String _leadIn = 'Find the right ';
  static const String _accented = 'F&B location';
  static const String _tail = '\nwith confidence';
  @override
  Widget build(BuildContext context) {
    return Text.rich(
      const TextSpan(
        children: [
          TextSpan(text: _leadIn),
          TextSpan(
            text: _accented,
            style: TextStyle(color: SitewiseColors.action),
          ),
          TextSpan(text: _tail),
        ],
      ),
      textAlign: TextAlign.center,
      style: const TextStyle(
        fontFamily: 'Sora',
        fontSize: 25,
        height: 1.18,
        fontWeight: FontWeight.w800,
        letterSpacing: -.7,
        color: SitewiseColors.ink,
      ),
    );
  }
}

/// Short, muted, centred supporting paragraph.
class _Subcopy extends StatelessWidget {
  const _Subcopy();

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 300),
      child: const Text(
        'Combine business preferences, location intelligence and property '
        'data to discover and compare suitable commercial properties.',
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: 13,
          height: 1.5,
          color: SitewiseColors.muted,
        ),
      ),
    );
  }
}

/// White rounded panel that overlaps the property visual and merges into the
/// bottom of the screen: progress indicators, full-width CTA, and a muted skip.
class _BottomPanel extends StatelessWidget {
  const _BottomPanel({required this.onNext, required this.onSkip});

  /// Approximate panel height used to reserve space above it.
  static const double contentHeight = 196;

  final VoidCallback onNext;
  final VoidCallback onSkip;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: SitewiseColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
        boxShadow: [
          BoxShadow(
            color: Color(0x1210151F),
            blurRadius: 24,
            offset: Offset(0, -6),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          // Extra top padding makes the panel visibly sit *over* the image.
          padding: const EdgeInsets.fromLTRB(22, 26, 22, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const OnboardingPageIndicator(index: 0),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton(
                  onPressed: onNext,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: SitewiseColors.action,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    shape: const StadiumBorder(),
                    textStyle: const TextStyle(
                      fontFamily: 'Sora',
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      letterSpacing: .1,
                    ),
                  ),
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text('Get Started'),
                      SizedBox(width: 8),
                      Icon(Icons.arrow_forward_rounded, size: 19),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 2),
              TextButton(
                onPressed: onSkip,
                style: TextButton.styleFrom(
                  foregroundColor: SitewiseColors.muted,
                  minimumSize: const Size(48, 42),
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  textStyle: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                child: const Text('Skip for now'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
