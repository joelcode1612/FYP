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
import 'package:fyp/core/errors/failures.dart';
import 'package:fyp/core/utils/capture_log.dart';
// The handoff stage enum is shared with the preview; the upload work itself
// now flows through [FrameUploadQueue].
import 'package:fyp/features/capture_360/application/backend_capture_coordinator.dart'
    show BackendCaptureCoordinator, BackendHandoffStage;
import 'package:fyp/features/capture_360/application/capture_panorama_generation_service.dart';
import 'package:fyp/features/capture_360/application/frame_upload_queue.dart';
import 'package:fyp/features/capture_360/data/repositories/sitewise_capture_repository.dart';
import 'package:fyp/features/capture_360/data/sphere/equirectangular_stitcher.dart';
import 'package:fyp/features/capture_360/data/sphere/sitewise_sphere_session_store.dart';
import 'package:fyp/features/capture_360/domain/sphere/sphere_capture_session.dart';
import 'package:fyp/features/capture_360/domain/sphere/sphere_target.dart';
import 'package:fyp/features/capture_360/guide/presentation/screens/capture_guide_screen.dart';
import 'package:fyp/features/capture_360/presentation/sphere/screens/panorama_candidate_review_screen.dart';
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

  String? _tourId;

  /// The capture station inside the tour. Normally the tour id; after an
  /// explicit recovery it is a fresh sibling so the incompatible station can
  /// be archived intact.
  String? _stationId;
  bool _preparing = true;
  bool _guideCompleted = false;
  bool _resumedComplete = false;
  Future<void>? _draftFuture;

  BackendHandoffStage? _handoffStage;
  int _processed = 0;
  int _total = kSphereTargetCount;
  int _requiredTargetCount = kSphereTargetCount;
  int _planVersion = kSphereCapturePlanVersion;
  bool _selectingPlan = false;
  int? _processingPercent;

  /// The honest sentence for the current backend stage. Never a percentage:
  /// the worker reports stages, not progress within a stage.
  String? _statusLine;
  String? _failure;
  String? _setupError;
  bool _setupCanStartFresh = false;
  bool _freshStartInProgress = false;

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

  /// Whether this capture's panorama comes from the backend worker. Plan-driven
  /// versions (4, 5, 6, 7, 8) and the retired 56-target plan do; only the
  /// retired 38-target plan still stitches on the device.
  bool get _isBackendStitched =>
      (_planVersion == kSphereEnhancedPlanVersion &&
          _requiredTargetCount == 56) ||
      planIsBackendStitched(_planVersion);

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
      // A recovered capture lives in a fresh sibling station. Read the pointer
      // BEFORE constructing the store so a reopened app resumes the current
      // attempt, never the archived one.
      final stationId = await SitewiseSphereSessionStore.stationIdForTour(
        frameStore: frameStore,
        tourId: tour.id,
      );

      // Engine check before anything opens: records without a session marker
      // were written by the retired 26-point flow and must not be resumed as a
      // 38-point session. A station the sphere flow has never touched (no
      // records at all) just starts normally.
      final isSphereEngine = await SitewiseSphereSessionStore.hasSessionMarker(
        frameStore: frameStore,
        tourId: tour.id,
        stationId: stationId,
      );
      if (!isSphereEngine) {
        final legacyRecords = await SiteWiseCaptureRepository(
          tourId: tour.id,
          frameStore: frameStore,
        ).loadRecords(stationId);
        if (legacyRecords.isNotEmpty) {
          if (!mounted) return;
          final restart = await showSitewiseConfirmDialog(
            context,
            title: 'Start the capture over?',
            message:
                'This tour was captured with the previous 26-point flow, which '
                'this app no longer runs. Its ${legacyRecords.length} saved '
                'photographs cannot be finished into a panorama. '
                'Start over deletes them and captures all $kSphereTargetCount points; Cancel '
                'keeps everything exactly as it is.',
            confirmLabel: 'Start over',
            destructive: true,
          );
          if (!restart) {
            if (!mounted) return;
            Navigator.of(context).pop();
            return;
          }
          await _purgeLegacyCapture(tour.id, stationId: stationId);
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
        stationId: stationId,
      );
      // The durable per-photograph upload queue. One instance per station,
      // created before the camera starts so the FIRST photograph is already
      // queued before the second is shot. Quality verification is the
      // backend worker's job: the capture loop stays camera-only, which is
      // what keeps the UI isolate free of decode work.
      final uploadQueue = MobileConfig.usesLiveApi
          ? FrameUploadQueue.forTour(
              frameStore: frameStore,
              tourId: tour.id,
              stationId: stationId,
            )
          : null;

      // Publish the tour/station identity BEFORE reading saved metadata. An
      // incompatible saved plan must be recoverable by archiving this exact
      // station; if these fields stayed null until a successful read, the
      // recovery button could never be offered.
      _tourId = tour.id;
      _stationId = stationId;
      _repository = repository;
      _sessions = sessions;
      _uploadQueue = uploadQueue;

      // App-closed recovery: if all originals are already on disk, do not open
      // the camera or re-run the guide. The resume path saves the panorama
      // draft (stitching first if the previous launch never got to it), then
      // the queue resumes the remaining uploads.
      final restoredFrames = isSphereEngine
          ? await sessions.loadFrames(stationId)
          : const <CapturedFrame>[];
      final restoredSession = isSphereEngine
          ? await sessions.getSession(stationId)
          : null;
      final int count;
      final int version;
      try {
        count = restoredSession?.requiredTargetCount ?? kSphereTargetCount;
        version =
            restoredSession?.capturePlanVersion ?? kSphereCapturePlanVersion;
        if (!planVersionMatchesCount(version, count)) {
          throw StateError('Saved plan version and target count do not match.');
        }
      } on Object catch (error) {
        // Unsupported/legacy count: the frames must not be reinterpreted under
        // the current 44-target geometry. Offer the same explicit recovery as
        // an unreadable session.json.
        throw IncompatibleCaptureSessionFailure(
          'The saved capture plan for this station cannot be used. '
          'Your photographs are kept. ${readableFailure(error, fallback: 'unsupported plan')}',
        );
      }
      if (isSphereEngine &&
          restoredSession == null &&
          restoredFrames.isNotEmpty) {
        throw const IncompatibleCaptureSessionFailure(
          'Saved photographs have no capture plan. Your photographs are kept; '
          'start a new capture to leave this attempt intact.',
        );
      }
      final savedIds = <int>{};
      for (final frame in restoredFrames) {
        if (frame.targetId < 1 ||
            frame.targetId > count ||
            !savedIds.add(frame.targetId)) {
          throw const IncompatibleCaptureSessionFailure(
            'Saved photographs do not match the capture plan. Your '
            'photographs are kept; start a new capture to leave this attempt '
            'intact.',
          );
        }
      }
      final present = restoredFrames
          .where((f) => File(f.imagePath).existsSync())
          .length;
      final shouldResume = MobileConfig.usesLiveApi && present == count;

      if (!mounted) return;
      setState(() {
        _tourId = tour.id;
        _stationId = stationId;
        _repository = repository;
        _sessions = sessions;
        _uploadQueue = uploadQueue;
        _requiredTargetCount = count;
        _planVersion = version;
        _total = count;
        _guideCompleted = restoredSession != null;
        _resumedComplete = shouldResume;
        _preparing = false;
      });

      if (shouldResume) {
        // A backend-stitched session's panorama is downloaded to disk, so
        // "ready" is only trustworthy while that file still exists. The legacy
        // 38-target flow re-stitches instead, and has no downloaded artifact to
        // check.
        final backendStitched =
            (version == kSphereEnhancedPlanVersion && count == 56) ||
            planIsBackendStitched(version);
        if (restoredSession?.syncStatus == FrameSyncStatus.ready &&
            restoredSession?.panoramaSyncStatus == FrameSyncStatus.ready &&
            (!backendStitched ||
                (restoredSession?.localPanoramaPath != null &&
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
      CaptureLog.log('Capture preparation failed: $error');
      if (!mounted) return;
      setState(() {
        _setupError = readableFailure(
          error,
          fallback: 'The capture session could not be prepared.',
        );
        _setupCanStartFresh =
            error is IncompatibleCaptureSessionFailure &&
            _tourId != null &&
            _stationId != null &&
            _sessions != null &&
            _repository != null;
        _preparing = false;
      });
    }
  }

  /// Explicit recovery: archive the incompatible station intact, then rebuild
  /// the capture screen against a fresh station in the same tour. No photo,
  /// manifest, panorama, session row or Supabase object is deleted.
  Future<void> _startFreshCapture() async {
    if (_freshStartInProgress) return;
    final tourId = _tourId;
    final sessions = _sessions;
    final repository = _repository;
    if (tourId == null || sessions == null || repository == null) return;
    setState(() => _freshStartInProgress = true);
    try {
      final archive = await sessions.archiveStation(
        reason: 'unreadable-session',
      );
      CaptureLog.log('Previous capture station archived at $archive');
      final freshStationId = 'sphere-${DateTime.now().millisecondsSinceEpoch}';
      final frameStore = ServiceLocator.frameStore;
      final freshSessions = SitewiseSphereSessionStore(
        frameStore: frameStore,
        tourId: tourId,
        stationId: freshStationId,
      );
      // Record the fresh station BEFORE any session exists, so a restart after
      // this point reopens the new attempt instead of the archived one. This
      // is a pointer write; nothing is deleted.
      await freshSessions.markActiveStation();
      setState(() {
        _stationId = freshStationId;
        _sessions = freshSessions;
        _uploadQueue = MobileConfig.usesLiveApi
            ? FrameUploadQueue.forTour(
                frameStore: frameStore,
                tourId: tourId,
                stationId: freshStationId,
              )
            : null;
        _setupError = null;
        _setupCanStartFresh = false;
        _failure = null;
        _failureKind = null;
        _resumedComplete = false;
        _handoffStage = null;
        _guideCompleted = false;
        _panoramaPath = null;
        _returnedAfterCapture = false;
        _requiredTargetCount = kSphereTargetCount;
        _planVersion = kSphereCapturePlanVersion;
        _total = kSphereTargetCount;
        _preparing = false;
      });
    } on Object catch (error) {
      CaptureLog.log('Could not archive the previous station: $error');
      if (mounted) {
        setState(() {
          _setupError =
              'The previous capture could not be archived, so nothing was '
              'changed: ${readableFailure(error, fallback: 'storage error')}';
        });
      }
    } finally {
      if (mounted) setState(() => _freshStartInProgress = false);
    }
  }

  Future<void> _beginCapture() async {
    if (_selectingPlan || _guideCompleted) return;
    final sessions = _sessions;
    // After explicit recovery the station is a fresh sibling; keep the
    // session id equal to the station directory so the saved plan, the frame
    // rows and the upload queue all describe the same attempt.
    final id = _stationId ?? _tourId;
    if (sessions == null || id == null) return;
    setState(() => _selectingPlan = true);
    try {
      // Every new session runs the ONE canonical adaptive five-ring plan:
      // 36 primary targets on the 0°/±30° rings plus 8 polar targets at
      // ±65°, with target ids equal to the connected-sector capture order.
      // The retired plan-version selection (V4/V11/26/30/38/56) is gone;
      // historical sessions are restored from their persisted plan metadata
      // and are never re-planned.
      final count = kSphereTargetCount;
      final version = sitewisePlanVersionForCount(count);
      // The saved session is authoritative, even if it has zero frames.
      final saved = await sessions.createSession(
        sessionId: id,
        propertyId: int.tryParse(widget.request.propertyId),
        requiredTargetCount: count,
      );
      if (!mounted) return;
      setState(() {
        _requiredTargetCount = saved.requiredTargetCount;
        _planVersion = saved.capturePlanVersion;
        _total = saved.requiredTargetCount;
        _guideCompleted = true;
      });
      // Defensive: the store derives the version for a 44-target session, so
      // it must be the canonical plan. If a future store change breaks that,
      // fail loudly here rather than capturing against unexpected geometry.
      if (_planVersion != version) {
        throw StateError(
          'The session store saved plan $_planVersion for a new capture; '
          'expected the canonical plan $version.',
        );
      }
    } on Object catch (error) {
      CaptureLog.log('Capture plan could not be saved: $error');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not save the capture plan. Please try again.'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _selectingPlan = false);
    }
  }

  /// Deletes the legacy 26-point station and its manifest mirror, so the
  /// 38-point flow starts from an empty directory. Only the station subtree is
  /// removed — the tour record and anything else in the tour directory stay.
  Future<void> _purgeLegacyCapture(
    String tourId, {
    required String stationId,
  }) async {
    try {
      final root = await ServiceLocator.frameStore.tourRoot(tourId);
      final stationDir = Directory(p.join(root, 'ar_capture', stationId));
      if (await stationDir.exists()) {
        await stationDir.delete(recursive: true);
      }
      await ServiceLocator.frameStore.saveManifest(
        tourId,
        const <int, manifest.CapturedFrame>{},
      );
      CaptureLog.log(
        'Legacy 26-point capture cleared for station $stationId in tour $tourId',
      );
    } catch (error) {
      CaptureLog.log('Legacy capture could not be cleared: $error');
      if (!mounted) return;
      setState(() {
        _setupError =
            'The previous capture could not be cleared, so the '
            '$kSphereTargetCount-point capture was not started: ${readableFailure(error, fallback: 'storage error')}';
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
    final stationId = _stationId ?? tourId;
    final propertyId = int.tryParse(widget.request.propertyId);
    final saved = await sessions.getSession(stationId);
    // Adaptive and 56-target sessions are stitched by the backend worker from
    // the originals. A resumed one must go straight back to waiting on that
    // job: stitching locally would produce a second, different panorama and
    // the panorama endpoint refuses it for these modes anyway.
    final planVersion =
        saved?.capturePlanVersion ??
        restoredSession?.capturePlanVersion ??
        _planVersion;
    if ((saved?.requiredTargetCount ?? restoredSession?.requiredTargetCount) ==
                56 &&
            planVersion == kSphereEnhancedPlanVersion ||
        planIsBackendStitched(planVersion)) {
      await _completeEnhanced();
      return;
    }

    // Recovery never re-uploads what the backend already confirmed.
    var frames = restoredFrames;
    if (frames.isEmpty) {
      frames = await sessions.loadFrames(stationId);
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
      final records = await repository.loadRecords(stationId);
      final result =
          await const PanoramaGenerationService(
            EquirectangularStitcher(),
          ).generate(
            records: records,
            total: saved?.requiredTargetCount ?? kSphereTargetCount,
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
                'We couldn\u2019t create your panorama. Your photographs are saved.';
          });
        }
        return;
      }
      _panoramaPath = result.panoramaPath;
      await sessions.savePanorama(
        sessionId: stationId,
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
              'We couldn\u2019t create your panorama. Your photographs are saved.';
        });
      }
      return;
    }
    await _savePanoramaDraft(_panoramaPath!);
  }

  /// The capture engine reports every planned photograph durable. Plan-driven
  /// sessions go straight to the backend handoff; the retired 38-target plan
  /// still finishes through the legacy device stitch on the saved originals.
  Future<void> _onCaptureEngineComplete() async {
    if (_isBackendStitched) {
      await _completeEnhanced();
      return;
    }
    final sessions = _sessions;
    final id = _stationId ?? _tourId;
    if (sessions == null || id == null) return;
    await _resumeDraftFlow(
      await sessions.loadFrames(id),
      await sessions.getSession(id),
    );
  }

  /// The backend handoff driver for a completed plan-driven capture.
  ///
  /// This used to call `queue.resume()` and then *immediately* check
  /// `panoramaSyncStatus` / `hasPanorama` / the local file. `resume()` only
  /// starts the drain, so the check ran before anything had happened and the
  /// screen fell through to "Retry Handoff" — while the backend was working
  /// perfectly. Worse, the old `finishEnhanced` polled for six minutes inside
  /// the drain and then threw, so a slow-but-healthy job always ended in that
  /// same failure.
  ///
  /// The handoff is now driven by [FrameUploadQueue.completeHandoff], which
  /// reports the real stage and returns `pending` — not `failed` — while the
  /// worker is still processing. Only a genuine failure reaches the Retry
  /// action, and that action resumes the same job rather than creating a new
  /// one.
  Future<void> _completeEnhanced() async {
    if (_draftRunning) return;
    final queue = _uploadQueue;
    final sessions = _sessions;
    final id = _stationId ?? _tourId;
    if (queue == null || sessions == null || id == null) return;
    final future = () async {
      try {
        if (mounted) {
          setState(() {
            _resumedComplete = true;
            _handoffStage = BackendHandoffStage.processing;
            _failure = null;
            _failureKind = null;
            _statusLine = 'Preparing your photographs…';
            _processed = _requiredTargetCount;
            _total = _requiredTargetCount;
          });
        }
        await queue.reconcileFrames(
          await sessions.loadFrames(id),
          propertyId: int.tryParse(widget.request.propertyId),
        );
        // Up to three follow passes. A pass returns `pending` when the worker
        // is still running, which is a normal state, not an error: pause and
        // follow the same job again. Nothing here creates a second job, and
        // nothing here reports a failure for a job that is merely slow.
        for (var pass = 0; pass < 3; pass++) {
          if (!mounted) return;
          final outcome = await queue.completeHandoff(
            onStage: (stage, message) {
              if (!mounted) return;
              setState(() {
                _handoffStage = BackendHandoffStage.processing;
                _statusLine = message;
              });
            },
          );
          if (outcome.ready) {
            if (mounted) {
              setState(() {
                _handoffStage = BackendHandoffStage.ready;
                _statusLine = 'Review your new panorama…';
                _panoramaPath = outcome.localPath;
              });
            }
            final propertyId = int.tryParse(widget.request.propertyId);
            if (propertyId == null ||
                outcome.localPath == null ||
                outcome.localPath!.isEmpty ||
                outcome.panoramaId == null ||
                outcome.panoramaId!.isEmpty ||
                outcome.sessionId == null ||
                outcome.sessionId!.isEmpty) {
              _returnAfterCapture();
              return;
            }
            await _reviewCandidate(
              sessionId: outcome.sessionId!,
              propertyId: propertyId,
              candidatePath: outcome.localPath!,
              candidatePanoramaId: outcome.panoramaId!,
              qualityStatus: outcome.verificationStatus,
            );
            return;
          }
          if (outcome.pending) {
            if (mounted) {
              setState(() => _statusLine = outcome.message ?? _statusLine);
            }
            if (pass < 2) {
              await Future<void>.delayed(const Duration(seconds: 20));
              continue;
            }
            // Still running after the follow budget: keep the screen in its
            // working state with the honest message. The user can leave and
            // come back — the job is durable and the preview resumes it.
            if (mounted) {
              setState(() {
                _handoffStage = BackendHandoffStage.processing;
                _statusLine =
                    'Your panorama is still being created. You can leave this '
                    'screen — it will be here when you come back.';
              });
            }
            return;
          }
          // A genuine failure.
          if (mounted) {
            setState(() {
              _failure =
                  outcome.message ?? 'The panorama could not be created.';
              _failureKind = 'upload';
              _handoffStage = null;
              _statusLine = null;
            });
          }
          return;
        }
      } on Object catch (error) {
        CaptureLog.log('Enhanced capture could not finish: $error');
        if (mounted) {
          setState(() {
            _failure = 'Your photos are saved. Retry to finish the panorama.';
            _failureKind = 'upload';
            _handoffStage = null;
            _statusLine = null;
          });
        }
      }
    }();
    _draftFuture = future;
    try {
      await future;
    } finally {
      if (identical(_draftFuture, future)) _draftFuture = null;
      if (mounted) setState(() {});
    }
  }

  Future<String?> _activePanoramaId(int propertyId) async {
    try {
      final response = await ServiceLocator.apiClient.get(
        '/api/v1/provider-flow/properties/$propertyId/inspection',
      );
      final data = response['data'];
      if (data is Map && data['panorama_id'] is String) {
        final id = (data['panorama_id'] as String).trim();
        return id.isEmpty ? null : id;
      }
    } on Object catch (error) {
      CaptureLog.log('Active panorama lookup failed: $error');
    }
    return null;
  }

  /// Shows the interactive candidate preview. Viewing never activates the
  /// candidate; only the explicit Use this panorama action does.
  Future<void> _reviewCandidate({
    required String sessionId,
    required int propertyId,
    required String candidatePath,
    required String candidatePanoramaId,
    String? qualityStatus,
  }) async {
    final sessions = _sessions;
    if (sessions == null) return;
    final activeId = await _activePanoramaId(propertyId);
    if (!mounted) return;
    final accepted = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => PanoramaCandidateReviewScreen(
          candidatePath: candidatePath,
          candidatePanoramaId: candidatePanoramaId,
          sessionId: sessionId,
          activePanoramaId: activeId,
          qualityStatus: qualityStatus,
          onConfirm: () async {
            final coordinator = BackendCaptureCoordinator(
              client: ServiceLocator.apiClient,
              store: sessions,
            );
            await coordinator.acceptPanoramaCandidate(
              sessionId: sessionId,
              panoramaId: candidatePanoramaId,
              expectedActivePanoramaId: activeId,
            );
            // Only after the backend committed the active reference does the
            // local draft pointer move to the accepted file.
            final tour = await ServiceLocator.tourRepo.tourById(_tourId ?? '');
            if (tour != null) {
              await ServiceLocator.tourRepo.updateTour(
                tour.copyWith(
                  panoramaPath: candidatePath,
                  status: VirtualTourStatus.ready,
                ),
              );
            }
            await sessions.savePanorama(
              sessionId: sessionId,
              localPanoramaPath: candidatePath,
              status: PanoramaGenerationStatus.ready,
              error: null,
            );
          },
          onCancel: () async {
            final coordinator = BackendCaptureCoordinator(
              client: ServiceLocator.apiClient,
              store: sessions,
            );
            await coordinator.cancelCaptureSession(sessionId);
            await _uploadQueue?.discardPanoramaCandidate();
            await sessions.savePanorama(
              sessionId: sessionId,
              localPanoramaPath: null,
              status: PanoramaGenerationStatus.failed,
              error: 'Recapture cancelled',
            );
          },
        ),
      ),
    );
    if (!mounted) return;
    // A back gesture also returns false: it leaves the candidate unconfirmed
    // and preserved, but still returns to the inspection screen.
    if (accepted == true || accepted == false) {
      _returnAfterCapture();
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

  /// Return to the inspection route after the saved panorama is ready.
  /// The inspection screen owns the review and submission workflow and reloads
  /// its persisted tour data when this route completes.
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
              if (_setupCanStartFresh) ...[
                SitewiseButton(
                  label: _freshStartInProgress
                      ? 'Archiving the old capture…'
                      : 'Start a new capture',
                  icon: Icons.camera_alt_outlined,
                  onPressed: _freshStartInProgress
                      ? null
                      : () => unawaited(_startFreshCapture()),
                ),
                const SizedBox(height: 12),
                SitewiseSecondaryButton(
                  label: 'Back',
                  icon: Icons.arrow_back_rounded,
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ] else
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
        statusLine: _statusLine,
        failure: _failure,
        failureKind: _failureKind,
        // A plan-driven capture retries by resuming the SAME backend job:
        // uploads that are already confirmed are skipped, and an existing
        // panorama is downloaded rather than generated again.
        onRetry: _draftRunning || !MobileConfig.usesLiveApi
            ? null
            : _isBackendStitched
            ? () => unawaited(_completeEnhanced())
            : _panoramaPath == null
            ? () => unawaited(_resumeDraftFlow(const <CapturedFrame>[], null))
            : () => unawaited(_onPanoramaReady(_panoramaPath!)),
        onView: _draftRunning ? null : _returnAfterCapture,
        onBack: _draftRunning ? null : () => Navigator.of(context).pop(),
      );
    }

    // Pre-capture instruction screen from the existing AR guide. The host
    // remains mounted so property, tour and frame-session state stay intact.
    // There is no plan selection: every new session runs the canonical
    // adaptive five-ring plan, so the guide starts the capture directly.
    if (!_guideCompleted) {
      return CaptureGuideScreen(
        showStartAction: true,
        onStartCapture: () => unawaited(_beginCapture()),
      );
    }
    final captureStationId = _stationId ?? _tourId;
    if (captureStationId == null) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator()),
      );
    }
    return SphereCaptureScreen(
      // A keyed rebuild guarantees an explicit new capture gets a NEW
      // controller instead of reusing the failed one and its subscriptions.
      key: ValueKey<String>('sphere-$captureStationId'),
      autoStart: true,
      planVersion: _planVersion,
      sessionId: captureStationId,
      repository: repository,
      sessions: _sessions,
      // Plan-driven captures hand off to the backend worker; the retired
      // 38-target plan still finishes through the legacy device stitch.
      onCaptureComplete: () => unawaited(_onCaptureEngineComplete()),
      // Every photograph is queued for Supabase upload the moment it lands.
      onFrameSaved: _onFrameSaved,
      // An unreadable saved plan is recovered explicitly here. The host
      // archives the old station before rebuilding this screen, so the
      // previous photographs and uploads remain intact.
      onStartNewCapture: () => unawaited(_startFreshCapture()),
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
    this.statusLine,
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

  /// The real backend stage ("Checking image connections…"). Shown instead of
  /// an invented percentage.
  final String? statusLine;
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
          statusLine ??
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
                      statusLine ??
                          (stage == BackendHandoffStage.framesBackingUp
                              ? '$processed of $total photos backed up'
                              : stage == BackendHandoffStage.processing
                              ? 'Creating the 360° panorama'
                              : 'Sending to Sitewise'),
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
