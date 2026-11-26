import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
// The manifest mirror this page clears uses shared_logic's CapturedFrame
// shape; every capture-flow type below is the 38-target sphere entity, which
// is why shared's CapturedFrame is hidden and the sphere one is THE type.
import 'package:shared_logic/shared_logic.dart' hide CapturedFrame;
import 'package:shared_logic/shared_logic.dart' as manifest show CapturedFrame;

import 'package:fyp/core/di/service_locator.dart';
import 'package:fyp/core/config/mobile_config.dart';
import 'package:fyp/core/utils/capture_log.dart';
// The handoff stage enum is shared with the preview; the upload work itself
// now flows through [FrameUploadQueue].
import 'package:fyp/features/capture_360/application/backend_capture_coordinator.dart'
    show BackendHandoffStage;
import 'package:fyp/features/capture_360/application/capture_panorama_generation_service.dart';
import 'package:fyp/features/capture_360/application/frame_upload_queue.dart';
import 'package:fyp/features/capture_360/data/repositories/sitewise_capture_repository.dart';
import 'package:fyp/features/capture_360/data/quality/dartcv_overlap_probe.dart';
import 'package:fyp/features/capture_360/data/quality/ui_frame_pixels_decoder.dart';
import 'package:fyp/features/capture_360/data/sphere/equirectangular_stitcher.dart';
import 'package:fyp/features/capture_360/data/sphere/sitewise_sphere_session_store.dart';
import 'package:fyp/features/capture_360/domain/quality/frame_quality_analyzer.dart';
import 'package:fyp/features/capture_360/domain/sphere/sphere_capture_session.dart';
import 'package:fyp/features/capture_360/domain/sphere/sphere_target.dart';
import 'package:fyp/features/capture_360/guide/presentation/screens/capture_guide_screen.dart';
import 'package:fyp/features/capture_360/presentation/sphere/screens/sphere_capture_screen.dart';
import 'package:fyp/shared/presentation/widgets/sitewise_button.dart';
import 'package:fyp/shared/presentation/widgets/sitewise_confirm_dialog.dart';
import 'package:fyp/shared/presentation/widgets/sitewise_secondary_button.dart';

/// What the capture screen was opened for. [title] names the tour record; a
/// bare property id (deep link) still works and falls back to a generic title.
class ArCaptureRequest {
  const ArCaptureRequest({required this.propertyId, this.title});

  final String propertyId;
  final String? title;
}

/// Guided 38-point 360° capture, driven by device rotation only.
///
/// The sphere's centre is the phone at all times: the 38 directions come from
/// the fixed layout in `sphere_target.dart`, the pose comes from the fused
/// rotation vector and the shutter fires inside a 2° alignment cone while the
/// phone is angularly still. There is no AR session, no plane detection and no
/// world anchor, so walking moves the whole sphere with the phone — only
/// rotation is tracked.
///
/// Once the 38th original JPEG is saved, this host owns the handoff: the
/// device stitches the 2:1 equirectangular panorama FIRST — the device
/// panorama is canonical — and only then talks to FastAPI. The finished
/// panorama is uploaded and confirmed through the signed panorama endpoints,
/// and the 38 originals are backed up afterwards through the resumable queue.
/// The server never re-stitches a device-generated capture.
class ArCaptureMobilePage extends StatefulWidget {
  const ArCaptureMobilePage({super.key, required this.request});

  final ArCaptureRequest request;

  @override
  State<ArCaptureMobilePage> createState() => _ArCaptureMobilePageState();
}

class _ArCaptureMobilePageState extends State<ArCaptureMobilePage> {
  SiteWiseCaptureRepository? _repository;
  SitewiseSphereSessionStore? _sessions;

  /// The durable per-photograph upload queue. Every saved photograph is
  /// queued here the moment it hits disk; the panorama joins it when the
  /// stitch completes. One instance per station, shared process-wide.
  FrameUploadQueue? _uploadQueue;

