import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:fyp/features/capture_360/domain/sphere/adaptive_sphere_plan.dart';
import 'package:fyp/features/capture_360/domain/sphere/sphere_target.dart';
import 'package:fyp/features/capture_360/presentation/widgets/capture_theme.dart';

/// Guide for the active adaptive five-ring capture plan before a session starts.
///
/// Every number on these three screens is read from the plan object rather than
/// written into the copy, so the guide describes the sweep that will actually
/// run — ring counts, spacing and the measured overlap all come from the
/// generated plan and the same projection the capture screen uses.
// SITEWISE_STANDARD_ONLY_20261126
class CapturePlanGuide extends StatefulWidget {
  const CapturePlanGuide({
    super.key,
    required this.onStart,
    this.allowEnhanced = false,
  });
  final ValueChanged<int> onStart;
  final bool allowEnhanced;

  @override
  State<CapturePlanGuide> createState() => _CapturePlanGuideState();
}

class _CapturePlanGuideState extends State<CapturePlanGuide> {
  int _step = 0;
  // The plan the next capture will actually use. Every new session runs the
  // canonical adaptive five-ring plan (12); reading the plan object instead of
  // a constant keeps this guide honest when the geometry changes: the numbers
  // below are the numbers the sweep will ask for.
  AdaptiveSpherePlan get _plan => kSpherePlanV12;
  int get _count => _plan.targetCount;
  String get _spacing => _middleSpacing.toStringAsFixed(0);

  /// The measured overlap between consecutive photographs, from the same
  /// projection the capture screen uses — not the circle approximation the
  /// coverage metrics are built on.
  String get _overlapPercent =>
      (_plan.metrics.minimumNeighbourOverlap * 100).round().toString();

  int _ringCount(String key) {
    for (final ring in _plan.rings) {
      if (ring.key == key) return ring.count;
    }
    return 0;
  }

  /// The horizontal step of the three main rings, which share their yaws.
  double get _middleSpacing {
    final middle = _plan.rings.firstWhere(
          (ring) => ring.key == 'middle',
      orElse: () => _plan.rings.first,
    );
    if (middle.yaws.isEmpty) return 0;
    return 360 / middle.yaws.length;
  }

  /// `4 + 12 + 12 + 12 + 4` — the ring breakdown, in the order the rings are
  /// captured from the top down.
  String get _ringBreakdown =>
      _plan.rings.map((ring) => '${ring.count}').join(' + ');

  void _back() {
    if (_step == 0) {
      Navigator.of(context).maybePop();
    } else {
      setState(() => _step--);
    }
  }

