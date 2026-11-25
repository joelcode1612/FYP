import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:fyp/features/capture_360/domain/sphere/sphere_target.dart';
import 'package:fyp/features/capture_360/presentation/widgets/capture_theme.dart';

/// Presentation-only guide. The enhanced plan is a preview, not a capture
/// capability: the current mobile controller still owns the standard plan.
class CapturePlanGuide extends StatefulWidget {
  const CapturePlanGuide({super.key, required this.onStart});
  final VoidCallback onStart;

  @override
  State<CapturePlanGuide> createState() => _CapturePlanGuideState();
}

class _CapturePlanGuideState extends State<CapturePlanGuide> {
  int _step = 0;
  bool _enhancedPreview = false;

  int get _count => _enhancedPreview ? 56 : buildSphereTargets().length;
  int get _perRing => (_count - 2) ~/ 3;
  String get _spacing => (360 / _perRing).toStringAsFixed(0);

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
    } else if (_enhancedPreview) {
      setState(() => _enhancedPreview = false);
    } else {
      widget.onStart();
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
        title: Text(const ['SiteWise', 'Before you start', 'Capture plan'][_step]),
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
                icon: Icon(_step == 2 && !_enhancedPreview
                    ? Icons.camera_alt_outlined : Icons.arrow_forward),
                label: Text(_step < 2 ? 'Continue' : _enhancedPreview
                    ? 'Switch to standard plan' : 'Start capture',
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _heading(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Text(text, style: const TextStyle(color: SiteWiseColors.ink,
        fontSize: 25, fontWeight: FontWeight.w700)),
  );

  Widget _body(String text) => Text(text, style: const TextStyle(
    color: SiteWiseColors.muted, fontSize: 16, height: 1.45,
  ));

  Widget _sphere({double height = 220}) => Container(
    height: height,
    decoration: BoxDecoration(color: SiteWiseColors.softBlue,
      borderRadius: BorderRadius.circular(16)),
    padding: const EdgeInsets.all(12),
    child: Semantics(
      label: '$_count planned photo directions${_enhancedPreview ? ', preview only' : ''}',
      child: CustomPaint(painter: _PlanSpherePainter(enhanced: _enhancedPreview)),
    ),
  );

  List<Widget> _intro() => [
    _sphere(height: 190),
    const SizedBox(height: 22),
    _heading('Capture 360° panorama'),
    _body('Take guided photographs to create a full view of this space.'),
    const SizedBox(height: 24),
    _heading('Capture plan'),
    _option(false, '38 targets (Standard)', '12 per ring · 30° spacing'),
    const SizedBox(height: 10),
    _option(true, '56 targets (Preview only)', '18 per ring · 20° spacing'),
    const SizedBox(height: 14),
    _notice(_enhancedPreview
      ? 'The enhanced layout is a preview. Live capture is not enabled until the mobile capture and processing pipeline supports it.'
      : 'The standard plan uses the existing working capture and panorama generation.'),
  ];

  Widget _option(bool enhanced, String title, String subtitle) {
    final selected = _enhancedPreview == enhanced;
    return Semantics(selected: selected, button: true,
      child: Material(
        color: selected ? SiteWiseColors.softBlue : SiteWiseColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: selected ? SiteWiseColors.primary : SiteWiseColors.border)),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => setState(() => _enhancedPreview = enhanced),
          child: Padding(padding: const EdgeInsets.all(16), child: Row(children: [
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700,
                color: SiteWiseColors.ink)),
              const SizedBox(height: 5), _body(subtitle),
            ])),
            const SizedBox(width: 12),
            Icon(selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
              color: selected ? SiteWiseColors.primary : SiteWiseColors.muted),
          ])),
        ),
      ),
    );
  }

  Widget _notice(String text) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(color: SiteWiseColors.softBlue,
      borderRadius: BorderRadius.circular(12)),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Icon(Icons.info_outline, color: SiteWiseColors.primary),
      const SizedBox(width: 10), Expanded(child: _body(text)),
    ]),
  );

  List<Widget> _guidance() => [
    _heading('Capture guidance'),
    _body('Use your normal smartphone. Follow the live camera guide.'),
    const SizedBox(height: 20),
    _tip(Icons.rotate_right, 'Turn around one spot', 'Turn slowly and keep the camera close to the same position.'),
    _tip(Icons.height, 'Keep a similar height', 'Avoid large changes in phone height between targets.'),
    _tip(Icons.center_focus_strong, 'Follow the on-screen targets', 'Move the numbered marker into the centre aiming ring.'),
    _tip(Icons.stay_current_portrait, 'Keep the phone steady', 'Wait for the capture guide to turn green and save the photo.'),
  ];

  Widget _tip(IconData icon, String title, String subtitle) => Container(
    margin: const EdgeInsets.only(bottom: 12), padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(border: Border.all(color: SiteWiseColors.border),
      borderRadius: BorderRadius.circular(12)),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(icon, color: SiteWiseColors.primary, size: 28), const SizedBox(width: 12),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: const TextStyle(color: SiteWiseColors.ink, fontSize: 17,
          fontWeight: FontWeight.w700)), const SizedBox(height: 4), _body(subtitle),
      ])),
    ]),
  );

  List<Widget> _overview() => [
    _heading('$_count photo directions'),
    _body(_enhancedPreview ? 'Experimental layout preview — not a live capture plan.'
      : 'Start with the middle ring and follow the live camera targets.'),
    const SizedBox(height: 16), _sphere(height: 260), const SizedBox(height: 16),
    _legend(const Color(0xFF2563EB), 'Upper ring', _perRing),
    _legend(const Color(0xFF15803D), 'Middle ring', _perRing),
    _legend(const Color(0xFFC2410C), 'Lower ring', _perRing),
    _legend(const Color(0xFF7C3AED), 'Ceiling', 1),
    _legend(const Color(0xFF7C3AED), 'Floor', 1),
    const SizedBox(height: 14),
    _notice('$_count total directions · $_spacing° horizontal spacing. '
      '${_enhancedPreview ? 'Switch to the standard plan to start a real capture.' : 'The app takes photographs using the existing capture engine.'}'),
  ];

  Widget _legend(Color color, String name, int count) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 7),
    child: Row(children: [Icon(Icons.circle, color: color, size: 14),
      const SizedBox(width: 12), Expanded(child: _body(name)),
      Text('$count ${count == 1 ? 'target' : 'targets'}', style: const TextStyle(
        color: SiteWiseColors.ink, fontSize: 16, fontWeight: FontWeight.w600)),
    ]),
  );
}

