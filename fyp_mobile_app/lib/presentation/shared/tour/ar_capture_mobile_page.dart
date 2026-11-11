import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:shared_logic/shared_logic.dart';
import 'package:vector_math/vector_math_64.dart' as v;

import '../../../application/services/panorama_capture_service.dart';
import '../../../application/services/service_locator.dart';
import '../../../core/theme/sitewise_theme.dart';
import '../../../core/utils/capture_log.dart';
import '../../../core/utils/device_pose_math.dart';
import '../../../data/datasources/local/camera_pose_source.dart';
import '../widgets/sitewise_button.dart';
import '../widgets/sitewise_confirm_dialog.dart';

/// What the capture screen was opened for. [title] names the tour record; a
/// bare property id (deep link) still works and falls back to a generic title.
class ArCaptureRequest {
  const ArCaptureRequest({required this.propertyId, this.title});

  final String propertyId;
  final String? title;
}

/// Guided 26-frame 360° capture: live camera preview, a reticle driven by the
/// device's real orientation, and the existing [PanoramaCaptureService] state
/// machine deciding when a frame may be taken.
///
/// This is **sensor-guided capture, not ARCore**: orientation comes from the
/// accelerometer and magnetometer, and position in metres is not measurable
/// without visual odometry. The screen says so instead of inventing a position
/// or silently disabling the drift check.
class ArCaptureMobilePage extends StatefulWidget {
  const ArCaptureMobilePage({super.key, required this.request});

  final ArCaptureRequest request;

  @override
  State<ArCaptureMobilePage> createState() => _ArCaptureMobilePageState();
}

