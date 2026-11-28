import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:sensors_plus/sensors_plus.dart';

import 'package:fyp/features/capture_360/application/sphere/sphere_capture_controller.dart';
import 'package:fyp/features/capture_360/data/sphere/jpeg_normalizer.dart';
import 'package:fyp/features/capture_360/data/sphere/platform/rotation_sensor.dart';
import 'package:fyp/features/capture_360/data/sphere/platform/sphere_camera.dart';
import 'package:fyp/features/capture_360/domain/repositories/capture_repository.dart';
import 'package:fyp/features/capture_360/domain/sphere/sphere_capture_session.dart';
import 'package:fyp/features/capture_360/domain/sphere/sphere_projection.dart';
import 'package:fyp/features/capture_360/domain/sphere/sphere_target.dart';
import 'package:fyp/features/capture_360/domain/virtual_tour/math/vectors.dart';
import 'package:fyp/features/capture_360/guide/presentation/screens/capture_guide_screen.dart';
import 'package:fyp/features/capture_360/presentation/sphere/widgets/sphere_overlay_painter.dart';
import 'package:fyp/features/capture_360/presentation/sphere/widgets/sphere_progress_map.dart';
import 'package:fyp/features/capture_360/presentation/sphere/widgets/sphere_ring_palette.dart';
import 'package:fyp/features/capture_360/presentation/widgets/capture_theme.dart';

/// SiteWise 360° Capture — the reference sphere-follows-phone flow, running
/// the canonical adaptive five-ring capture plan.
///
/// Start screen → live camera with the plan's projected targets → automatic
/// shutter inside the alignment cone → completion hand-off to the host, which
/// uploads the photographs and drives the backend panorama job.
///
/// The sphere's centre is the phone at all times: there is no AR session, no
/// plane detection and no world anchor, so walking cannot leave a target
/// behind and there is no position estimate to drift.
///
/// This screen is the reference implementation's capture surface adapted to
/// SiteWise: the target geometry comes from the session's capture plan, the
/// photographs are handed to the host's upload queue the moment they are
/// durable, and everything after the last photograph (backend panorama job,
/// candidate review) belongs to [ArCaptureMobilePage]. No stitching, no
/// gallery export and no per-frame analysis runs on this screen.
class SphereCaptureScreen extends StatefulWidget {
  const SphereCaptureScreen({
    super.key,
    this.autoStart = false,
    this.planVersion = kSphereCapturePlanVersion,
    this.camera,
    this.rotation,
    required this.repository,
    this.sessions,
    required this.sessionId,
    this.userId,
    this.propertyId,
    this.motionStream,
    this.gyroscopeStream,
    required this.onFrameSaved,
    required this.onCaptureComplete,
    this.onStartNewCapture,
  });

  /// Start the capture as soon as the first frame renders. The host sets this
  /// after the guide screen so the photographer never taps Start twice.
  final bool autoStart;

  /// The capture plan this session runs under. New sessions pass the
  /// canonical adaptive five-ring plan; a resumed session passes the version
  /// it was captured with, so its photographs are never reinterpreted.
  final int planVersion;

  /// Overridable for tests. Production uses the hardened [PluginSphereCamera].
  final SphereCamera? camera;

  /// Overridable for tests. Production uses [NativeRotationSource].
  final RotationSource? rotation;

  /// The frame/record repository. The host always supplies the SiteWise
  /// repository bound to the tour and frame store.
  final CaptureRepository repository;

  /// The local-first session store. The host supplies the SiteWise store.
  final CaptureSessionStore? sessions;

  /// The station directory and session id. Also the station id the repository
  /// and the upload queue key their files by.
  final String sessionId;

  final String? userId;
  final int? propertyId;

  /// Overridable accelerometer/gyroscope streams for tests. The accelerometer
  /// pauses the shutter while the viewpoint is moving; the gyroscope feeds the
  /// angular freeze gate.
  final Stream<Vec3>? motionStream;
  final Stream<Vec3>? gyroscopeStream;