class _PlanSpherePainter extends CustomPainter {
  const _PlanSpherePainter({required this.enhanced});
  final bool enhanced;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = math.max(0.0, math.min(size.width, size.height) / 2 - 12);
    final line = Paint()..color = SiteWiseColors.borderStrong
      ..style = PaintingStyle.stroke..strokeWidth = 1.2;
    canvas.drawCircle(center, radius, line);
    // Slightly tilted orthographic projection, so back and front points separate.
    Offset point(double yaw, double pitch) {
      final v = sphereDirection(yaw + 9, pitch);
      return center + Offset(v.x, -(v.y * .97 + v.z * .24)) * radius;
    }
    void trace(Iterable<Offset> points) {
      final path = Path(); var first = true;
      for (final p in points) {
        if (first) { path.moveTo(p.dx, p.dy); first = false; }
        else { path.lineTo(p.dx, p.dy); }
      }
      canvas.drawPath(path, line);
    }
    for (final pitch in <double>[-kSphereRingPitchDeg, 0, kSphereRingPitchDeg]) {
      trace(List.generate(73, (i) => point(i * 5.0, pitch)));
    }
    for (var yaw = 0; yaw < 360; yaw += 45) {
      trace(List.generate(37, (i) => point(yaw.toDouble(), -90 + i * 5.0)));
    }
    void dot(double yaw, double pitch) {
      final color = pitch.abs() >= 89 ? const Color(0xFF7C3AED)
        : pitch > 0 ? const Color(0xFF2563EB)
        : pitch < 0 ? const Color(0xFFC2410C) : const Color(0xFF15803D);
      final p = point(yaw, pitch);
      canvas.drawCircle(p, 4.8, Paint()..color = Colors.white);
      canvas.drawCircle(p, 3.8, Paint()..color = color);
    }
    if (!enhanced) {
      for (final target in buildSphereTargets()) { dot(target.yawDeg, target.pitchDeg); }
    } else {
      // Illustrative geometry only; never used to create a capture session.
      for (final pitch in <double>[0, kSphereRingPitchDeg, -kSphereRingPitchDeg]) {
        for (var i = 0; i < 18; i++) { dot(i * 20.0, pitch); }
      }
      dot(0, 90); dot(0, -90);
    }
  }

  @override
  bool shouldRepaint(covariant _PlanSpherePainter oldDelegate) => oldDelegate.enhanced != enhanced;
}
