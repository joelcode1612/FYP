import 'package:shared_logic/shared_logic.dart';
import 'package:ar_flutter_plugin/managers/ar_anchor_manager.dart';
import 'package:ar_flutter_plugin/managers/ar_location_manager.dart';
import 'package:ar_flutter_plugin/managers/ar_object_manager.dart';
import 'package:ar_flutter_plugin/managers/ar_session_manager.dart';
import 'package:flutter/foundation.dart';
import 'package:vector_math/vector_math_64.dart' as v;

import '../../../application/services/ar_capture_service.dart';
import '../../../application/services/panorama_capture_service.dart';
import '../../../application/services/service_locator.dart';
import '../../../core/utils/ar_math.dart';
import '../../../core/utils/capture_log.dart';

/// UI state for the AR panorama capture screen.
///
/// Coordinates [PanoramaCaptureService] (state machine + sequence),
/// [ArCaptureService] (AR plugin boundary) and the tour/stitching services.
/// Never builds widgets; the page polls the camera via [pollCameraPose]
/// on a ticker and renders this state.

class PanoramaCaptureViewModel extends ChangeNotifier {
  final PanoramaCaptureService _session;
  final ArCaptureService _ar;

  v.Vector3 cameraPosition = v.Vector3.zero();
  v.Quaternion cameraRotation = v.Quaternion.identity();
  double yawDeg = 0;
  double pitchDeg = 0;
  bool aligned = false;
  String? stage;
  bool generating = false;
  String? lastPanoramaPath;
  String? propertyTitle;

  String? _localError;
  bool _disposed = false;
  bool _polling = false;
  bool _autoBusy = false;

  PanoramaCaptureViewModel({
    required PanoramaCaptureService session,
    required ArCaptureService ar,
    // Public parameter names are the API; private fields stay encapsulated.
    // ignore: prefer_initializing_formals
  }) : _session = session,
       // ignore: prefer_initializing_formals
       _ar = ar;

  List<CapturePoint> get targets => _session.targets;
  int get currentIndex => _session.currentIndex;
  CapturePoint? get currentTarget => _session.currentTarget;
  CaptureSessionState get sessionState => _session.state;
  bool get isComplete => _session.isComplete;
  bool get allCaptured => _session.allCaptured;
  bool get positionWarning => _session.positionWarning;
  bool get originSet => _session.origin != null;
  int get capturedCount => _session.capturedCount;
  double get progress => _session.progress;
  int get totalFrames => _session.targets.length;
  String? get tourId => _session.tourId;
  String? get error => _localError ?? _session.error;
  double get stability => _session.stabilityFraction(DateTime.now());

  bool get canCapture =>
      (_session.state == CaptureSessionState.guiding ||
          _session.state == CaptureSessionState.stabilizing) &&
      aligned &&
      !positionWarning &&
      !generating &&
      !_autoBusy;

  bool get canGenerate =>
      allCaptured &&
      _session.state == CaptureSessionState.guiding &&
      !generating;

  String get stateLabel => switch (_session.state) {
    CaptureSessionState.initializing => 'Initializing AR…',
    CaptureSessionState.trackingReady => 'Tracking ready…',
    CaptureSessionState.settingOrigin => 'Setting capture position…',
    CaptureSessionState.guiding =>
      positionWarning
          ? 'Please return to the capture position.'
          : 'Guide to the highlighted target',
    CaptureSessionState.stabilizing => 'Hold steady…',
    CaptureSessionState.capturing => 'Capturing…',
    CaptureSessionState.processing => stage ?? 'Processing…',
    CaptureSessionState.preview => 'Panorama ready for review',
    CaptureSessionState.completed => 'Tour submitted',
    CaptureSessionState.error => 'Something needs attention',
  };