  /// Fired after each photograph is safely on disk. The host enqueues the
  /// upload; this callback returns immediately.
  final void Function(CapturedFrame frame) onFrameSaved;

  /// Fired once when every planned photograph is on disk. The host owns the
  /// backend handoff from here.
  final VoidCallback onCaptureComplete;

  /// Explicit recovery for an unreadable session: the host archives the old
  /// station (keeping every photograph) and rebuilds this screen fresh.
  final VoidCallback? onStartNewCapture;

  @override
  State<SphereCaptureScreen> createState() => _SphereCaptureScreenState();
}

class _SphereCaptureScreenState extends State<SphereCaptureScreen>
    with WidgetsBindingObserver {
  SphereCaptureController? _controller;
  SphereCamera? _camera;
  bool _starting = false;
  String? _startError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.autoStart) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _start();
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Android revokes the camera when the app goes to the background. Without
    // forwarding this, the preview is black on return with no message.
    final controller = _controller;
    if (controller == null) return;
    controller.handleAppLifecycle(state).whenComplete(() {
      // A reopen creates a *new* CameraController, so the preview's
      // ValueListenableBuilder must be rebuilt against it; the old one is
      // disposed and would otherwise keep rendering its final frame.
      if (mounted) setState(() {});
    });
  }

  Future<void> _start() async {
    if (_starting || _controller != null) return;
    setState(() {
      _starting = true;
      _startError = null;
    });
    try {
      final camera = widget.camera ?? PluginSphereCamera();
      final rotation = widget.rotation ?? NativeRotationSource();
      final repository = widget.repository;
      final controller = SphereCaptureController(
        rotation: rotation,
        camera: camera,
        repository: repository,
        stationId: widget.sessionId,
        planVersion: widget.planVersion,
        // The normaliser measures the JPEG's real geometry and keeps the
        // sensor's bytes: nothing in the capture loop decodes a
        // full-resolution still, and no native library is involved.
        normalize: const JpegNormalizer().normalize,
        sessions: widget.sessions,
        userId: widget.userId,
        propertyId: widget.propertyId,
        onFrameSaved: widget.onFrameSaved,
        onCaptureComplete: widget.onCaptureComplete,
        motion:
            widget.motionStream ??
            accelerometerEventStream(
              samplingPeriod: SensorInterval.normalInterval,
            ).map((AccelerometerEvent e) => Vec3(e.x, e.y, e.z)),
        // Angular rate, for the freeze gate. Not the accelerometer: walking
        // through a room is smooth in |a| but a turn is what rolls a shutter.
        angularVelocity:
            widget.gyroscopeStream ??
            gyroscopeEventStream(
              samplingPeriod: SensorInterval.gameInterval,
            ).map((GyroscopeEvent e) => Vec3(e.x, e.y, e.z)),
      );
      if (!mounted) return;
      setState(() {
        _controller = controller;
        _camera = camera;
        _starting = false;
      });
      await controller.start();
      // The first build after the setState above happens before the camera
      // controller exists, so `preview()` has nothing to listen to yet. One
      // rebuild after start attaches the live texture; without it the preview
      // stays on the black placeholder for the whole session.
      if (mounted) setState(() {});
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _starting = false;
        _startError = 'The capture could not start: $error';
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final camera = _camera;
    if (controller == null || camera == null) {
      // A guide-started capture must not show a second Start button.
      // On genuine camera errors, retain the existing retry UI.
      if (widget.autoStart && _startError == null) {
        return const Scaffold(
          backgroundColor: CaptureColors.cameraChrome,
          body: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(color: CaptureColors.accentOnDark),
                SizedBox(height: 18),
                Text('Opening 360° camera…',
                    style: TextStyle(color: Colors.white, fontSize: 16)),
              ],
            ),
          ),
        );
      }
      return _StartScreen(
        onStart: _starting ? null : _start,
        starting: _starting,
        error: _startError,
        planVersion: widget.planVersion,
      );
    }
    return _LiveCapture(
      controller: controller,
      camera: camera,
      onStartNewCapture: widget.onStartNewCapture,
    );
  }
}

