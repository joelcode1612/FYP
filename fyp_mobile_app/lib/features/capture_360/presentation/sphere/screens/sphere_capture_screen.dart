import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:sensors_plus/sensors_plus.dart';

import 'package:fyp/features/capture_360/domain/sphere/sphere_capture_session.dart';
import 'package:fyp/features/capture_360/domain/services/panorama_stitcher.dart';
import 'package:fyp/features/capture_360/application/sphere/sphere_platform_ports.dart';
import 'package:fyp/features/capture_360/application/sphere/sphere_capture_controller.dart';
import 'package:fyp/features/capture_360/domain/sphere/sphere_projection.dart';
import 'package:fyp/features/capture_360/domain/sphere/sphere_target.dart';
import 'package:fyp/features/capture_360/data/repositories/capture_repository_impl.dart';
import 'package:fyp/features/capture_360/capture_composition.dart';
import 'package:fyp/features/capture_360/presentation/sphere/screens/sphere_panorama_screen.dart';
import 'package:fyp/features/capture_360/presentation/sphere/widgets/sphere_overlay_painter.dart';
import 'package:fyp/features/capture_360/presentation/sphere/widgets/sphere_progress_map.dart';
import 'package:fyp/features/capture_360/presentation/sphere/widgets/sphere_ring_palette.dart';
import 'package:fyp/features/capture_360/domain/virtual_tour/math/vectors.dart';
import 'package:fyp/features/capture_360/presentation/widgets/capture_theme.dart';

/// SiteWise 360° Capture — the 38-target, sphere-follows-phone flow.
///
/// Start screen → live camera with 38 projected targets → automatic shutter
/// inside 5° → completion modal with the stitched 360° panorama.
///
/// The sphere's centre is the phone at all times: there is no AR session, no
/// plane detection and no world anchor, so walking cannot leave a target
/// behind and there is no position estimate to drift.
class SphereCaptureScreen extends StatefulWidget {
  const SphereCaptureScreen({
    super.key,
    this.autoStart = false,
    this.camera,
    this.rotation,
    this.repository,
    this.stitcher,
    this.motionStream,
    this.gyroscopeStream,
    this.sessions,
    this.sessionId,
    this.userId,
    this.propertyId,
    this.backendProcessing = false,
    this.onCaptureComplete,
    this.onPanoramaReady,
  });

  /// True only when entered after completing the SiteWise guide.
  /// The camera starts after the first frame, using the same _start() flow.
  final bool autoStart;

  /// Injection points for tests and for callers that already hold a station.
  final SphereCamera? camera;
  final RotationSource? rotation;
  final CaptureRepository? repository;
  final PanoramaStitcher? stitcher;
  final Stream<Vec3>? motionStream;

  /// Raw angular rate, rad/s. Injected in tests; defaults to `sensors_plus`.
  final Stream<Vec3>? gyroscopeStream;

  /// The local session store. SiteWise supplies the tour-scoped JSON store;
  /// `null` keeps the capture local-only with no resume metadata.
  final CaptureSessionStore? sessions;

  /// Resumes this exact session. When omitted, the newest unfinished session is
  /// resumed, and a new one is created only if there is none.
  final String? sessionId;

  /// The signed-in account, when the caller already has one.
  final String? userId;

  /// The capture specification's numeric property id, when the caller has one.
  /// SiteWise draft identifiers are strings and stay on the tour record, so the
  /// SiteWise host leaves this `null`.
  final int? propertyId;

  /// When true, completion sends saved frames to FastAPI without local stitching.
  final bool backendProcessing;

  /// Fired once when all 38 original photographs have been saved.
  final VoidCallback? onCaptureComplete;

  /// Fired once when the stitched panorama exists on disk, so the host page
  /// can attach it to the SiteWise tour, upload it through its own API and
  /// open the existing tour preview.
  final void Function(String panoramaPath)? onPanoramaReady;

  @override
  State<SphereCaptureScreen> createState() => _SphereCaptureScreenState();
}