  void _next() {
    if (_step < 2) {
      setState(() => _step++);
    } else {
      widget.onStart(_count);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: SiteWiseColors.surface,
      appBar: AppBar(
        backgroundColor: SiteWiseColors.surface,
        foregroundColor: SiteWiseColors.ink,
        leading: IconButton(
          tooltip: 'Back',
          onPressed: _back,
          icon: const Icon(Icons.arrow_back),
        ),
        title: Text(
          const ['SiteWise', 'Before you start', 'Capture plan'][_step],
        ),
      ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
              child: LinearProgressIndicator(
                value: (_step + 1) / 3,
                minHeight: 4,
                color: SiteWiseColors.primary,
                backgroundColor: SiteWiseColors.border,
              ),
            ),
            Expanded(
              child: ListView(
                key: ValueKey(_step),
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                children: [
                  if (_step == 0) ..._intro(),
                  if (_step == 1) ..._guidance(),
                  if (_step == 2) ..._overview(),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(52),
                  backgroundColor: SiteWiseColors.primary,
                  foregroundColor: Colors.white,
                ),
                onPressed: _next,
                icon: Icon(
                  _step == 2 ? Icons.camera_alt_outlined : Icons.arrow_forward,
                ),
                label: Text(
                  _step < 2 ? 'Continue' : 'Start capture',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _heading(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Text(
      text,
      style: const TextStyle(
        color: SiteWiseColors.ink,
        fontSize: 25,
        fontWeight: FontWeight.w700,
      ),
    ),
  );

  Widget _body(String text) => Text(
    text,
    style: const TextStyle(
      color: SiteWiseColors.muted,
      fontSize: 16,
      height: 1.45,
    ),
  );

  Widget _sphere({double height = 220}) => Container(
    height: height,
    decoration: BoxDecoration(
      color: SiteWiseColors.softBlue,
      borderRadius: BorderRadius.circular(16),
    ),
    padding: const EdgeInsets.all(12),
    child: Semantics(
      label: '$_count planned photo directions',
      child: CustomPaint(painter: _PlanSpherePainter(_plan)),
    ),
  );

  List<Widget> _intro() => [
    _sphere(height: 190),
    const SizedBox(height: 22),
    _heading('Capture 360° panorama'),
    _body('Take guided photographs to create a full view of this space.'),
    const SizedBox(height: 24),
    _heading('Capture plan'),
    _notice(
      '$_count photo directions in five rings ($_ringBreakdown). '
          'Each ring steps $_spacing° horizontally; the upper and lower rings '
          'are offset by half a step and sit 30° above and below the middle '
          'ring. You do not finish one ring before moving to the next. Every '
          'photo keeps the previous one in view — measured overlap '
          'is at least $_overlapPercent%.',
    ),
  ];

  Widget _notice(String text) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: SiteWiseColors.softBlue,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.info_outline, color: SiteWiseColors.primary),
        const SizedBox(width: 10),
        Expanded(child: _body(text)),
      ],
    ),
  );

  List<Widget> _guidance() => [
    _heading('Capture guidance'),
    _body('Use your normal smartphone. Follow the live camera guide.'),
    const SizedBox(height: 20),
    _tip(
      Icons.rotate_right,
      'Turn around one spot',
      'Turn slowly and keep the camera close to the same position.',
    ),
    _tip(
      Icons.height,
      'Keep a similar height',
      'Avoid large changes in phone height between targets.',
    ),
    _tip(
      Icons.center_focus_strong,
      'Follow the on-screen targets',
      'Move the numbered marker into the centre aiming ring.',
    ),
    _tip(
      Icons.stay_current_portrait,
      'Keep the phone steady',
      'Wait for the capture guide to turn green and save the photo.',
    ),
  ];

  Widget _tip(IconData icon, String title, String subtitle) => Container(
    margin: const EdgeInsets.only(bottom: 12),
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      border: Border.all(color: SiteWiseColors.border),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: SiteWiseColors.primary, size: 28),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  color: SiteWiseColors.ink,
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              _body(subtitle),
            ],
          ),
        ),
      ],
    ),
  );

  List<Widget> _overview() => [
    _heading('$_count photo directions'),
    _body(
      'The guide works in arches rather than whole rings: from each '
          'middle-ring direction it climbs to the upper ring and the ceiling, '
          'or drops to the lower ring and the floor, and comes back to the next '
          'middle direction. Each step moves to a neighbouring direction (up to '
          '30° horizontally or 35° vertically), so the frame you just captured '
          'still overlaps the next one and the rings are linked from the start.',
    ),
    const SizedBox(height: 16),
    _sphere(height: 260),
    const SizedBox(height: 16),
    _legend(
      const Color(0xFF7C3AED),
      'Upper polar ring',
      _ringCount('upper_polar'),
    ),
    _legend(const Color(0xFF2563EB), 'Upper ring', _ringCount('upper')),
    _legend(const Color(0xFF15803D), 'Middle ring', _ringCount('middle')),
    _legend(const Color(0xFFC2410C), 'Lower ring', _ringCount('lower')),
    _legend(
      const Color(0xFF7C3AED),
      'Lower polar ring',
      _ringCount('lower_polar'),
    ),
    const SizedBox(height: 14),
    _notice(
      '$_count total directions · $_spacing° horizontal spacing · '
          '30° main-ring spacing. The app takes photographs using the existing '
          'capture engine.',
    ),
  ];

  Widget _legend(Color color, String name, int count) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 7),
    child: Row(
      children: [
        Icon(Icons.circle, color: color, size: 14),
        const SizedBox(width: 12),
        Expanded(child: _body(name)),
        Text(
          '$count ${count == 1 ? 'target' : 'targets'}',
          style: const TextStyle(
            color: SiteWiseColors.ink,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    ),
  );
}

class _PlanSpherePainter extends CustomPainter {
  const _PlanSpherePainter(this._plan);

  final AdaptiveSpherePlan _plan;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = math.max(0.0, math.min(size.width, size.height) / 2 - 12);
    final line = Paint()
      ..color = SiteWiseColors.borderStrong
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    canvas.drawCircle(center, radius, line);
    // Slightly tilted orthographic projection, so back and front points separate.
    Offset point(double yaw, double pitch) {
      final v = sphereDirection(yaw + 9, pitch);
      return center + Offset(v.x, -(v.y * .97 + v.z * .24)) * radius;
    }

    void trace(Iterable<Offset> points) {
      final path = Path();
      var first = true;
      for (final p in points) {
        if (first) {
          path.moveTo(p.dx, p.dy);
          first = false;
        } else {
          path.lineTo(p.dx, p.dy);
        }
      }
      canvas.drawPath(path, line);
    }

    // One latitude circle per ring, at the ring's own pitch. Drawing the
    // retired three-ring layout (0/±40) here would show a sphere the user is
    // not about to capture.
    for (final ring in _plan.rings) {
      trace(List.generate(73, (i) => point(i * 5.0, ring.pitchDeg)));
    }
    for (var yaw = 0; yaw < 360; yaw += 45) {
      trace(List.generate(37, (i) => point(yaw.toDouble(), -90 + i * 5.0)));
    }
    // Dots take their colour from the ring they belong to, so the legend and
    // the drawing cannot disagree.
    Color ringColour(String key) {
      switch (key) {
        case 'upper_polar':
        case 'lower_polar':
        case 'ceiling':
        case 'floor':
          return const Color(0xFF7C3AED);
        case 'upper':
          return const Color(0xFF2563EB);
        case 'lower':
          return const Color(0xFFC2410C);
        default:
          return const Color(0xFF15803D);
      }
    }

    void dot(double yaw, double pitch, Color color) {
      final p = point(yaw, pitch);
      canvas.drawCircle(p, 4.8, Paint()..color = Colors.white);
      canvas.drawCircle(p, 3.8, Paint()..color = color);
    }

    for (final target in _plan.targets) {
      // The legend colours and the dots must agree, so both go through the
      // ring key rather than the display name.
      dot(
        target.yawDeg,
        target.pitchDeg,
        ringColour(AdaptiveSpherePlan.ringKeyOf(target.ringName)),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _PlanSpherePainter oldDelegate) =>
      oldDelegate._plan != _plan;
}