// ── start screen ───────────────────────────────────────────────────────────

class _StartScreen extends StatelessWidget {
  const _StartScreen({
    required this.onStart,
    required this.starting,
    this.error,
    required this.planVersion,
  });

  final VoidCallback? onStart;
  final bool starting;
  final String? error;
  final int planVersion;

  @override
  Widget build(BuildContext context) {
    final targetCount = sphereTargetCountForPlan(planVersion);
    return Scaffold(
      backgroundColor: CaptureColors.cameraChrome,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.threesixty,
                    color: CaptureColors.accentOnDark,
                    size: 26,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'SiteWise',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.92),
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.2,
                    ),
                  ),
                  const SizedBox(width: 6),
                  const Text(
                    '360° Capture',
                    style: TextStyle(
                      color: CaptureColors.mutedOnDark,
                      fontSize: 15,
                    ),
                  ),
                ],
              ),
              const Spacer(flex: 2),
              Center(
                child: _SphereDiagram(size: 220, planVersion: planVersion),
              ),
              const SizedBox(height: 30),
              Text(
                '360° Capture ($targetCount Targets)',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 25,
                  fontWeight: FontWeight.w700,
                  height: 1.25,
                ),
              ),
              const SizedBox(height: 10),
              const Text(
                'Hold the phone level and face the first wall, then tap Start. '
                'The targets follow an adaptive five-ring plan — turn to bring '
                'the next one into the centre ring and the photograph is taken '
                'automatically.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: CaptureColors.mutedOnDark,
                  fontSize: 13,
                  height: 1.5,
                ),
              ),
              const Spacer(flex: 3),
              if (error != null) ...[
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: CaptureColors.danger.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: CaptureColors.danger.withValues(alpha: 0.5),
                    ),
                  ),
                  child: Text(
                    error!,
                    style: const TextStyle(
                      color: CaptureColors.danger,
                      fontSize: 12,
                      height: 1.4,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
              ],
              FilledButton(
                onPressed: onStart,
                style: FilledButton.styleFrom(
                  backgroundColor: CaptureColors.accent,
                  foregroundColor: Colors.white,
                  minimumSize: const Size.fromHeight(52),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                child: starting
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor:
                              AlwaysStoppedAnimation<Color>(Colors.white),
                        ),
                      )
                    : const Text(
                        'Start Capture',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
              ),
              const SizedBox(height: 12),
              const Text(
                '3DoF rotation only · levelled to gravity at Start · the sphere '
                'stays locked to the room',
                textAlign: TextAlign.center,
                style: TextStyle(color: CaptureColors.mutedOnDark, fontSize: 11),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The plan's targets, drawn orthographically so the layout is visible before
/// Start.
class _SphereDiagram extends StatelessWidget {
  const _SphereDiagram({required this.size, required this.planVersion});

  final double size;
  final int planVersion;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: size,
    height: size,
    child: CustomPaint(
      painter: _SphereDiagramPainter(
        targets: buildSphereTargets(planVersion: planVersion),
      ),
    ),
  );
}

class _SphereDiagramPainter extends CustomPainter {
  const _SphereDiagramPainter({required this.targets});

  final List<SphereTargetSpec> targets;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) / 2 - 8;
    final outline = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.1
      ..color = Colors.white.withValues(alpha: 0.28);
    canvas.drawCircle(center, radius, outline);

    // The rings, foreshortened the way a sphere reads in a still image.
    final ringPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.9
      ..color = Colors.white.withValues(alpha: 0.16);
    final ringHeight = radius * 0.30;
    canvas.drawOval(
      Rect.fromCenter(
        center: center,
        width: radius * 2,
        height: ringHeight * 2,
      ),
      ringPaint,
    );
    final pitches = <double>{
      for (final target in targets) target.pitchDeg,
    }.toList()..sort();
    for (final pitch in pitches) {
      final y = -math.sin(pitch * math.pi / 180) * radius;
      final rx = math.cos(pitch * math.pi / 180) * radius;
      canvas.drawOval(
        Rect.fromCenter(
          center: center + Offset(0, y),
          width: rx * 2,
          height: ringHeight * 2 * math.cos(pitch * math.pi / 180),
        ),
        ringPaint,
      );
    }

    for (final target in targets) {
      final d = target.direction;
      final point = center + Offset(d.x * radius, -d.y * radius);
      final front = d.z <= 0;
      final isPolar = target.pitchDeg.abs() > 45;
      canvas.drawCircle(
        point,
        isPolar ? 4.2 : 3.2,
        Paint()
          ..color =
              sphereRingColor(target).withValues(alpha: front ? 1 : 0.35),
      );
    }

    // The reference diagram's phone at the centre: the sphere's origin is the
    // device, not a tripod, and drawing it is the clearest way to say so.
    final phoneWidth = radius * 0.18;
    final phoneHeight = radius * 0.34;
    final phone = RRect.fromRectAndRadius(
      Rect.fromCenter(center: center, width: phoneWidth, height: phoneHeight),
      Radius.circular(radius * 0.03),
    );
    canvas.drawRRect(phone, Paint()..color = CaptureColors.cameraChrome);
    canvas.drawRRect(
      phone,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8
        ..color = Colors.white.withValues(alpha: 0.9),
    );
    final screen = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: center,
        width: phoneWidth * 0.76,
        height: phoneHeight * 0.82,
      ),
      Radius.circular(radius * 0.012),
    );
    canvas.drawRRect(screen, Paint()..color = const Color(0xFF2A3640));
  }

  @override
  bool shouldRepaint(_SphereDiagramPainter oldDelegate) =>
      oldDelegate.targets.length != targets.length;
}