  /// Resolve (or create) the draft tour for [propertyId] and register the
  /// session for resume. Reuses the live session state when this service
  /// instance was restored from [CaptureSessionStore].
  Future<void> startSession(String propertyId) async {
    try {
      _session.propertyId = propertyId;
      if (_session.tourId == null) {
        String title = 'Property 360° tour';
        String? reusableId;
        try {
          final property = await ServiceLocator.properties.detail(propertyId);
          if (property != null) {
            title = '${property.title} 360° tour';
            propertyTitle = property.title;
            final tours = await ServiceLocator.tourService.toursForOwner(
              property.ownerId,
            );
            for (final t in tours) {
              if (t.propertyId == propertyId &&
                  (t.status == VirtualTourStatus.draft ||
                      t.status == VirtualTourStatus.ready ||
                      t.status == VirtualTourStatus.processing)) {
                reusableId = t.id;
                title = t.title;
                break;
              }
            }
          }
        } catch (e) {
          CaptureLog.log('Tour lookup failed, creating draft: $e');
        }
        final tourId =
            reusableId ??
            (await ServiceLocator.tourService.createDraft(
              propertyId: propertyId,
              title: title,
              frameCount: _session.targets.length,
            )).id;
        _session.tourId = tourId;
        ServiceLocator.captureSessions.startNew(
          propertyId: propertyId,
          tourId: tourId,
          service: _session,
        );
        final persisted = await ServiceLocator.frameStore.loadManifest(tourId);
        if (persisted.isNotEmpty) _session.restoreFrames(persisted);
      } else {
        _session.prepareResume();
        ServiceLocator.captureSessions.startNew(
          propertyId: propertyId,
          tourId: _session.tourId!,
          service: _session,
        );
      }
      _localError = null;
    } catch (e) {
      _localError = 'Could not start capture session: $e';
    }
    _safeNotify();
  }

  Future<void> onARViewCreated(
    ARSessionManager sessionManager,
    ARObjectManager objectManager,
    ARAnchorManager anchorManager,
    ARLocationManager locationManager,
  ) async {
    try {
      await _ar.attach(sessionManager, objectManager);
      await _ar.placeCaptureTargets(_session.targets);
    } catch (e) {
      _localError = e.toString();
      _safeNotify();
    }
  }

  /// Reads the current camera pose, feeds the session state machine and
  /// fires automatic capture once alignment has been stable long enough.
  /// Guarded against overlap, disposal and concurrent captures.
  Future<void> pollCameraPose() async {
    if (_polling || _disposed || !_ar.isReady) return;
    _polling = true;
    try {
      final pose = await _ar.getCameraPose();
      if (pose == null || _disposed) return;
      final translation = v.Vector3.zero();
      final rotation = v.Quaternion.identity();
      final scale = v.Vector3.zero();
      pose.decompose(translation, rotation, scale);
      cameraPosition = translation;
      cameraRotation = rotation;
      final target = _session.currentTarget;
      var yawErr = 0.0;
      var pitchErr = 0.0;
      var ok = false;
      if (target != null) {
        final reading = computeAlignment(
          cameraPosition: translation,
          cameraRotation: rotation,
          targetPosition: sphericalToVector(
            target.pitch,
            target.yaw,
            radius: ArCaptureConfig.nodeRadius,
          ),
          yawTolerance: target.yawTolerance,
          pitchTolerance: target.pitchTolerance,
        );
        yawDeg = reading.yawDeg;
        pitchDeg = reading.pitchDeg;
        yawErr = reading.yawError;
        pitchErr = reading.pitchError;
        ok = reading.aligned;
      }
      aligned = ok && !_session.positionWarning;
      _session.observePose(
        cameraPosition: translation,
        yawError: yawErr,
        pitchError: pitchErr,
        alignedNow: ok,
        at: DateTime.now(),
      );
      _safeNotify();
      if (_session.config.autoCapture &&
          !_autoBusy &&
          !generating &&
          _session.stabilityReady(DateTime.now())) {
        await performCapture();
      }
    } catch (e) {
      _localError = e.toString();
      _safeNotify();
    } finally {
      _polling = false;
    }
  }

  /// Manual capture button. Still requires alignment — it never skips the
  /// capture conditions, it only triggers the acquisition on demand.
  Future<bool> captureManual() => performCapture();

