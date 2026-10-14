import 'package:shared_logic/shared_logic.dart';
import 'package:flutter/material.dart';

import '../../../../core/theme/sitewise_theme.dart';
import '../../../shared/landing/landing_content.dart';
import '../../../shared/widgets/sitewise_button.dart';
import '../../../shared/widgets/sitewise_map_panel.dart';
import '../../../shared/widgets/sitewise_secondary_button.dart';
import '../../widgets/mobile_tour_viewer.dart';

/// Mobile landing section widgets (stacked compositions). Same shared
/// [LandingContent] as the Web tree.

class MobileEyebrow extends StatelessWidget {
  final String text;
  const MobileEyebrow(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            color: SitewiseColors.action,
          ),
        ),
        const SizedBox(width: 7),
        Flexible(
          child: Text(
            text.toUpperCase(),
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
              color: SitewiseColors.overline,
            ),
          ),
        ),
      ],
    );
  }
}

class MobileSectionHead extends StatelessWidget {
  final String eyebrow;
  final String title;
  final String body;
  const MobileSectionHead({
    super.key,
    required this.eyebrow,
    required this.title,
    required this.body,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MobileEyebrow(eyebrow),
        const SizedBox(height: 10),
        Text(
          title,
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w700,
            letterSpacing: -0.5,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          body,
          style: const TextStyle(
            color: SitewiseColors.muted,
            fontSize: 14,
            height: 1.65,
          ),
        ),
      ],
    );
  }
}

class MobileHeroCopy extends StatelessWidget {
  final VoidCallback onGetStarted;
  final VoidCallback onSeeHow;
  const MobileHeroCopy({
    super.key,
    required this.onGetStarted,
    required this.onSeeHow,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const MobileEyebrow(LandingContent.eyebrow),
        const SizedBox(height: 14),
        RichText(
          text: const TextSpan(
            style: TextStyle(
              fontSize: 34,
              fontWeight: FontWeight.w800,
              letterSpacing: -1,
              height: 1.1,
              color: SitewiseColors.ink,
            ),
            children: [
              TextSpan(text: LandingContent.heroTitleA),
              TextSpan(
                text: LandingContent.heroTitleEm,
                style: TextStyle(color: SitewiseColors.action),
              ),
              TextSpan(text: LandingContent.heroTitleB),
            ],
          ),
        ),
        const SizedBox(height: 14),
        const Text(
          LandingContent.heroLead,
          style: TextStyle(
            color: SitewiseColors.muted,
            fontSize: 14,
            height: 1.7,
          ),
        ),
        const SizedBox(height: 20),
        SitewiseButton(
          label: LandingContent.heroPrimary,
          onPressed: onGetStarted,
        ),
        const SizedBox(height: 8),
        SitewiseSecondaryButton(
          label: LandingContent.heroSecondary,
          onPressed: onSeeHow,
        ),
      ],
    );
  }
}

class MobileHeroVisual extends StatelessWidget {
  const MobileHeroVisual({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 330,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: SitewiseColors.border),
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFFF9FBFE), Color(0xFFEEF4FB)],
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: Stack(
          children: [
            const Positioned.fill(
              child: CustomPaint(painter: _MobileMapPainter()),
            ),
            Positioned(
              right: 14,
              bottom: 14,
              child: Container(
                width: 198,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.95),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: SitewiseColors.border),
                ),
                child: const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'LOCATION INSIGHT',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: SitewiseColors.overline,
                      ),
                    ),
                    SizedBox(height: 8),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Text(
                          '91',
                          style: TextStyle(
                            fontSize: 30,
                            fontWeight: FontWeight.w800,
                            height: 1,
                          ),
                        ),
                        SizedBox(width: 6),
                        Text(
                          '/ 100',
                          style: TextStyle(
                            fontSize: 11,
                            color: SitewiseColors.muted,
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: 8),
                    _MobileMeter(pct: 0.88),
                    SizedBox(height: 6),
                    _MobileMeter(pct: 0.94),
                    SizedBox(height: 6),
                    _MobileMeter(pct: 0.65),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MobileMeter extends StatelessWidget {
  final double pct;
  const _MobileMeter({required this.pct});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(99),
      child: LinearProgressIndicator(
        value: pct,
        minHeight: 5,
        backgroundColor: const Color(0xFFEEF0F3),
        valueColor: const AlwaysStoppedAnimation(SitewiseColors.action),
      ),
    );
  }
}