// ── live capture ───────────────────────────────────────────────────────────

class _LiveCapture extends StatelessWidget {
  const _LiveCapture({
    required this.controller,
    required this.camera,
    this.onStartNewCapture,
  });

  final SphereCaptureController controller;
  final SphereCamera camera;
  final VoidCallback? onStartNewCapture;

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    body: Stack(
      fit: StackFit.expand,
      children: [
        // Toolbar and capture controls sit OUTSIDE the viewfinder; the camera
        // image lives in an explicit 3:4 box whose size drives the marker
        // projection. A fullscreen cover-cropped preview and a fullscreen
        // projection only stay consistent by accident — and the photographs
        // are 3:4, so the viewfinder shows exactly what will be saved.
        SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: _TopBar(controller: controller),
              ),
              Expanded(
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    child: AspectRatio(
                      aspectRatio: 3 / 4,
                      child: _Viewfinder(
                        controller: controller,
                        camera: camera,
                      ),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: AnimatedBuilder(
                  animation: controller,
                  builder: (BuildContext context, Widget? child) =>
                      _BottomPanel(controller: controller),
                ),
              ),
            ],
          ),
        ),
        AnimatedBuilder(
          animation: controller,
          builder: (BuildContext context, Widget? child) {
            if (controller.phase == SphereCapturePhase.complete) {
              return _CompletionOverlay(controller: controller);
            }
            if (controller.phase == SphereCapturePhase.failed) {
              return _FailureOverlay(
                controller: controller,
                onStartNewCapture: onStartNewCapture,
              );
            }
            return const SizedBox.shrink();
          },
        ),
      ],
    ),
  );
}

/// Whether the verbose projection diagnostics are compiled in. Off unless the
/// run asks for it: `--dart-define=sphere_diagnostics=true`.
const bool kSphereDiagnostics = bool.fromEnvironment('sphere_diagnostics');

/// The portrait 3:4 viewfinder: the camera image, the marker overlay and the
/// reticle, all in one coordinate system.
///
/// The preview is a 3:4 sensor frame (the same aspect the JPEG is saved at),
/// so at exactly 3:4 it fills the box without cropping or stretching — which
/// is what lets [SphereProjection]'s pinhole model describe the visible image
/// exactly, and the reticle at the box centre is the optical axis.
class _Viewfinder extends StatelessWidget {
  const _Viewfinder({required this.controller, required this.camera});