  /// The per-photograph quality verifier. Warnings are attached to the saved
  /// frames and shown in the capture UI; this page never acts on them
  /// automatically — the agent decides on any retake.
  FrameQualityAnalyzer? _qualityAnalyzer;
  String? _tourId;
  bool _preparing = true;
  bool _guideCompleted = false;
  bool _resumedComplete = false;
  Future<void>? _draftFuture;

  BackendHandoffStage? _handoffStage;
  int _processed = 0;
  int _total = kSphereTargetCount;
  int _requiredTargetCount = kSphereTargetCount;
  bool _selectingPlan = false;
  int? _processingPercent;
  String? _failure;
  String? _setupError;

  /// What failed, so the recovery screen offers the RIGHT recovery: a device
  /// stitch failure retries stitching (the originals are untouched); an
  /// upload failure retries the queue drain (the panorama is already on
  /// disk).
  String? _failureKind;

  /// The device-stitched panorama the draft workflow uploads. Set by the
  /// capture screen's `onPanoramaReady` callback or by the resume stitch;
  /// the canonical tour file is produced on this device, never on the server.
  String? _panoramaPath;

  bool _returnedAfterCapture = false;

  bool get _draftRunning => _draftFuture != null;

  @override
  void initState() {
    super.initState();
    _prepare();
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
      // One unfinished capture per property. Reusing the draft is what makes
      // "resume" safe: a second tour for the same property would split the
      // saved frames across two records.
      final tour =
          await ServiceLocator.tourService.tourForPropertyDraft(propertyId) ??
          await ServiceLocator.tourService.createDraft(
            propertyId: propertyId,
            title: widget.request.title ?? '360° tour',
            frameCount: 0,
          );
      final frameStore = ServiceLocator.frameStore;

      // Engine check before anything opens: records without a session marker
      // were written by the retired 26-point flow and must not be resumed as a
      // 38-point session. A station the 38-flow has never touched (no records
      // at all) just starts normally.
      final isSphereEngine = await SitewiseSphereSessionStore.hasSessionMarker(
        frameStore: frameStore,
        tourId: tour.id,
      );
      if (!isSphereEngine) {
        final legacyRecords = await SiteWiseCaptureRepository(
          tourId: tour.id,
          frameStore: frameStore,
        ).loadRecords(tour.id);
        if (legacyRecords.isNotEmpty) {
          if (!mounted) return;
          final restart = await showSitewiseConfirmDialog(
            context,
            title: 'Start the 38-point capture over?',
            message:
                'This tour was captured with the previous 26-point flow, which '
                'this app no longer runs. Its ${legacyRecords.length} saved '
                'photographs cannot be finished into a 38-point panorama. '
                'Start over deletes them and captures all 38 points; Cancel '
                'keeps everything exactly as it is.',
            confirmLabel: 'Start over',
            destructive: true,
          );
          if (!restart) {
            if (!mounted) return;
            Navigator.of(context).pop();
            return;
          }
          await _purgeLegacyCapture(tour.id);
        }
      }

      final repository = SiteWiseCaptureRepository(
        tourId: tour.id,
        frameStore: frameStore,
        onProgress: (count) => _syncFrameCount(tour.id, count),
      );
      final sessions = SitewiseSphereSessionStore(
        frameStore: frameStore,
        tourId: tour.id,
      );
      // One queue per station, shared with the preview and the property
      // detail. Created before the camera starts so the FIRST photograph is
      // already queued before the second is shot.
      final uploadQueue = MobileConfig.usesLiveApi
          ? FrameUploadQueue.forTour(frameStore: frameStore, tourId: tour.id)
          : null;

      // The lightweight on-device quality checks (sharpness/blur, exposure,
      // integrity/dimensions, orientation metadata, advisory overlap). The
      // decoder and probe are stateless, so one instance serves the session.
      final qualityAnalyzer = FrameQualityAnalyzer(
        decoder: const UiJpegFrameDecoder(),
        overlapProbe: const DartCvOverlapProbe(),
      );

      // App-closed recovery: if all originals are already on disk, do not open
      // the camera or re-run the guide. The resume path saves the panorama
      // draft (stitching first if the previous launch never got to it), then
      // the queue resumes the remaining uploads.
      final restoredFrames = isSphereEngine
          ? await sessions.loadFrames(tour.id)
          : const <CapturedFrame>[];
      final restoredSession = isSphereEngine
          ? await sessions.getSession(tour.id)
          : null;
      final count = restoredSession?.requiredTargetCount ?? kSphereTargetCount;
      sitewisePlanVersionForCount(count);
      if (isSphereEngine && restoredSession == null && restoredFrames.isNotEmpty) {
        throw StateError('Saved photos have no capture plan.');
      }
      final savedIds = <int>{};
      for (final frame in restoredFrames) {
        if (frame.targetId < 1 || frame.targetId > count || !savedIds.add(frame.targetId)) {
          throw StateError('Saved photos do not match the capture plan.');
        }
      }
      final present = restoredFrames.where((f) => File(f.imagePath).existsSync()).length;
      final shouldResume = MobileConfig.usesLiveApi && present == count;

      if (!mounted) return;
      setState(() {
        _tourId = tour.id;
        _repository = repository;
        _sessions = sessions;
        _uploadQueue = uploadQueue;
        _qualityAnalyzer = qualityAnalyzer;
        _requiredTargetCount = count;
        _total = count;
        _guideCompleted = restoredSession != null;
        _resumedComplete = shouldResume;
        _preparing = false;
      });

      if (shouldResume) {
        if (restoredSession?.syncStatus == FrameSyncStatus.ready &&
            restoredSession?.panoramaSyncStatus == FrameSyncStatus.ready &&
            (count != 56 || (restoredSession?.localPanoramaPath != null &&
                File(restoredSession!.localPanoramaPath!).existsSync()))) {
          _returnAfterCapture();
        } else {
          unawaited(_resumeDraftFlow(restoredFrames, restoredSession));
        }
      } else if (uploadQueue != null && restoredFrames.isNotEmpty) {
        unawaited(() async {
          try {
            await uploadQueue.reconcileFrames(
              restoredFrames,
              propertyId: int.tryParse(propertyId),
            );
            await uploadQueue.resume();
          } on Object catch (error) {
            CaptureLog.log('Saved photo uploads could not resume: $error');
          }
        }());
      }
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

  Future<void> _selectPlan(int count) async {
    if (_selectingPlan || _guideCompleted) return;
    final sessions = _sessions;
    final id = _tourId;
    if (sessions == null || id == null) return;
    setState(() => _selectingPlan = true);
    try {
      sitewisePlanVersionForCount(count);
      if (count == 56 && (!MobileConfig.usesLiveApi || _uploadQueue == null)) {
        throw StateError('Enhanced capture requires the SiteWise service.');
      }
      // The saved session is authoritative, even if it has zero frames.
      final saved = await sessions.createSession(
        sessionId: id,
        propertyId: int.tryParse(widget.request.propertyId),
        requiredTargetCount: count,
      );
      if (!mounted) return;
      setState(() {
        _requiredTargetCount = saved.requiredTargetCount;
        _total = saved.requiredTargetCount;
        _guideCompleted = true;
      });
    } on Object catch (error) {
      CaptureLog.log('Capture plan could not be saved: $error');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Could not save the capture plan. Please try again.'),
        ));
      }
    } finally {
      if (mounted) setState(() => _selectingPlan = false);
    }
  }

  /// Deletes the legacy 26-point station and its manifest mirror, so the
  /// 38-point flow starts from an empty directory. Only the station subtree is
  /// removed — the tour record and anything else in the tour directory stay.
  Future<void> _purgeLegacyCapture(String tourId) async {
    try {
      final root = await ServiceLocator.frameStore.tourRoot(tourId);
      final stationDir = Directory(p.join(root, 'ar_capture', tourId));
      if (await stationDir.exists()) {
        await stationDir.delete(recursive: true);
      }
      await ServiceLocator.frameStore.saveManifest(
        tourId,
        const <int, manifest.CapturedFrame>{},
      );
      CaptureLog.log('Legacy 26-point capture cleared for tour $tourId');
    } catch (error) {
      CaptureLog.log('Legacy capture could not be cleared: $error');
      if (!mounted) return;
      setState(() {
        _setupError =
            'The previous capture could not be cleared, so the 38-point '
            'capture was not started: ${readableFailure(error, fallback: 'storage error')}';
        _preparing = false;
      });
    }
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

  /// Resumes an interrupted draft workflow after the app was closed with all
  /// 38 originals on disk.
  ///
  /// The device panorama is canonical, so the resume order mirrors the fresh
  /// capture: if the previous launch already stitched the panorama, that file
  /// becomes the draft; if it never got to stitch, the same on-device
  /// pipeline runs here first. Every not-yet-confirmed photograph (including
  /// any captured before the queue existed) is reconciled into the queue,
  /// which then drains in the background. Nothing is re-captured and the
  /// server is never asked to stitch.
  Future<void> _resumeDraftFlow(
    List<CapturedFrame> restoredFrames,
    CaptureSession? restoredSession,
  ) async {
    final tourId = _tourId;
    final sessions = _sessions;
    final repository = _repository;
    if (tourId == null || sessions == null || repository == null) return;
    final propertyId = int.tryParse(widget.request.propertyId);
    final saved = await sessions.getSession(tourId);
    if (saved?.requiredTargetCount == 56) {
      await _completeEnhanced();
      return;
    }

    // Recovery never re-uploads what the backend already confirmed.
    var frames = restoredFrames;
    if (frames.isEmpty) {
      frames = await sessions.loadFrames(tourId);
    }
    await _uploadQueue?.reconcileFrames(frames, propertyId: propertyId);

    final stitched = restoredSession?.localPanoramaPath;
    if (stitched != null &&
        stitched.isNotEmpty &&
        await File(stitched).exists()) {
      _panoramaPath = stitched;
      await _savePanoramaDraft(stitched);
      return;
    }
    if (mounted) {
      setState(() {
        _handoffStage = BackendHandoffStage.processing;
        _processed = _requiredTargetCount;
        _total = _requiredTargetCount;
        _processingPercent = null;
        _failure = null;
        _failureKind = null;
      });
    }
    try {
      final records = await repository.loadRecords(tourId);
      final result =
          await const PanoramaGenerationService(
            EquirectangularStitcher(),
          ).generate(
            records: records,
            total: kSphereTargetCount,
            onStage: (String stage) {
              // Diagnostic only. The stitcher's stage wording ("Matching
              // overlaps: 12/38 pairs") is image-processing jargon; it is
              // logged and the screen keeps one plain sentence.
              CaptureLog.log('STITCH_STAGE: $stage');
            },
          );
      if (!result.success || result.panoramaPath == null) {
        if (mounted) {
          setState(() {
            _handoffStage = null;
            _processingPercent = null;
            _failureKind = 'stitch';
            _failure =
                'We couldn\u2019t create your panorama. Your 38 photographs '
                'are saved.';
          });
        }
        return;
      }
      _panoramaPath = result.panoramaPath;
      await sessions.savePanorama(
        sessionId: tourId,
        localPanoramaPath: result.panoramaPath,
        status: PanoramaGenerationStatus.ready,
        error: null,
      );
    } on Object catch (error, stack) {
      CaptureLog.log('Device stitch on resume failed: $error');
      CaptureLog.log('Device stitch on resume stack: $stack');
      if (mounted) {
        setState(() {
          _handoffStage = null;
          _processingPercent = null;
          _failureKind = 'stitch';
          _failure =
              'We couldn\u2019t create your panorama. Your 38 photographs '
              'are saved.';
        });
      }
      return;
    }
    await _savePanoramaDraft(_panoramaPath!);
  }

  /// The device panorama exists on disk. This is the draft trigger:
  ///
  ///   Layer A — the LOCAL draft is persisted (the controller already wrote
  ///   the session store; the tour record gets the path and the ready
  ///   status here, so reopening the property finds it);
  ///   Layer B — the panorama joins the upload queue, which syncs it to
  ///   Supabase and confirms it through FastAPI in the background;
  /// The completed capture returns to the inspection while the queue runs.
  Future<void> _completeEnhanced() async {
    if (_draftRunning) return;
    final queue = _uploadQueue;
    final sessions = _sessions;
    final id = _tourId;
    if (queue == null || sessions == null || id == null) return;
    final future = () async {
      try {
        if (mounted) {
          setState(() {
            _resumedComplete = true;
            _handoffStage = BackendHandoffStage.processing;
            _failure = null;
            _failureKind = null;
            _processed = _requiredTargetCount;
            _total = _requiredTargetCount;
          });
        }
        await queue.reconcileFrames(await sessions.loadFrames(id),
          propertyId: int.tryParse(widget.request.propertyId));
        await queue.resume();
        final saved = await sessions.getSession(id);
        if (saved?.panoramaSyncStatus != FrameSyncStatus.ready ||
            saved?.hasPanorama != true ||
            !await File(saved!.localPanoramaPath!).exists()) {
          throw StateError('Panorama is not ready.');
        }
        if (mounted) setState(() => _handoffStage = BackendHandoffStage.ready);
        _returnAfterCapture();
      } on Object catch (error) {
        CaptureLog.log('Enhanced capture could not finish: $error');
        if (mounted) {
          setState(() {
            _failure = 'Your photos are saved. Retry to finish the panorama.';
            _failureKind = 'upload';
            _handoffStage = null;
          });
        }
      }
    }();
    _draftFuture = future;
    try { await future; } finally {
      if (identical(_draftFuture, future)) _draftFuture = null;
      if (mounted) setState(() {});
    }
  }

  Future<void> _onPanoramaReady(String panoramaPath) async {
    _panoramaPath = panoramaPath;
    if (_draftFuture != null || !MobileConfig.usesLiveApi) return;
    final future = _savePanoramaDraft(panoramaPath);
    _draftFuture = future;
    unawaited(
      future.whenComplete(() {
        if (identical(_draftFuture, future)) _draftFuture = null;
      }),
    );
    await future;
  }

  Future<void> _savePanoramaDraft(String panoramaPath) async {
    final tourId = _tourId;
    if (tourId == null) return;
    final propertyId = int.tryParse(widget.request.propertyId);
    if (propertyId == null) {
      if (mounted) {
        setState(() {
          _failure =
              'The property draft must be saved before the panorama can be '
              'attached to it. Your photographs and the panorama are kept '
              'on this device.';
        });
      }
      return;
    }
    if (mounted) {
      setState(() {
        _failure = null;
        _failureKind = null;
        _processingPercent = null;
        _handoffStage = BackendHandoffStage.captured;
        _processed = _requiredTargetCount;
        _total = _requiredTargetCount;
      });
    }

    // Layer A — attach the draft to the tour record so the property detail
    // and the preview both find it after leaving this screen.
    try {
      final tour = await ServiceLocator.tourRepo.tourById(tourId);
      if (tour != null &&
          (tour.panoramaPath != panoramaPath ||
              tour.status != VirtualTourStatus.ready)) {
        await ServiceLocator.tourRepo.updateTour(
          tour.copyWith(
            panoramaPath: panoramaPath,
            status: VirtualTourStatus.ready,
          ),
        );
      }
    } on Object catch (error) {
      CaptureLog.log('Tour draft could not record the panorama: $error');
    }

    // Enqueue persists the upload record and starts the background worker.
    try {
      await _uploadQueue?.enqueuePanorama(panoramaPath, propertyId: propertyId);
      _uploadQueue?.resumeInBackground();
    } on Object catch (error) {
      CaptureLog.log('Saved panorama could not be queued: $error');
    }

    _returnAfterCapture();
  }

  /// The per-photograph upload hook: fired by the capture controller after
  /// each JPEG is safely on disk. Queueing is fire-and-forget — a slow
  /// network never blocks the next capture target.
  void _onFrameSaved(CapturedFrame frame) {
    final queue = _uploadQueue;
    if (queue == null) return;
    final propertyId = int.tryParse(widget.request.propertyId);
    unawaited(
      queue
          .enqueueFrame(frame, propertyId: propertyId)
          .catchError(
            (Object error) =>
                CaptureLog.log('Saved photo could not be queued: $error'),
          ),
    );
  }

  void _returnAfterCapture() {
    if (_returnedAfterCapture ||
        !mounted ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    _returnedAfterCapture = true;
    final navigator = Navigator.of(context);
    if (navigator.canPop()) {
      navigator.pop(true);
    } else {
      navigator.pushReplacementNamed(
        '/provider/inspection',
        arguments: widget.request.propertyId,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final repository = _repository;
    if (_setupError != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('360° capture')),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.threesixty_outlined, size: 48),
              const SizedBox(height: 12),
              Text(_setupError!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              SitewiseButton(
                label: 'Back',
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
      );
    }
    if (_preparing || repository == null || _sessions == null) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator()),
      );
    }

    // A completed capture, an active handoff, a finished tour and a retryable
    // failure all share one honest progress screen. It replaces the camera
    // once the device panorama is ready for upload; stitching progress
    // itself is shown by the capture screen's completion overlay.
    if (_resumedComplete || _handoffStage != null || _failure != null) {
      return _HandoffStatusScreen(
        stage: _handoffStage,
        processed: _processed,
        total: _total,
        percent: _processingPercent,
        failure: _failure,
        failureKind: _failureKind,
        onRetry: _draftRunning || !MobileConfig.usesLiveApi
            ? null
            : _panoramaPath == null
            ? () => unawaited(_resumeDraftFlow(const <CapturedFrame>[], null))
            : () => unawaited(_onPanoramaReady(_panoramaPath!)),
        onView: _draftRunning ? null : _returnAfterCapture,
        onBack: _draftRunning ? null : () => Navigator.of(context).pop(),
      );
    }

    // Pre-capture instruction screen from the existing AR guide. The host
    // remains mounted so property, tour and frame-session state stay intact.
    if (!_guideCompleted) {
      return CaptureGuideScreen(
        allowEnhanced: MobileConfig.usesLiveApi && _uploadQueue != null,
        onStartCapturePlan: (count) => unawaited(_selectPlan(count)),
      );
    }
    return SphereCaptureScreen(
      autoStart: true,
      requiredTargetCount: _requiredTargetCount,
      sessionId: _tourId,
      repository: repository,
      sessions: _sessions,
      // The device stitches the canonical panorama; the draft is saved and
      // the cloud sync starts the moment the stitch completes.
      backendProcessing: _requiredTargetCount == 56,
      onCaptureComplete: () => unawaited(_completeEnhanced()),
      onPanoramaReady: _onPanoramaReady,
      // Every photograph is queued for Supabase upload the moment it lands.
      onFrameSaved: _onFrameSaved,
      // Quality warnings are shown in the capture UI; only the agent retakes.
      qualityAnalyzer: _qualityAnalyzer,
    );
  }
}