class _SphereCaptureScreenState extends State<SphereCaptureScreen>
    with WidgetsBindingObserver {
  SphereCaptureController? _controller;
  SphereCamera? _camera;
  bool _starting = false;
  String? _startError;
  bool _panoramaNotified = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.autoStart) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_start());
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

  void _onControllerChanged() {
    if (_panoramaNotified) return;
    final controller = _controller;
    if (controller == null) return;
    if (widget.backendProcessing) {
      if (controller.phase != SphereCapturePhase.complete ||
          controller.capturedCount < kSphereTargetCount) {
        return;
      }
      _panoramaNotified = true;
      widget.onCaptureComplete?.call();
      return;
    }
    final path = controller.panoramaPath;
    if (controller.stitching || path == null) return;
    _panoramaNotified = true;
    widget.onPanoramaReady?.call(path);
  }

  Future<void> _start() async {
    if (_starting || _controller != null) return;
    setState(() {
      _starting = true;
      _startError = null;
    });
    try {
      final defaults = createSphereDefaults();
      final camera = widget.camera ?? defaults.camera;
      final rotation = widget.rotation ?? defaults.rotation;
      final repository =
          widget.repository ?? await FileCaptureRepository.create();
      final store = widget.sessions;
      // Resume before creating. A user who closed the app at target 31 must come
      // back to target 31, not to a fresh 38-target session that orphans the 30
      // photographs already on disk.
      String stationId;
      if (widget.sessionId != null) {
        stationId = widget.sessionId!;
      } else {
        final resumable = await store?.findResumableSession(
          userId: widget.userId,
        );
        stationId =
            resumable?.sessionId ??
            'sphere-${DateTime.now().millisecondsSinceEpoch}';
      }
      final controller = SphereCaptureController(
        rotation: rotation,
        camera: camera,
        repository: repository,
        stitcher: widget.stitcher ?? defaults.stitcher,
        backendProcessing: widget.backendProcessing,
        stationId: stationId,
        // The 4:3 normaliser links OpenCV, so it is supplied here rather than
        // defaulted inside the controller: that keeps the controller — and its
        // tests — free of the native stitching library.
        normalize: defaults.normalize,
        sessions: store,
        userId: widget.userId,
        propertyId: widget.propertyId,
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
      controller.addListener(_onControllerChanged);
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
    _controller?.removeListener(_onControllerChanged);
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final camera = _camera;
    if (controller == null || camera == null) {
      return _StartScreen(
        onStart: _starting ? null : _start,
        starting: _starting,
        error: _startError,
      );
    }
    return _LiveCapture(
      controller: controller,
      camera: camera,
      backendProcessing: widget.backendProcessing,
    );
  }
}

// ── start screen ───────────────────────────────────────────────────────────

class _StartScreen extends StatelessWidget {
  const _StartScreen({
    required this.onStart,
    required this.starting,
    this.error,
  });

  final VoidCallback? onStart;
  final bool starting;
  final String? error;

  @override
  Widget build(BuildContext context) => Scaffold(
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
            const Center(child: _SphereDiagram(size: 220)),
            const SizedBox(height: 30),
            const Text(
              'AR 360° Capture ($kSphereTargetCount Targets)',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white,
                fontSize: 25,
                fontWeight: FontWeight.w700,
                height: 1.25,
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              'Hold the phone level and face the first wall, then tap Start. '
              'The $kSphereTargetCount targets are levelled to gravity — turn '
              'to bring the next one into the centre ring and the photograph '
              'is taken automatically.',
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
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
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

/// The 38 dots, drawn orthographically so the layout is visible before Start.
class _SphereDiagram extends StatelessWidget {
  const _SphereDiagram({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: size,
    height: size,
    child: CustomPaint(painter: _SphereDiagramPainter()),
  );
}

class _SphereDiagramPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) / 2 - 8;
    final outline = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.1
      ..color = Colors.white.withValues(alpha: 0.28);
    canvas.drawCircle(center, radius, outline);

    // The three rings, foreshortened the way a sphere reads in a still image.
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
    for (final pitch in <double>[kSphereRingPitchDeg, -kSphereRingPitchDeg]) {
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

    for (final target in buildSphereTargets()) {
      final d = target.direction;
      final point = center + Offset(d.x * radius, -d.y * radius);
      final front = d.z <= 0;
      final isPole = target.isZenith || target.isNadir;
      canvas.drawCircle(
        point,
        isPole ? 4.2 : 3.2,
        Paint()
          ..color = sphereRingColor(target).withValues(alpha: front ? 1 : 0.35),
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
  bool shouldRepaint(_SphereDiagramPainter oldDelegate) => false;
}

// ── live capture ───────────────────────────────────────────────────────────

class _LiveCapture extends StatelessWidget {
  const _LiveCapture({
    required this.controller,
    required this.camera,
    required this.backendProcessing,
  });

  final SphereCaptureController controller;
  final SphereCamera camera;
  final bool backendProcessing;

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    body: Stack(
      fit: StackFit.expand,
      children: [
        // Toolbar and capture controls sit OUTSIDE the viewfinder; the camera
        // image lives in an explicit 3:4 box whose size drives the marker
        // projection. Previously the preview filled the whole screen and the
        // overlay was projected for that fullscreen viewport, so on a tall
        // phone the preview was cover-cropped horizontally while the markers
        // were laid out for the cropped width — the geometry only stayed
        // consistent by accident, and the visible framing was never the 3:4
        // frame the photographs actually capture.
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
              return backendProcessing
                  ? _BackendCompletionOverlay(controller: controller)
                  : _CompletionOverlay(controller: controller);
            }
            if (controller.phase == SphereCapturePhase.failed) {
              return _FailureOverlay(controller: controller);
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
/// it is" from a device log — viewfinder geometry, the lens assumption, the
/// camera's elevation relative to the levelled reference, the selected
/// target's fixed direction, and where both the target and the reticle are
/// drawn. Throttled to once a second: the sensor itself runs at 50 Hz and a
/// per-sample log would drown the device console.
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
      // same frame the middle ring's 0° pitch is defined in, so a non-zero
      // value here is exactly the angle by which the horizon sits above or
      // below the reticle.
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
      'focalY=${p.focalLengthY.toStringAsFixed(1)} '
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
              value: controller.capturedCount / kSphereTargetCount,
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

class _BackendCompletionOverlay extends StatelessWidget {
  const _BackendCompletionOverlay({required this.controller});

  final SphereCaptureController controller;

  @override
  Widget build(BuildContext context) => Container(
    color: Colors.black.withValues(alpha: 0.72),
    child: Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: CaptureColors.sheet,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: CaptureColors.hairlineOnDark),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.cloud_upload_outlined,
                color: CaptureColors.ok,
                size: 48,
              ),
              const SizedBox(height: 12),
              const Text(
                'Capture complete',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '${controller.capturedCount} / $kSphereTargetCount photos saved',
                style: const TextStyle(
                  color: CaptureColors.mutedOnDark,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'SiteWise processes the panorama on the server. Your original '
                'photos stay on this device if an upload needs to be retried.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: CaptureColors.mutedOnDark,
                  fontSize: 13,
                  height: 1.5,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

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
                '${controller.capturedCount} / $kSphereTargetCount Targets',
                style: const TextStyle(
                  color: CaptureColors.mutedOnDark,
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 16),
              _PanoramaStatus(controller: controller),
              const SizedBox(height: 18),
              FilledButton.icon(
                onPressed: controller.panoramaPath == null
                    ? null
                    : () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => SpherePanoramaScreen(
                            panoramaPath: controller.panoramaPath!,
                          ),
                        ),
                      ),
                icon: const Icon(Icons.threesixty, size: 18),
                label: const Text('View 360° Panorama'),
                style: FilledButton.styleFrom(
                  backgroundColor: CaptureColors.accent,
                  foregroundColor: Colors.white,
                  minimumSize: const Size.fromHeight(46),
                ),
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: controller.exporting
                    ? null
                    : () => _saveAndFinish(context),
                icon: controller.exporting
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save_alt, size: 18),
                label: const Text('Save & Finish'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  minimumSize: const Size.fromHeight(46),
                  side: const BorderSide(color: CaptureColors.hairlineOnDark),
                ),
              ),
              if (controller.exportPath != null) ...[
                const SizedBox(height: 10),
                Text(
                  'Exported to ${controller.exportPath}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: CaptureColors.mutedOnDark,
                    fontSize: 10.5,
                    height: 1.4,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    ),
  );

  Future<void> _saveAndFinish(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final path = await controller.saveAndFinish();
    if (!context.mounted) return;
    // Save & Finish after a failed stitch still exports the photographs — that
    // is deliberate, they are the user's work — but it must not claim a
    // panorama was produced. `panoramaPath` is only set when the stitcher
    // returned success *and* the JPEG exists and is non-empty, so it is the
    // honest test here.
    final hasPanorama = controller.panoramaPath != null;
    final message = path == null
        ? controller.message ?? 'The export failed.'
        : hasPanorama
        ? 'Exported $kSphereTargetCount photographs and the panorama to $path'
        : 'Exported $kSphereTargetCount photographs to $path. No panorama was '
              'generated — the photographs are kept, so you can retry stitching '
              'from the review screen without recapturing.';
    messenger.showSnackBar(SnackBar(content: Text(message)));
    if (path != null) navigator.pop();
  }
}

class _PanoramaStatus extends StatelessWidget {
  const _PanoramaStatus({required this.controller});

  final SphereCaptureController controller;

  @override
  Widget build(BuildContext context) {
    if (controller.stitching) {
      return Row(
        children: [
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              controller.stitchStage ?? 'Stitching the panorama…',
              style: const TextStyle(
                color: CaptureColors.mutedOnDark,
                fontSize: 12,
              ),
            ),
          ),
        ],
      );
    }
    if (controller.stitchError != null) {
      return Column(
        children: [
          Text(
            controller.stitchError!,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: CaptureColors.warn,
              fontSize: 11.5,
              height: 1.4,
            ),
          ),
          TextButton(
            onPressed: controller.retryStitching,
            style: TextButton.styleFrom(
              // The app's default theme is the light one, so a text button on
              // this dark screen has to name its own colour.
              foregroundColor: CaptureColors.linkOnDark,
              minimumSize: const Size(0, CaptureMetrics.minTouchTarget),
            ),
            child: const Text('Retry stitching'),
          ),
        ],
      );
    }
    if (controller.panoramaPath != null) {
      return Column(
        children: [
          const Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.check, color: CaptureColors.ok, size: 15),
              SizedBox(width: 6),
              Text(
                '360° panorama ready',
                style: TextStyle(
                  color: CaptureColors.mutedOnDark,
                  fontSize: 12,
                ),
              ),
            ],
          ),
          if (controller.galleryPath != null) ...[
            const SizedBox(height: 4),
            Text(
              'Saved to ${controller.galleryFolder}',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: CaptureColors.linkOnDark,
                fontSize: 10.5,
                height: 1.4,
              ),
            ),
          ],
        ],
      );
    }
    return const Text(
      'The panorama will be generated from the $kSphereTargetCount saved '
      'photographs.',
      textAlign: TextAlign.center,
      style: TextStyle(color: CaptureColors.mutedOnDark, fontSize: 11.5),
    );
  }
}

class _FailureOverlay extends StatelessWidget {
  const _FailureOverlay({required this.controller});

  final SphereCaptureController controller;

  @override
  Widget build(BuildContext context) => Container(
    color: Colors.black.withValues(alpha: 0.82),
    child: Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.error_outline,
              color: CaptureColors.danger,
              size: 42,
            ),
            const SizedBox(height: 14),
            Text(
              controller.message ?? 'The capture stopped.',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: controller.start,
              style: FilledButton.styleFrom(
                backgroundColor: CaptureColors.accent,
              ),
              child: const Text('Try again'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).maybePop(),
              child: const Text(
                'Back',
                style: TextStyle(color: CaptureColors.mutedOnDark),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