  final SphereCaptureController controller;
  final SphereCamera camera;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(12),
    child: ColoredBox(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          camera.preview(),
          LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              // The preview is cover-fitted into this 3:4 box, so the vertical
              // FOV actually visible is the camera's, narrowed by the crop
              // whenever the preview frame is taller than 3:4. Projecting the
              // full camera FOV onto a cropped viewfinder would push every
              // off-axis marker too far from the reticle — which reads as
              // "the middle ring is too high" as soon as the phone tilts.
              final viewfinderAspect =
                  constraints.maxWidth / constraints.maxHeight;
              final visibleFov = visibleVerticalFovDeg(
                cameraVerticalFovDeg: kSphereAssumedVerticalFovDeg,
                frameAspect: camera.previewAspectRatio ?? 0.75,
                viewfinderAspect: viewfinderAspect,
              );
              final projection = SphereProjection(
                width: constraints.maxWidth,
                height: constraints.maxHeight,
                verticalFovDeg: visibleFov,
              );
              return Stack(
                fit: StackFit.expand,
                children: [
                  RepaintBoundary(
                    child: CustomPaint(
                      painter: SphereOverlayPainter(
                        controller: controller,
                        projection: projection,
                      ),
                    ),
                  ),
                  if (kSphereDiagnostics)
                    Align(
                      alignment: Alignment.bottomLeft,
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: _ProjectionDiagnostics(
                          controller: controller,
                          camera: camera,
                          projection: projection,
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
          Positioned(
            top: 10,
            left: 16,
            right: 16,
            child: Center(
              child: AnimatedBuilder(
                animation: controller,
                builder: (BuildContext context, Widget? child) =>
                    _CapturedBanner(visible: controller.banner != null),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

/// The verbose projection diagnostics panel (only compiled in behind
/// `--dart-define=sphere_diagnostics=true`).
///
/// Logs the numbers needed to answer "is the middle ring where gravity says
/// it is" from a device log. Throttled to once a second: the sensor itself
/// runs at 50 Hz and a per-sample log would drown the device console.
class _ProjectionDiagnostics extends StatefulWidget {
  const _ProjectionDiagnostics({
    required this.controller,
    required this.camera,
    required this.projection,
  });

  final SphereCaptureController controller;
  final SphereCamera camera;
  final SphereProjection projection;

  @override
  State<_ProjectionDiagnostics> createState() => _ProjectionDiagnosticsState();
}

class _ProjectionDiagnosticsState extends State<_ProjectionDiagnostics> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _log());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _log() {
    final c = widget.controller;
    final p = widget.projection;
    final device = c.deviceToWorld;
    final start = c.startDeviceToWorld;
    final target = c.activeTarget;
    double? elevationDeg;
    double? referenceHeadingDeg;
    Offset? projected;
    if (device != null && start != null) {
      // The camera's elevation in the *levelled sphere frame* (+Y up): the
      // same frame the middle ring's 0° pitch is defined in.
      final relative = (start.conjugate * device).normalized;
      final forward = relative.rotate(const Vec3(0, 0, -1));
      elevationDeg =
          math.asin(forward.y.clamp(-1.0, 1.0)) * 180 / math.pi;
      final reference = start.rotate(const Vec3(0, 0, -1));
      referenceHeadingDeg =
          math.atan2(reference.x, -reference.z) * 180 / math.pi;
      if (target != null) {
        projected = p.project(
          sphereTargetCameraDirection(
            deviceToWorld: device,
            startDeviceToWorld: start,
            startDirection: target.spec.direction,
          ),
        );
      }
    }
    debugPrint(
      'SPHERE_VIEW: viewfinder=${p.width.round()}x${p.height.round()} '
      'aspect=${(p.width / p.height).toStringAsFixed(3)} '
      'previewAspect=${widget.camera.previewAspectRatio?.toStringAsFixed(3) ?? 'n/a'} '
      'vfov=${p.verticalFovDeg.toStringAsFixed(1)}° '
      'cameraElevation=${elevationDeg?.toStringAsFixed(1) ?? 'n/a'}° '
      'referenceHeading=${referenceHeadingDeg?.toStringAsFixed(1) ?? 'n/a'}° '
      'target=${target?.spec.targetId ?? '-'} '
      'yaw=${target?.spec.yawDeg.toStringAsFixed(0) ?? '-'}° '
      'pitch=${target?.spec.pitchDeg.toStringAsFixed(0) ?? '-'}° '
      'projected=${projected == null ? 'off-screen' : '(${projected.dx.toStringAsFixed(0)},${projected.dy.toStringAsFixed(0)})'} '
      'reticle=(${(p.width / 2).round()},${(p.height / 2).round()}) '
      'error=${c.activeErrorDeg.toStringAsFixed(1)}°',
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final target = c.activeTarget;
    final device = c.deviceToWorld;
    final start = c.startDeviceToWorld;
    var elevation = 'n/a';
    if (device != null && start != null) {
      final relative = (start.conjugate * device).normalized;
      final forward = relative.rotate(const Vec3(0, 0, -1));
      elevation =
          '${(math.asin(forward.y.clamp(-1.0, 1.0)) * 180 / math.pi).toStringAsFixed(1)}°';
    }
    return IgnorePointer(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.65),
          borderRadius: BorderRadius.circular(8),
        ),
        child: DefaultTextStyle(
          style: const TextStyle(
            color: Colors.white70,
            fontSize: 9.5,
            height: 1.3,
            fontFamily: 'monospace',
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'vf ${widget.projection.width.round()}×'
                '${widget.projection.height.round()} '
                'f${widget.projection.focalLengthY.round()}',
              ),
              Text('elev $elevation  err ${c.activeErrorDeg.toStringAsFixed(1)}°'),
              Text(
                'T${target?.spec.targetId ?? '-'} '
                'y${target?.spec.yawDeg.toStringAsFixed(0) ?? '-'} '
                'p${target?.spec.pitchDeg.toStringAsFixed(0) ?? '-'}',
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.controller});

  final SphereCaptureController controller;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      _GlassButton(
        icon: Icons.close,
        onTap: () => Navigator.of(context).maybePop(),
      ),
      const SizedBox(width: 8),
      AnimatedBuilder(
        animation: controller,
        builder: (BuildContext context, Widget? child) =>
            _MotionChip(moving: controller.moving),
      ),
      const SizedBox(width: 8),
      // In-session help: opens the capture guide on top of the live session.
      // The controller below stays mounted and keeps its state, so reopening
      // the instructions never restarts or resets the capture.
      _GlassButton(
        icon: Icons.help_outline,
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const CaptureGuideScreen()),
        ),
      ),
      const Spacer(),
      SphereProgressMap(controller: controller),
    ],
  );
}

class _GlassButton extends StatelessWidget {
  const _GlassButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.black.withValues(alpha: 0.45),
    shape: const CircleBorder(),
    child: InkWell(
      customBorder: const CircleBorder(),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(9),
        child: Icon(icon, color: Colors.white, size: 20),
      ),
    ),
  );
}

class _CapturedBanner extends StatelessWidget {
  const _CapturedBanner({required this.visible});

  final bool visible;

  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
    duration: const Duration(milliseconds: 180),
    child: visible
        ? Container(
            key: const ValueKey<String>('captured'),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            decoration: BoxDecoration(
              color: CaptureColors.ok.withValues(alpha: 0.94),
              borderRadius: BorderRadius.circular(24),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x55000000),
                  blurRadius: 12,
                  offset: Offset(0, 4),
                ),
              ],
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.check, color: Colors.white, size: 16),
                SizedBox(width: 6),
                Text(
                  'Captured!',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          )
        : const SizedBox.shrink(),
  );
}