/// The user-facing progression for the backend handoff. Every message is a
/// complete sentence the app can show without translating a server exception.
class _HandoffStatusScreen extends StatelessWidget {
  const _HandoffStatusScreen({
    required this.stage,
    required this.processed,
    required this.total,
    this.percent,
    this.failure,
    this.failureKind,
    this.onRetry,
    this.onView,
    this.onBack,
  });

  final BackendHandoffStage? stage;
  final int processed;
  final int total;
  final int? percent;
  final String? failure;

  /// `'stitch'` or `'upload'` — decides the recovery offered: a stitch
  /// failure retries the on-device pipeline (originals untouched), an upload
  /// failure retries the handoff (the panorama is already on disk).
  final String? failureKind;

  final VoidCallback? onRetry;
  final VoidCallback? onView;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ready = stage == BackendHandoffStage.ready;
    final failed = failure != null;
    final working = !ready && !failed;
    final stitchFailed = failed && failureKind == 'stitch';

    final String title;
    final String message;
    if (ready) {
      title = 'Your 360° panorama is ready';
      message =
          'Your panorama is saved in SiteWise, and your '
          'original photographs are backed up.';
    } else if (failed) {
      title = stitchFailed
          ? 'Creating your 360° panorama failed'
          : 'Upload failed';
      message = failure!;
    } else if (stage == BackendHandoffStage.processing) {
      title = 'Creating your 360° panorama';
      message =
          'Your $total photographs are being stitched into one panorama '
          'for your property.';
    } else if (stage == BackendHandoffStage.panoramaUploading) {
      title = 'Uploading your 360° panorama';
      message =
          'The finished panorama is sent to Sitewise first, so the tour is '
          'ready for review as soon as possible.';
    } else if (stage == BackendHandoffStage.framesBackingUp) {
      title = 'Backing up your original photos';
      message = '$processed of $total photos backed up';
    } else {
      title = '$total of $total photos captured';
      message = 'Your photographs are safely saved on this device.';
    }

