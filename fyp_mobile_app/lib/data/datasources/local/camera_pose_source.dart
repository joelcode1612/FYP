import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
import 'package:sensors_plus/sensors_plus.dart';

import '../../../core/utils/device_pose_math.dart';

/// Live camera preview plus device orientation for the guided 360° capture.
///
/// Orientation comes from the accelerometer and magnetometer. There is no
/// AR/visual-odometry plugin in this app, so **device position in metres is not
/// measurable here** — callers must not invent one, and the capture screen
/// tells the user that drift monitoring is unavailable.
class CameraPoseSource {
  CameraController? _controller;
  StreamSubscription<AccelerometerEvent>? _accel;
  StreamSubscription<MagnetometerEvent>? _mag;
  List<double>? _filteredAccel;
  List<double>? _filteredMag;
  DevicePose? _pose;
  String? _error;
  String? _sensorError;
  bool _disposed = false;

  CameraController? get controller => _controller;

  /// Latest fused orientation, or null until both sensors have reported.
  DevicePose? get pose => _pose;

  /// Camera failure (missing hardware, denied permission, init failure).
  String? get error => _error;

  /// Sensor failure reported by the platform streams.
  String? get sensorError => _sensorError;

  bool get previewReady => _controller?.value.isInitialized ?? false;

  static const Duration _sampling = Duration(milliseconds: 20);

  /// Opens the back camera and starts the orientation streams. Never throws:
  /// a failure is reported through [error] so the screen can state it and offer
  /// a retry instead of rendering a black rectangle.
  Future<void> start() async {
    if (_disposed) return;
    _error = null;
    _sensorError = null;
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        _error = 'No camera is available on this device, so a tour cannot be '
            'captured here.';
        return;
      }
      final back = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      final controller = CameraController(
        back,
        ResolutionPreset.high,
        enableAudio: false,
      );
      await controller.initialize();
      // All 26 frames must share one stored orientation, otherwise the
      // stitcher receives tiles rotated against each other.
      await controller.lockCaptureOrientation(DeviceOrientation.portraitUp);
      if (_disposed) {
        await controller.dispose();
        return;
      }
      _controller = controller;
    } on CameraException catch (e) {
      _error = switch (e.code) {
        'CameraAccessDenied' ||
        'CameraAccessDeniedWithoutPrompt' ||
        'cameraPermission' =>
          'Camera permission was denied. Allow camera access for SiteWise in '
              'the system settings, then reopen this screen.',
        _ => 'The camera could not be started (${e.code})'
            '${e.description == null ? '.' : ': ${e.description}'}',
      };
      return;
    } catch (e) {
      _error = 'The camera could not be started: $e';
      return;
    }

    _accel = accelerometerEventStream(samplingPeriod: _sampling).listen(
      (event) {
        _filteredAccel = DevicePoseMath.lowPass(
          _filteredAccel,
          [event.x, event.y, event.z],
        );
        _fuse();
      },
      onError: (Object e) {
        _sensorError = 'The motion sensors stopped reporting: $e';
      },
    );
    _mag = magnetometerEventStream(samplingPeriod: _sampling).listen(
      (event) {
        _filteredMag = DevicePoseMath.lowPass(
          _filteredMag,
          [event.x, event.y, event.z],
          alpha: 0.6,
        );
        _fuse();
      },
      onError: (Object e) {
        _sensorError = 'The compass stopped reporting: $e';
      },
    );
  }

  void _fuse() {
    final accel = _filteredAccel;
    final mag = _filteredMag;
    if (accel == null || mag == null) return;
    final pose = DevicePoseMath.fuse(accel: accel, mag: mag);
    if (pose != null) _pose = pose;
  }

  /// Captures one still and returns its encoded bytes. Throws when the camera
  /// is not ready or a capture is already running — the caller must keep the
  /// user on the same target and let them retry.
  Future<Uint8List> takePicture() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      throw StateError('The camera is not ready.');
    }
    if (controller.value.isTakingPicture) {
      throw StateError('A capture is already running.');
    }
    final file = await controller.takePicture();
    return file.readAsBytes();
  }

  Future<void> dispose() async {
    _disposed = true;
    await _accel?.cancel();
    await _mag?.cancel();
    _accel = null;
    _mag = null;
    final controller = _controller;
    _controller = null;
    _pose = null;
    if (controller != null) {
      try {
        await controller.dispose();
      } catch (_) {
        // Already torn down by the platform (backgrounded, hot restart).
      }
    }
  }
}