class _BottomPanel extends StatelessWidget {
  const _BottomPanel({required this.controller});

  final SphereCaptureController controller;

  @override
  Widget build(BuildContext context) {
    final aligned = controller.activeErrorDeg <= controller.toleranceDeg;
    final total = controller.targetCount;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.68),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: CaptureColors.hairlineOnDark),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            controller.guidance,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: aligned ? CaptureColors.ok : Colors.white,
              fontSize: 12.5,
              height: 1.35,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 9),
          Text(
            controller.progressLabel,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: total == 0 ? 0 : controller.capturedCount / total,
              minHeight: 4,
              backgroundColor: Colors.white.withValues(alpha: 0.14),
              valueColor: const AlwaysStoppedAnimation<Color>(CaptureColors.ok),
            ),
          ),
        ],
      ),
    );
  }
}

class _MotionChip extends StatelessWidget {
  const _MotionChip({required this.moving});

  final bool moving;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: CaptureColors.hairlineFaint),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          moving ? Icons.directions_walk : Icons.my_location,
          color: CaptureColors.linkOnDark,
          size: 14,
        ),
        const SizedBox(width: 5),
        Text(
          moving ? 'Moving' : 'Sphere synced',
          style: const TextStyle(
            color: CaptureColors.linkOnDark,
            fontSize: 10.5,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    ),
  );
}