  Future<bool> performCapture() async {
    if (_autoBusy) return false;
    _autoBusy = true;
    try {
      if (!_session.beginCapture()) {
        _localError = _session.error ?? 'Not ready to capture.';
        _safeNotify();
        return false;
      }
      _localError = null;
      _safeNotify();
      final bytes = await _ar.captureSnapshotPng();
      if (bytes == null || _disposed) {
        _session.failCapture('Camera capture failed. Hold steady and retry.');
        _safeNotify();
        return false;
      }
      final tourId = _session.tourId;
      if (tourId == null) {
        _session.failCapture('No tour session. Restart capture.');
        _safeNotify();
        return false;
      }
      final path = await ServiceLocator.frameStore.saveFrame(
        tourId: tourId,
        frameIndex: _session.currentIndex,
        bytes: bytes,
      );
      final ok = _session.confirmFrame(imagePath: path, at: DateTime.now());
      if (!ok) {
        await ServiceLocator.frameStore.deleteFrame(path);
        _safeNotify();
        return false;
      }
      await ServiceLocator.frameStore.saveManifest(tourId, _session.frames);
      _localError = null;
      _safeNotify();
      return true;
    } catch (e) {
      _session.failCapture('Capture error: $e');
      _safeNotify();
      return false;
    } finally {
      _autoBusy = false;
    }
  }

  /// Discard the most recent frame (or the final frame when complete) and
  /// step back to it. The image file is removed; no duplicate is created.
  Future<void> retakeLast() async {
    final idx = allCaptured
        ? _session.targets.length - 1
        : _session.currentIndex - 1;
    if (idx < 0 || !_session.frames.containsKey(idx)) {
      _localError = 'Nothing to retake yet.';
      _safeNotify();
      return;
    }
    final path = _session.frames[idx]!.imagePath;
    await ServiceLocator.frameStore.deleteFrame(path);
    _session.reopenFrame(idx);
    final tourId = _session.tourId;
    if (tourId != null) {
      await ServiceLocator.frameStore.saveManifest(tourId, _session.frames);
    }
    _localError = null;
    _safeNotify();
  }

  /// Validate the 26-frame sequence and run OpenCV stitching. Frames are
  /// never deleted on failure; the error names the problem.
  Future<bool> generatePanorama() async {
    if (generating) return false;
    if (!allCaptured) {
      final missing = _session.missingFrames();
      _localError = missing.isEmpty
          ? 'Capture all 26 frames first.'
          : 'Panorama cannot be generated. '
                'Frame ${missing.first + 1} is missing.';
      _safeNotify();
      return false;
    }
    final tourId = _session.tourId;
    if (tourId == null) {
      _localError = 'No tour session.';
      _safeNotify();
      return false;
    }
    generating = true;
    stage = 'Validating frames...';
    _localError = null;
    _safeNotify();
    try {
      final ordered = _session.frames.entries.toList()
        ..sort((a, b) => a.key.compareTo(b.key));
      final missing = await ServiceLocator.frameStore.missingFiles([
        for (final e in ordered) e.value.imagePath,
      ]);
      if (missing.isNotEmpty) {
        _session.fail(
          'Panorama cannot be generated. ${missing.length} frame file(s) '
          'are unreadable.',
        );
        return false;
      }
      _session.startProcessing();
      if (_session.state != CaptureSessionState.processing) {
        return false;
      }
      await ServiceLocator.tourRepo.updateTour(
        (await ServiceLocator.tourRepo.tourById(
          tourId,
        ))!.copyWith(status: VirtualTourStatus.processing),
      );
      final result = await ServiceLocator.panoramas.generate(
        tourId: tourId,
        frames: [for (final e in ordered) e.value],
        onStage: (s) {
          stage = s;
          _safeNotify();
        },
      );
      if (result.success && result.panoramaPath != null) {
        await ServiceLocator.tourService.attachPanorama(
          tourId,
          result.panoramaPath!,
        );
        lastPanoramaPath = result.panoramaPath;
        _session.markPreview();
        stage = result.message;
        return true;
      }
      _session.fail(result.message);
      return false;
    } catch (e) {
      _session.fail('Generation error: $e');
      return false;
    } finally {
      generating = false;
      _safeNotify();
    }
  }

  /// Restart the whole capture (clears frames from disk and memory).
  Future<void> restartCapture() async {
    final tourId = _session.tourId;
    if (tourId != null) {
      for (final f in _session.frames.values) {
        await ServiceLocator.frameStore.deleteFrame(f.imagePath);
      }
      await ServiceLocator.frameStore.saveManifest(tourId, {});
    }
    _session.reset();
    _localError = null;
    stage = null;
    generating = false;
    lastPanoramaPath = null;
    _safeNotify();
  }

  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _ar.dispose();
    super.dispose();
  }
}