class _ArCaptureMobilePageState extends State<ArCaptureMobilePage>
    with WidgetsBindingObserver {
  /// No AR tracking means no real position. A fixed origin keeps the service's
  /// drift check inert rather than feeding it a fabricated trajectory.
  static final v.Vector3 _fixedOrigin = v.Vector3.zero();
  static const Duration _tickEvery = Duration(milliseconds: 100);
  static const int _sensorWaitPolls = 80;

  CameraPoseSource _source = CameraPoseSource();
  PanoramaCaptureService? _service;
  String? _tourId;
  Timer? _ticker;
  double? _originHeading;
  bool _preparing = true;
  bool _paused = false;
  bool _capturing = false;
  bool _generating = false;
  bool _sensorsSilent = false;
  String? _setupError;
  String? _stage;
  int _polls = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _prepare();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.cancel();
    _source.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted || _service == null) return;
    if (state == AppLifecycleState.resumed) {
      if (!_paused) return;
      _paused = false;
      _source = CameraPoseSource();
      _startCamera();
      return;
    }
    if (_paused) return;
    // Only a real background transition releases the camera. `inactive` also
    // fires for the Android permission dialog, which would tear the controller
    // down while initialize() is still awaiting the user's answer.
    if (state != AppLifecycleState.paused &&
        state != AppLifecycleState.hidden) {
      return;
    }
    // Holding the camera while backgrounded crashes on some devices; the
    // session and its confirmed frames stay in the store untouched.
    _paused = true;
    _ticker?.cancel();
    _ticker = null;
    _source.dispose();
    setState(() {});
  }

  Future<void> _prepare() async {
    final propertyId = widget.request.propertyId;
    if (propertyId.isEmpty) {
      setState(() {
        _setupError =
            'No property was supplied, so there is nothing to capture '
            'a tour for.';
        _preparing = false;
      });
      return;
    }
    try {
      var session = ServiceLocator.captureSessions.forProperty(propertyId);
      if (session == null) {
        final tour = await ServiceLocator.tourService.createDraft(
          propertyId: propertyId,
          title: widget.request.title ?? '360° tour',
          frameCount: 0,
        );
        final service = ServiceLocator.newPanoramaCaptureService();
        service.tourId = tour.id;
        service.propertyId = propertyId;
        session = ServiceLocator.captureSessions.startNew(
          propertyId: propertyId,
          tourId: tour.id,
          service: service,
        );
      }
      final service = session.service;
      if (service.frames.isEmpty) {
        final manifest = await ServiceLocator.frameStore.loadManifest(
          session.tourId,
        );
        if (manifest.isNotEmpty) service.restoreFrames(manifest);
      }
      _originHeading = await _readOriginHeading(session.tourId);
      // Re-warm tracking and re-establish the origin; confirmed frames survive.
      service.prepareResume();
      if (!mounted) return;
      setState(() {
        _service = service;
        _tourId = session!.tourId;
        _preparing = false;
      });
      await _syncFrameCount(session.tourId, service.capturedCount);
      await _startCamera();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _setupError = readableFailure(
          error,
          fallback: 'The capture session could not be prepared.',
        );
        _preparing = false;
      });
    }
  }

  Future<void> _startCamera() async {
    _polls = 0;
    _sensorsSilent = false;
    await _source.start();
    if (!mounted) return;
    setState(() {});
    _ticker?.cancel();
    if (_source.error != null) return;
    _ticker = Timer.periodic(_tickEvery, (_) => _onTick());
  }

  void _onTick() {
    final service = _service;
    if (service == null || _paused || _capturing || _generating) return;
    if (service.allCaptured) {
      setState(() {});
      return;
    }
    _polls++;
    final pose = _source.pose;
    if (pose == null) {
      if (_polls >= _sensorWaitPolls && !_sensorsSilent) {
        setState(() => _sensorsSilent = true);
      }
      return;
    }
    final now = DateTime.now();
    final origin = _originHeading;
    if (origin == null) {
      // Warm up tracking without claiming any alignment: the start direction
      // has not been set, so no yaw error is meaningful yet.
      service.observePose(
        cameraPosition: _fixedOrigin,
        yawError: 0,
        pitchError: 0,
        alignedNow: false,
        at: now,
      );
      setState(() {});
      return;
    }
    final target = service.currentTarget;
    if (target == null) return;
    // ZENITH and NADIR accept any yaw (tolerance 360°); a bearing measured
    // while pointing straight up is noise, so it is not shown as an error.
    final yawError = target.yawTolerance >= 360
        ? 0.0
        : DevicePoseMath.wrap180(
            DevicePoseMath.wrap180(pose.headingDeg - origin) - target.yaw,
          );
    final pitchError = pose.pitchDeg - target.pitch;
    service.observePose(
      cameraPosition: _fixedOrigin,
      yawError: yawError,
      pitchError: pitchError,
      alignedNow: target.isAligned(yawDeg: yawError, pitchDeg: pitchError),
      at: now,
    );
    if (service.config.autoCapture && service.stabilityReady(now)) {
      _capture();
      return;
    }
    setState(() {});
  }

  void _setOriginHeading() {
    final pose = _source.pose;
    final tourId = _tourId;
    if (pose == null || tourId == null) return;
    setState(() => _originHeading = pose.headingDeg);
    _writeOriginHeading(tourId, pose.headingDeg);
    CaptureLog.log(
      'Start direction set to ${pose.headingDeg.toStringAsFixed(0)}°',
    );
  }

  Future<void> _capture() async {
    final service = _service;
    final tourId = _tourId;
    if (service == null || tourId == null || _capturing || _generating) return;
    if (service.allCaptured) return;
    if (!service.beginCapture()) {
      setState(() {});
      return;
    }
    setState(() => _capturing = true);
    var complete = false;
    try {
      final bytes = await _source.takePicture();
      final target = service.currentTarget;
      if (target == null) {
        service.failCapture('No active capture target.');
        return;
      }
      final path = await ServiceLocator.frameStore.saveFrame(
        tourId: tourId,
        frameIndex: target.frameIndex,
        bytes: bytes,
      );
      if (!service.confirmFrame(imagePath: path, at: DateTime.now())) {
        // The session refused the frame, so the file is not part of the tour.
        await ServiceLocator.frameStore.deleteFrame(path);
        return;
      }
      await ServiceLocator.frameStore.saveManifest(tourId, service.frames);
      await _syncFrameCount(tourId, service.capturedCount);
      complete = service.allCaptured;
    } catch (error) {
      service.failCapture(
        error is CameraException
            ? 'The camera could not save this frame (${error.code}).'
            : readableFailure(error, fallback: 'The frame could not be saved.'),
      );
    } finally {
      // Every exit clears the busy flag, including the refused-frame paths —
      // otherwise the screen stays on "Saving frame…" with no way forward.
      if (mounted) setState(() => _capturing = false);
    }
    if (complete && mounted) await _generate();
  }

  Future<void> _generate() async {
    final service = _service;
    final tourId = _tourId;
    if (service == null || tourId == null || _generating) return;
    service.startProcessing();
    if (service.state != CaptureSessionState.processing) {
      setState(() {});
      return;
    }
    setState(() {
      _generating = true;
      _stage = 'Validating frames…';
    });
    final ordered = service.frames.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final result = await ServiceLocator.panoramas.generate(
      tourId: tourId,
      frames: [for (final entry in ordered) entry.value],
      onStage: (stage) {
        if (mounted) setState(() => _stage = stage);
      },
    );
    if (!mounted) return;
    setState(() => _generating = false);
    if (result.success) {
      service.markPreview();
      Navigator.of(
        context,
      ).pushReplacementNamed('/tour-preview', arguments: tourId);
      return;
    }
    service.fail(result.message);
    setState(() {});
  }

  Future<void> _restart() async {
    final service = _service;
    final tourId = _tourId;
    if (service == null || tourId == null || _capturing || _generating) return;
    final confirmed = await showSitewiseConfirmDialog(
      context,
      title: 'Restart this capture?',
      message:
          'Every frame saved for this tour is deleted from the device. '
          'The tour itself stays a draft.',
      confirmLabel: 'Restart',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    _ticker?.cancel();
    await ServiceLocator.frameStore.deleteTour(tourId);
    service.reset();
    await ServiceLocator.frameStore.saveManifest(tourId, service.frames);
    await _syncFrameCount(tourId, 0);
    if (!mounted) return;
    setState(() => _originHeading = null);
    _ticker = Timer.periodic(_tickEvery, (_) => _onTick());
  }

  void _openPreview() {
    final tourId = _tourId;
    if (tourId == null) return;
    Navigator.of(
      context,
    ).pushReplacementNamed('/tour-preview', arguments: tourId);
  }

  /// The tour record carries the real number of confirmed frames, so the
  /// preview and the owner's listings never claim progress that was not saved.
  Future<void> _syncFrameCount(String tourId, int count) async {
    try {
      final tour = await ServiceLocator.tourRepo.tourById(tourId);
      if (tour == null || tour.frameCount == count) return;
      await ServiceLocator.tourRepo.updateTour(
        tour.copyWith(frameCount: count, sceneCount: count),
      );
    } catch (error) {
      CaptureLog.log('Frame count could not be recorded: $error');
    }
  }

  Future<double?> _readOriginHeading(String tourId) async {
    try {
      final root = await ServiceLocator.frameStore.tourRoot(tourId);
      final file = File('$root/origin.json');
      if (!await file.exists()) return null;
      final row = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return (row['headingDeg'] as num).toDouble();
    } catch (_) {
      // No usable record: the user sets the start direction again.
      return null;
    }
  }

  Future<void> _writeOriginHeading(String tourId, double headingDeg) async {
    try {
      final root = await ServiceLocator.frameStore.tourRoot(tourId);
      await Directory(root).create(recursive: true);
      await File(
        '$root/origin.json',
      ).writeAsString(jsonEncode({'headingDeg': headingDeg}), flush: true);
    } catch (error) {
      // Retakes still resume from the in-memory session; only a cold restart
      // would need the start direction set again.
      CaptureLog.log('Start direction could not be persisted: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final service = _service;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Guided 360° capture'),
        actions: [
          if (service != null)
            IconButton(
              tooltip: 'Restart capture',
              icon: const Icon(Icons.restart_alt_rounded),
              onPressed: _capturing || _generating ? null : _restart,
            ),
        ],
      ),
      body: _preparing
          ? const Center(
              child: CircularProgressIndicator(color: SitewiseColors.action),
            )
          : _setupError != null
          ? _panel(
              title: 'Capture unavailable',
              message: _setupError!,
              actionLabel: 'Try again',
              onAction: () {
                setState(() {
                  _setupError = null;
                  _preparing = true;
                });
                _prepare();
              },
            )
          : service == null
          ? const SizedBox.shrink()
          : _captureBody(service),
    );
  }

  Widget _captureBody(PanoramaCaptureService service) {
    final overlay = _overlay(service);
    return Stack(
      fit: StackFit.expand,
      children: [
        _preview(),
        if (overlay == null)
          SafeArea(
            child: Column(
              children: [
                _header(service),
                Expanded(child: _reticle(service)),
                _footer(service),
              ],
            ),
          )
        else
          overlay,
      ],
    );
  }

  Widget _preview() {
    final controller = _source.controller;
    if (controller == null || !controller.value.isInitialized) {
      return const SizedBox.shrink();
    }
    return Center(child: CameraPreview(controller));
  }

  Widget _header(PanoramaCaptureService service) {
    final target = service.currentTarget;
    final pose = _source.pose;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: .55),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Frame ${service.currentIndex + 1} of ${service.targets.length}'
                  '${target == null ? '' : ' · ${target.name}'}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Text(
                '${service.capturedCount} saved',
                style: const TextStyle(color: Colors.white70, fontSize: 11),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: service.progress,
              minHeight: 6,
              backgroundColor: Colors.white24,
              color: SitewiseColors.action,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Yaw ${_deg(service.yawErrorDeg)} · Pitch ${_deg(service.pitchErrorDeg)}'
            '${pose == null ? '' : ' · Roll ${_deg(pose.rollDeg)}'}',
            style: const TextStyle(color: Colors.white70, fontSize: 11),
          ),
          const SizedBox(height: 6),
          const Text(
            'Sensor-guided capture, not AR tracking. Directions are relative to '
            'the start direction you set. Stay in one spot — position drift '
            'cannot be measured on this device.',
            style: TextStyle(
              color: Colors.white60,
              fontSize: 10.5,
              height: 1.3,
            ),
          ),
        ],
      ),
    );
  }

  Widget _reticle(PanoramaCaptureService service) {
    final target = service.currentTarget;
    return CustomPaint(
      painter: _ReticlePainter(
        yawErrorDeg: service.yawErrorDeg,
        pitchErrorDeg: service.pitchErrorDeg,
        anyYaw: (target?.yawTolerance ?? 0) >= 360,
        aligned: service.aligned,
        stability: service.stabilityFraction(DateTime.now()),
      ),
      child: const SizedBox.expand(),
    );
  }

  Widget _footer(PanoramaCaptureService service) {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: .55),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            _instruction(service),
            textAlign: TextAlign.center,
            style: TextStyle(
              color: service.aligned ? SitewiseColors.success : Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
          if (service.error != null) ...[
            const SizedBox(height: 6),
            Text(
              service.error!,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: SitewiseColors.danger,
                fontSize: 11.5,
              ),
            ),
          ],
          const SizedBox(height: 10),
          SitewiseButton(
            label: _capturing ? 'Saving frame…' : 'Capture frame',
            icon: Icons.camera_alt_rounded,
            onPressed:
                service.aligned && !_capturing && !_generating && !_paused
                ? _capture
                : null,
          ),
        ],
      ),
    );
  }

  String _instruction(PanoramaCaptureService service) {
    if (_capturing) return 'Saving frame…';
    if (_source.pose == null) return 'Waiting for the motion sensors…';
    final target = service.currentTarget;
    if (target == null) return 'No capture target.';
    if (service.aligned) return 'Aligned — hold still.';
    final parts = <String>[];
    final yaw = service.yawErrorDeg;
    final pitch = service.pitchErrorDeg;
    if (target.yawTolerance < 360 && yaw.abs() > target.yawTolerance) {
      parts.add(
        '${yaw > 0 ? 'Turn left' : 'Turn right'} ${yaw.abs().toStringAsFixed(0)}°',
      );
    }
    if (pitch.abs() > target.pitchTolerance) {
      parts.add(
        '${pitch > 0 ? 'Tilt down' : 'Tilt up'} '
        '${pitch.abs().toStringAsFixed(0)}°',
      );
    }
    return parts.isEmpty ? 'Hold still…' : parts.join(' · ');
  }

  /// A blocking condition replaces the guidance overlay rather than sitting on
  /// top of it: no alignment numbers are shown while they would be meaningless.
  Widget? _overlay(PanoramaCaptureService service) {
    if (_paused) {
      return _panel(
        title: 'Camera paused',
        message:
            'The camera was released while the app was in the background. '
            'Return to the app to continue; your saved frames are kept.',
      );
    }
    if (_source.error != null) {
      return _panel(
        title: 'Camera unavailable',
        message: _source.error!,
        actionLabel: 'Try again',
        onAction: _startCamera,
      );
    }
    if (_source.sensorError != null) {
      return _panel(
        title: 'Orientation unavailable',
        message: _source.sensorError!,
        actionLabel: 'Try again',
        onAction: _startCamera,
      );
    }
    if (_sensorsSilent) {
      return _panel(
        title: 'No orientation data',
        message:
            'The accelerometer and compass have not reported a reading. '
            'Guided capture needs both — a device without a magnetometer '
            'cannot aim at the 26 targets.',
        actionLabel: 'Try again',
        onAction: _startCamera,
      );
    }
    if (_generating) {
      return _panel(
        title: 'Generating panorama',
        message: _stage ?? 'Working…',
        busy: true,
      );
    }
    if (service.state == CaptureSessionState.error) {
      return _panel(
        title: 'Capture stopped',
        message: service.error ?? 'The capture session failed.',
        actionLabel: 'Review saved frames',
        onAction: _openPreview,
      );
    }
    if (_originHeading == null) {
      final pose = _source.pose;
      return _panel(
        title: 'Set the start direction',
        message:
            'Stand where you will stay for all 26 frames and point the '
            'camera at the direction you want as 0°. Every target is measured '
            'from it.'
            '${pose == null ? '' : '\n\nCurrent direction: ${pose.headingDeg.toStringAsFixed(0)}°'}',
        actionLabel: 'Set start direction',
        onAction: pose == null ? null : _setOriginHeading,
      );
    }
    if (service.allCaptured) {
      return _panel(
        title: 'All 26 frames captured',
        message:
            'Generate the panorama to finish this tour. You can still '
            'retake individual frames from the preview.',
        actionLabel: 'Generate panorama',
        onAction: _generate,
        secondaryLabel: 'Review frames',
        onSecondary: _openPreview,
      );
    }
    return null;
  }

  Widget _panel({
    required String title,
    required String message,
    String? actionLabel,
    VoidCallback? onAction,
    String? secondaryLabel,
    VoidCallback? onSecondary,
    bool busy = false,
  }) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: .78),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white24),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (busy) ...[
                const Center(
                  child: CircularProgressIndicator(
                    color: SitewiseColors.action,
                  ),
                ),
                const SizedBox(height: 14),
              ],
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
              if (actionLabel != null) ...[
                const SizedBox(height: 16),
                SitewiseButton(
                  label: actionLabel,
                  onPressed: busy ? null : onAction,
                ),
              ],
              if (secondaryLabel != null) ...[
                const SizedBox(height: 8),
                TextButton(
                  onPressed: onSecondary,
                  child: Text(
                    secondaryLabel,
                    style: const TextStyle(color: Colors.white70),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  static String _deg(double value) =>
      '${value >= 0 ? '+' : ''}${value.toStringAsFixed(0)}°';
}

/// Draws the fixed centre crosshair and the target ring displaced by the real
/// alignment error, so the user moves the phone until the two coincide.
class _ReticlePainter extends CustomPainter {
  _ReticlePainter({
    required this.yawErrorDeg,
    required this.pitchErrorDeg,
    required this.anyYaw,
    required this.aligned,
    required this.stability,
  });

  final double yawErrorDeg;
  final double pitchErrorDeg;
  final bool anyYaw;
  final bool aligned;
  final double stability;

  static const double _pxPerDeg = 4;
  static const double _ringRadius = 46;

  @override
  void paint(Canvas canvas, Size size) {
    final centre = Offset(size.width / 2, size.height / 2);
    final guide = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..color = Colors.white54;
    canvas.drawLine(centre.translate(-14, 0), centre.translate(14, 0), guide);
    canvas.drawLine(centre.translate(0, -14), centre.translate(0, 14), guide);

    final reachX = size.width / 2 - _ringRadius - 8;
    final reachY = size.height / 2 - _ringRadius - 8;
    // A target to the left of where the camera points sits left of centre.
    final dx = anyYaw
        ? 0.0
        : (-yawErrorDeg * _pxPerDeg).clamp(-reachX, reachX).toDouble();
    final dy = (pitchErrorDeg * _pxPerDeg).clamp(-reachY, reachY).toDouble();
    final ring = centre.translate(dx, dy);
    final color = aligned ? SitewiseColors.success : SitewiseColors.warning;

    canvas.drawCircle(
      ring,
      _ringRadius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = color,
    );
    canvas.drawCircle(ring, 4, Paint()..color = color);
    if (stability > 0) {
      canvas.drawArc(
        Rect.fromCircle(center: ring, radius: _ringRadius + 9),
        -1.5707963267948966,
        stability * 6.283185307179586,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4
          ..strokeCap = StrokeCap.round
          ..color = SitewiseColors.action,
      );
    }
  }

  @override
  bool shouldRepaint(_ReticlePainter old) =>
      old.yawErrorDeg != yawErrorDeg ||
      old.pitchErrorDeg != pitchErrorDeg ||
      old.anyYaw != anyYaw ||
      old.aligned != aligned ||
      old.stability != stability;
}