/// Shown the moment the last photograph is durable. The host replaces this
/// screen with the handoff/processing progression as soon as it reacts to
/// [SphereCaptureController.onCaptureComplete]; this overlay exists so the
/// final save never visually falls off a cliff.
class _CompletionOverlay extends StatelessWidget {
  const _CompletionOverlay({required this.controller});

  final SphereCaptureController controller;

  @override
  Widget build(BuildContext context) => Container(
    color: Colors.black.withValues(alpha: 0.72),
    child: Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Container(
          padding: const EdgeInsets.fromLTRB(22, 24, 22, 18),
          decoration: BoxDecoration(
            color: CaptureColors.sheet,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: CaptureColors.hairlineOnDark),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.check_circle, color: CaptureColors.ok, size: 54),
              const SizedBox(height: 12),
              const Text(
                'Capture Complete!',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '${controller.capturedCount} / ${controller.targetCount} Targets',
                style: const TextStyle(
                  color: CaptureColors.mutedOnDark,
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 16),
              const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 10),
                  Flexible(
                    child: Text(
                      'Uploading your photographs and preparing the panorama…',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: CaptureColors.mutedOnDark,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// The camera could not start. Offers the two recoveries that actually exist:
/// try again (transient camera or sensor failures), or — when the host
/// supplies it — archive the station and start fresh (an unreadable session).
class _FailureOverlay extends StatelessWidget {
  const _FailureOverlay({
    required this.controller,
    this.onStartNewCapture,
  });

  final SphereCaptureController controller;
  final VoidCallback? onStartNewCapture;

  @override
  Widget build(BuildContext context) => Container(
    color: Colors.black.withValues(alpha: 0.78),
    child: Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Container(
          padding: const EdgeInsets.fromLTRB(22, 24, 22, 18),
          decoration: BoxDecoration(
            color: CaptureColors.sheet,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: CaptureColors.hairlineOnDark),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(
                Icons.error_outline,
                color: CaptureColors.danger,
                size: 48,
              ),
              const SizedBox(height: 12),
              const Text(
                'The capture could not start',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                controller.message ?? 'An unknown camera error occurred.',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: CaptureColors.mutedOnDark,
                  fontSize: 12,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 18),
              FilledButton.icon(
                onPressed: () => controller.start(),
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Try Again'),
                style: FilledButton.styleFrom(
                  backgroundColor: CaptureColors.accent,
                  foregroundColor: Colors.white,
                  minimumSize: const Size.fromHeight(46),
                ),
              ),
              if (onStartNewCapture != null) ...[
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: onStartNewCapture,
                  icon: const Icon(Icons.restart_alt, size: 18),
                  label: const Text('Start a New Capture'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    minimumSize: const Size.fromHeight(46),
                    side: const BorderSide(color: CaptureColors.hairlineOnDark),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}
