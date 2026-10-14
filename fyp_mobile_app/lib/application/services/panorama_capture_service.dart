import 'package:shared_logic/shared_logic.dart';
import 'package:vector_math/vector_math_64.dart' as v;

import '../../core/utils/capture_log.dart';

/// Capture-session orchestration for the 26-frame AR panorama flow.
///
/// Pure Dart — no Flutter, AR plugin, or I/O dependencies. Owns the explicit
/// session state machine, the ordered frame sequence (no skipping, no
/// duplicates, no advance before a confirmed image), stability tracking,
/// fixed-origin monitoring and frame validation. Timestamps are passed in so
/// the logic stays deterministic and unit-testable.

class PanoramaCaptureService {
  final List<CapturePoint> targets;
  final CaptureConfig config;

  CaptureSessionState _state = CaptureSessionState.initializing;
  int _currentIndex = 0;
  final Map<int, CapturedFrame> _frames = {};
  v.Vector3? _origin;
  int _steadyPolls = 0;
  DateTime? _alignedSince;
  bool _captureInFlight = false;

  double yawErrorDeg = 0;
  double pitchErrorDeg = 0;
  bool aligned = false;
  bool positionWarning = false;
  String? error;
  String? tourId;
  String? propertyId;

  PanoramaCaptureService(
    List<CapturePoint> targets, [
    this.config = const CaptureConfig(),
  ]) : targets = List.unmodifiable(targets);

  CaptureSessionState get state => _state;
  int get currentIndex => _currentIndex;

  CapturePoint? get currentTarget => targets.isEmpty
      ? null
      : targets[_currentIndex.clamp(0, targets.length - 1)];

  Map<int, CapturedFrame> get frames => Map.unmodifiable(_frames);
  int get capturedCount => _frames.length;
  bool get allCaptured =>
      targets.isNotEmpty && _frames.length >= targets.length;
  bool get isLast => targets.isNotEmpty && _currentIndex >= targets.length - 1;
  bool get isComplete => _state == CaptureSessionState.completed;

  double get progress {
    if (targets.isEmpty) return 0;
    if (_state == CaptureSessionState.completed) return 1;
    return _frames.length / targets.length;
  }

  v.Vector3? get origin => _origin?.clone();

  /// Feed one camera-pose observation (already reduced to alignment errors
  /// by the caller). Drives tracking warm-up, origin capture, stability
  /// tracking and position monitoring.
  void observePose({
    required v.Vector3 cameraPosition,
    required double yawError,
    required double pitchError,
    required bool alignedNow,
    required DateTime at,
  }) {
    if (targets.isEmpty) {
      error = 'No capture targets configured.';
      _state = CaptureSessionState.error;
      return;
    }
    if (_origin != null) {
      positionWarning =
          cameraPosition.distanceTo(_origin!) > config.movementThresholdMeters;
    }
    yawErrorDeg = yawError;
    pitchErrorDeg = pitchError;
    aligned = alignedNow && !positionWarning;

    switch (_state) {
      case CaptureSessionState.initializing:
        _steadyPolls++;
        if (_steadyPolls >= config.trackingWarmupPolls) {
          _state = CaptureSessionState.trackingReady;
          CaptureLog.log('Tracking ready');
        }
      case CaptureSessionState.trackingReady:
        _origin = cameraPosition.clone();
        _state = CaptureSessionState.settingOrigin;
        CaptureLog.log('Capture origin established');
        _state = CaptureSessionState.guiding;
        _announceTarget();
      case CaptureSessionState.guiding:
      case CaptureSessionState.stabilizing:
        if (!aligned) {
          if (_state == CaptureSessionState.stabilizing) {
            CaptureLog.log('Alignment lost, stability timer reset');
          }
          _alignedSince = null;
          _state = CaptureSessionState.guiding;
          return;
        }
        _alignedSince ??= at;
        if (_state == CaptureSessionState.guiding) {
          _state = CaptureSessionState.stabilizing;
        }
      case CaptureSessionState.capturing:
      case CaptureSessionState.processing:
      case CaptureSessionState.preview:
      case CaptureSessionState.completed:
      case CaptureSessionState.error:
      case CaptureSessionState.settingOrigin:
        break;
    }
  }

  /// True once alignment has held continuously for [CaptureConfig.stabilityDuration].
  bool stabilityReady(DateTime now) {
    final since = _alignedSince;
    if (_state != CaptureSessionState.stabilizing || since == null) {
      return false;
    }
    return now.difference(since) >= config.stabilityDuration;
  }

  /// Reserve the current target for capture. Returns false when capture
  /// must not start (not aligned, off-origin, or one already running).
  bool beginCapture() {
    if (_captureInFlight) return false;
    if (_state != CaptureSessionState.guiding &&
        _state != CaptureSessionState.stabilizing) {
      return false;
    }
    if (!aligned) {
      error = 'Align with the target before capturing.';
      return false;
    }
    _captureInFlight = true;
    error = null;
    _state = CaptureSessionState.capturing;
    CaptureLog.log('Capturing frame ${_currentIndex + 1}');
    return true;
  }