class _MobileMapPainter extends CustomPainter {
  const _MobileMapPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = const Color(0xFF94A3B8).withValues(alpha: 0.16)
      ..strokeWidth = 1;
    for (var x = 0.0; x < size.width; x += 28) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
    }
    for (var y = 0.0; y < size.height; y += 28) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    final road = Paint()
      ..color = Colors.white.withValues(alpha: 0.86)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 26;
    canvas.drawLine(
      Offset(-size.width * 0.1, size.height * 0.55),
      Offset(size.width * 1.1, size.height * 0.4),
      road,
    );
    final ring = Paint()
      ..color = SitewiseColors.action.withValues(alpha: 0.46)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(size.width * 0.5, size.height * 0.5),
        width: 220,
        height: 155,
      ),
      ring,
    );
    for (final p in [
      Offset(size.width * 0.18, size.height * 0.3),
      Offset(size.width * 0.75, size.height * 0.38),
      Offset(size.width * 0.6, size.height * 0.7),
    ]) {
      canvas.drawCircle(p, 10, Paint()..color = Colors.white);
      canvas.drawCircle(p, 5, Paint()..color = SitewiseColors.action);
    }
    final c = Offset(size.width * 0.5, size.height * 0.5);
    canvas.drawCircle(c, 22, Paint()..color = Colors.white);
    canvas.drawCircle(
      c,
      22,
      Paint()
        ..color = SitewiseColors.success
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    canvas.drawCircle(c, 7, Paint()..color = SitewiseColors.success);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class MobileRoleCards extends StatelessWidget {
  final void Function(AppRole role, String route) onEnter;
  const MobileRoleCards({super.key, required this.onEnter});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (final r in LandingContent.roles)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        color: SitewiseColors.geoWash,
                        borderRadius: BorderRadius.circular(11),
                      ),
                      child: Icon(
                        r.icon,
                        color: SitewiseColors.action,
                        size: 22,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      r.title,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      r.body,
                      style: const TextStyle(
                        color: SitewiseColors.muted,
                        fontSize: 13,
                        height: 1.6,
                      ),
                    ),
                    const SizedBox(height: 12),
                    InkWell(
                      onTap: () => onEnter(r.role, r.route),
                      child: Text(
                        '${r.linkLabel} →',
                        style: const TextStyle(
                          color: SitewiseColors.action,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class MobileSteps extends StatelessWidget {
  const MobileSteps({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (final s in LandingContent.steps)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: SitewiseColors.geoWash,
                        borderRadius: BorderRadius.circular(9),
                        border: Border.all(color: SitewiseColors.geoBorder),
                      ),
                      child: Center(
                        child: Text(
                          s.num,
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 13,
                            color: SitewiseColors.action,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            s.title,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            s.body,
                            style: const TextStyle(
                              fontSize: 12.5,
                              height: 1.6,
                              color: SitewiseColors.muted,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class MobileGeoFeatures extends StatelessWidget {
  const MobileGeoFeatures({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (final f in LandingContent.features)
          Padding(
            padding: const EdgeInsets.only(top: 14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: const Color(0xFFF2F4F7),
                    borderRadius: BorderRadius.circular(9),
                    border: Border.all(color: SitewiseColors.border),
                  ),
                  child: Icon(f.icon, size: 18, color: SitewiseColors.action),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        f.title,
                        style: const TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        f.body,
                        style: const TextStyle(
                          fontSize: 12.5,
                          height: 1.55,
                          color: SitewiseColors.muted,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class MobileGeoVisual extends StatelessWidget {
  const MobileGeoVisual({super.key});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: SitewiseMapPanel(
        height: 300,
        pins: const [
          MapPin(id: 'g1', label: 'SS15', latitude: 3.07, longitude: 101.58),
          MapPin(id: 'g2', label: 'SS2', latitude: 3.11, longitude: 101.62),
          MapPin(
            id: 'g3',
            label: 'Selected',
            latitude: 3.09,
            longitude: 101.60,
            highlighted: true,
          ),
        ],
      ),
    );
  }
}

class MobileAssessment extends StatelessWidget {
  const MobileAssessment({super.key});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Sample assessment',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: SitewiseColors.overline,
                        ),
                      ),
                      SizedBox(height: 6),
                      Text(
                        LandingContent.assessmentProperty,
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
                Text(
                  LandingContent.assessmentScore.toStringAsFixed(0),
                  style: const TextStyle(
                    fontSize: 34,
                    fontWeight: FontWeight.w800,
                    height: 1,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            for (final d in LandingContent.drivers)
              Container(
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.all(13),
                decoration: BoxDecoration(
                  color: const Color(0xFFFBFCFD),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: SitewiseColors.border),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 7,
                          height: 7,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: d.tradeoff
                                ? SitewiseColors.warning
                                : SitewiseColors.success,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            d.title,
                            style: const TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      d.body,
                      style: const TextStyle(
                        fontSize: 11.5,
                        height: 1.5,
                        color: SitewiseColors.muted,
                      ),
                    ),
                  ],
                ),
              ),
            const Text(
              'Demonstration content only.',
              style: TextStyle(fontSize: 10.5, color: SitewiseColors.overline),
            ),
          ],
        ),
      ),
    );
  }
}

class MobileWeights extends StatelessWidget {
  const MobileWeights({super.key});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Business preference example',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            const Text(
              'Criteria can reflect the priorities of a specific F&B concept.',
              style: TextStyle(fontSize: 12, color: SitewiseColors.muted),
            ),
            for (final w in LandingContent.weights)
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          w.$1,
                          style: const TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          '${w.$2.toStringAsFixed(0)}%',
                          style: const TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(99),
                      child: LinearProgressIndicator(
                        value: w.$2 / 100,
                        minHeight: 7,
                        backgroundColor: const Color(0xFFEEF0F3),
                        valueColor: const AlwaysStoppedAnimation(
                          SitewiseColors.ink,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class MobileTourShowcase extends StatelessWidget {
  final VoidCallback onExplore;
  const MobileTourShowcase({super.key, required this.onExplore});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MobileTourViewer(tour: LandingContent.sampleTour),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'SAMPLE SITE PROFILE · VERIFIED',
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    color: SitewiseColors.overline,
                  ),
                ),
                for (final r in LandingContent.siteProfile)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 9),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          r.$1,
                          style: const TextStyle(
                            fontSize: 12,
                            color: SitewiseColors.muted,
                          ),
                        ),
                        Text(
                          r.$2,
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 12),
                SitewiseSecondaryButton(
                  label: 'Explore properties',
                  onPressed: onExplore,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class MobileCtaBox extends StatelessWidget {
  final VoidCallback onGetStarted;
  final VoidCallback onLearn;
  const MobileCtaBox({
    super.key,
    required this.onGetStarted,
    required this.onLearn,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(28),
      decoration: BoxDecoration(
        color: SitewiseColors.ink,
        borderRadius: BorderRadius.circular(22),
      ),
      child: Column(
        children: [
          Text(
            LandingContent.ctaTitle,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            LandingContent.ctaBody,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Color(0xFFC8CED8),
              fontSize: 13,
              height: 1.65,
            ),
          ),
          const SizedBox(height: 20),
          ElevatedButton(
            onPressed: onGetStarted,
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.white,
              foregroundColor: SitewiseColors.ink,
              minimumSize: const Size(double.infinity, 48),
            ),
            child: const Text('Get Started →'),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: onLearn,
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white,
              side: const BorderSide(color: Colors.white24),
              minimumSize: const Size(double.infinity, 48),
            ),
            child: const Text('Learn how it works'),
          ),
        ],
      ),
    );
  }
}

class MobileFooter extends StatelessWidget {
  final void Function(String anchor) onNav;
  final VoidCallback onGetStarted;
  final VoidCallback onLogin;
  const MobileFooter({
    super.key,
    required this.onNav,
    required this.onGetStarted,
    required this.onLogin,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: SitewiseColors.surface,
        border: Border(top: BorderSide(color: SitewiseColors.border)),
      ),
      padding: const EdgeInsets.fromLTRB(16, 32, 16, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              _MobileBrandMark(),
              SizedBox(width: 10),
              Text(
                'Sitewise',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'Evidence-based geospatial decision support for F&B property selection.',
            style: TextStyle(fontSize: 11.5, color: SitewiseColors.muted),
          ),
          const SizedBox(height: 20),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _MobileFooterCol(
                  title: 'Platform',
                  links: [
                    ('How It Works', () => onNav('how')),
                    ('Location Intelligence', () => onNav('geo')),
                    ('Recommendations', () => onNav('recs')),
                    ('360° Tours', () => onNav('tour')),
                  ],
                ),
              ),
              Expanded(
                child: _MobileFooterCol(
                  title: 'Account',
                  links: [
                    ('Get Started', onGetStarted),
                    ('Log In', onLogin),
                    ('About', () => onNav('top')),
                    ('Contact', onGetStarted),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          const Divider(height: 1),
          const SizedBox(height: 12),
          const Text(
            '© 2026 Sitewise. Academic Project Prototype.',
            style: TextStyle(fontSize: 10.5, color: SitewiseColors.overline),
          ),
        ],
      ),
    );
  }
}

class _MobileBrandMark extends StatelessWidget {
  const _MobileBrandMark();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(9),
        gradient: const LinearGradient(
          colors: [SitewiseColors.action, SitewiseColors.accent],
        ),
      ),
      child: const Icon(Icons.location_on, color: Colors.white, size: 20),
    );
  }
}

class _MobileFooterCol extends StatelessWidget {
  final String title;
  final List<(String, VoidCallback)> links;
  const _MobileFooterCol({required this.title, required this.links});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title.toUpperCase(),
          style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700),
        ),
        for (final link in links)
          Padding(
            padding: const EdgeInsets.only(top: 9),
            child: InkWell(
              onTap: link.$2,
              child: Text(
                link.$1,
                style: const TextStyle(
                  fontSize: 11.5,
                  color: SitewiseColors.muted,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class MobileBrand extends StatelessWidget {
  final VoidCallback onTap;
  const MobileBrand({super.key, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _MobileBrandMark(),
          SizedBox(width: 8),
          Text(
            'Sitewise',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}