    final double? progressValue;
    if (ready) {
      progressValue = 1;
    } else if (failed ||
        stage == BackendHandoffStage.processing ||
        stage == BackendHandoffStage.panoramaUploading) {
      progressValue = null;
    } else {
      progressValue = total == 0 ? 0 : (processed / total).clamp(0.0, 1.0);
    }

    return Scaffold(
      appBar: AppBar(title: const Text('360° capture')),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(
                    failed
                        ? stitchFailed
                              ? Icons.image_not_supported_outlined
                              : Icons.cloud_off_outlined
                        : ready || stage == BackendHandoffStage.processing
                        ? Icons.threesixty
                        : Icons.cloud_upload_outlined,
                    size: 64,
                    color: failed
                        ? theme.colorScheme.error
                        : theme.colorScheme.primary,
                  ),
                  const SizedBox(height: 24),
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    message,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(
                        alpha: 0.78,
                      ),
                    ),
                  ),
                  if (working) ...[
                    const SizedBox(height: 28),
                    LinearProgressIndicator(
                      value: progressValue,
                      minHeight: 8,
                      backgroundColor:
                          theme.colorScheme.surfaceContainerHighest,
                      color: theme.colorScheme.primary,
                      semanticsLabel: 'Capture progress',
                    ),
                    const SizedBox(height: 12),
                    Text(
                      stage == BackendHandoffStage.framesBackingUp
                          ? '$processed of $total photos backed up'
                          : stage == BackendHandoffStage.processing
                          ? 'Creating the 360° panorama'
                          : 'Sending to Sitewise',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 20),
                    const Center(
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  ],
                  if (ready) ...[
                    const SizedBox(height: 32),
                    SitewiseButton(
                      label: 'Back to Property Inspection',
                      icon: Icons.arrow_back_rounded,
                      onPressed: onView,
                    ),
                  ],
                  if (failed && onRetry != null) ...[
                    const SizedBox(height: 32),
                    SitewiseButton(
                      label: stitchFailed ? 'Retry Stitching' : 'Retry Handoff',
                      icon: Icons.refresh,
                      onPressed: onRetry,
                    ),
                  ],
                  if (failed && onBack != null) ...[
                    const SizedBox(height: 12),
                    SitewiseSecondaryButton(
                      label: 'Back to Property',
                      icon: Icons.arrow_back_rounded,
                      onPressed: onBack,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