  /// Record a successfully saved image for the reserved target and advance.
  /// Never advances without a confirmed image; never duplicates a frame.
  bool confirmFrame({required String imagePath, required DateTime at}) {
    if (!_captureInFlight || _state != CaptureSessionState.capturing) {
      error = 'No capture in progress.';
      return false;
    }
    final target = currentTarget;
    if (target == null) {
      error = 'No active target.';
      _captureInFlight = false;
      return false;
    }
    if (_frames.containsKey(_currentIndex)) {
      error = 'Frame ${_currentIndex + 1} is already captured.';
      _captureInFlight = false;
      _state = CaptureSessionState.guiding;
      return false;
    }
    _frames[_currentIndex] = CapturedFrame(
      frameIndex: target.frameIndex,
      targetName: target.name,
      targetYaw: target.yaw,
      targetPitch: target.pitch,
      imagePath: imagePath,
      capturedAt: at,
    );
    _captureInFlight = false;
    CaptureLog.log('Frame ${_currentIndex + 1} saved');
    if (allCaptured) {
      CaptureLog.log('All ${targets.length} frames captured');
    } else {
      _currentIndex++;
      _alignedSince = null;
      _announceTarget();
    }
    _state = CaptureSessionState.guiding;
    return true;
  }

  /// A capture attempt failed: stay on the same target so the user can retry.
  void failCapture(String message) {
    _captureInFlight = false;
    error = message;
    if (_state == CaptureSessionState.capturing) {
      _state = CaptureSessionState.guiding;
    }
    CaptureLog.log('Capture failed: $message');
  }

  /// Discard frame [index] and return to it for a retake. Later frames are
  /// kept — they were taken from the same origin and stay valid.
  void reopenFrame(int index) {
    if (index < 0 || index >= targets.length) return;
    _frames.remove(index);
    _currentIndex = index;
    _alignedSince = null;
    error = null;
    _state = CaptureSessionState.guiding;
    CaptureLog.log('Retaking frame ${index + 1} (${targets[index].name})');
  }

  /// Sequence positions (0-based) with no confirmed frame yet.
  List<int> missingFrames() {
    final missing = <int>[];
    for (var i = 0; i < targets.length; i++) {
      if (!_frames.containsKey(i)) missing.add(i);
    }
    return missing;
  }

  /// Fraction (0–1) of the stability window already elapsed.
  double stabilityFraction(DateTime now) {
    final since = _alignedSince;
    if (_state != CaptureSessionState.stabilizing || since == null) return 0;
    final total = config.stabilityDuration.inMicroseconds;
    if (total <= 0) return 1;
    return (now.difference(since).inMicroseconds / total).clamp(0.0, 1.0);
  }

  /// Restore previously persisted frames (resume flow). Points at the
  /// first missing frame and returns to guiding.
  void restoreFrames(Map<int, CapturedFrame> frames) {
    _frames
      ..clear()
      ..addAll(frames);
    final missing = missingFrames();
    _currentIndex = missing.isEmpty ? targets.length - 1 : missing.first;
    _alignedSince = null;
    error = null;
    if (_state != CaptureSessionState.completed) {
      _state = CaptureSessionState.guiding;
    }
    CaptureLog.log('Session restored with ${_frames.length} frames');
  }

  /// Re-arm a resumed session: re-warm tracking and re-establish the
  /// capture origin on the next pose polls. Frames are kept.
  void prepareResume() {
    if (_state == CaptureSessionState.completed) return;
    _steadyPolls = 0;
    _alignedSince = null;
    _state = CaptureSessionState.trackingReady;
    CaptureLog.log('Session resumed, re-establishing origin');
  }

  void startProcessing() {
    if (!allCaptured) {
      final missing = missingFrames();
      error = missing.isEmpty
          ? 'Frames are incomplete.'
          : 'Panorama cannot be generated. Frame ${missing.first + 1} is missing.';
      return;
    }
    error = null;
    _state = CaptureSessionState.processing;
    CaptureLog.log('Starting panorama generation');
  }

  void markPreview() {
    _state = CaptureSessionState.preview;
    CaptureLog.log('Panorama validation successful');
  }

  void markCompleted() {
    _state = CaptureSessionState.completed;
  }

  void fail(String message) {
    error = message;
    _state = CaptureSessionState.error;
    CaptureLog.log('Error: $message');
  }

  void reset() {
    _state = CaptureSessionState.initializing;
    _currentIndex = 0;
    _frames.clear();
    _origin = null;
    _steadyPolls = 0;
    _alignedSince = null;
    _captureInFlight = false;
    yawErrorDeg = 0;
    pitchErrorDeg = 0;
    aligned = false;
    positionWarning = false;
    error = null;
  }

  void _announceTarget() {
    final target = currentTarget;
    if (target == null) return;
    CaptureLog.log(
      'Current target: ${_currentIndex + 1}/${targets.length} '
      '(${target.name}, yaw ${target.yaw}°, pitch ${target.pitch}°)',
    );
  }
}
