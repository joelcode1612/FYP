import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shared_logic/shared_logic.dart';
import 'package:flutter/foundation.dart';

import 'package:fyp/core/di/service_locator.dart';
import 'package:fyp/core/config/mobile_config.dart';
import 'package:fyp/core/utils/capture_log.dart';
import 'package:fyp/features/capture_360/data/capture_frame_store.dart';
import 'package:fyp/features/capture_360/application/capture_panorama_generation_service.dart';
import 'package:fyp/features/capture_360/data/repositories/sitewise_capture_repository.dart';
import 'package:fyp/features/capture_360/data/api_panorama_viewer_repository.dart';
import 'package:fyp/features/capture_360/application/backend_capture_coordinator.dart';
import 'package:fyp/features/capture_360/data/stitch/incremental_stitch_service.dart';
import 'package:fyp/features/capture_360/data/stitch/incremental_stitch_worker.dart';
import 'package:fyp/features/capture_360/domain/models/capture_record.dart';
import 'package:fyp/features/capture_360/domain/services/target_sphere.dart';
import 'package:fyp/features/capture_360/data/sphere/equirectangular_stitcher.dart';
import 'package:fyp/features/capture_360/data/sphere/sitewise_sphere_session_store.dart';
// Session/enum types only; `CapturedFrame` stays shared_logic's — the
// manifest mirror this view model reads is written in that shape.
import 'package:fyp/features/capture_360/domain/sphere/sphere_capture_session.dart' hide CapturedFrame;
import 'package:fyp/features/capture_360/domain/sphere/sphere_target.dart';

/// Preview/edit state for a captured tour. Loads the persisted frame
/// manifest and the capture records, keeps the incremental stitching verdicts
/// visible after the capture screen is gone (26-point legacy tours only),
/// regenerates the panorama after retakes, finishes an interrupted Sitewise
/// upload, submits for verification and deletes. Retakes clear one target's
/// record so the live capture session resumes at that direction with every
/// other frame kept.
///
/// Two capture engines can own a tour, and the preview follows the tour's
/// engine: the 38-direction sphere flow marks its sessions with a
/// `session.json` marker before the camera starts, so its tours show the 38
/// layout and regenerate through the sphere stitcher. A tour without the
/// marker was captured by the retired 26-point flow and keeps that flow's
/// layout, verifier and stitcher — nothing silently re-reads a 26-frame
/// station as a 38-frame one.

class TourPreviewViewModel extends ChangeNotifier {
  final String tourId;

  VirtualTour? tour;
  List<CapturedFrame> frames = [];
  List<CaptureRecord> records = const <CaptureRecord>[];
  bool loading = false;
  bool generating = false;
  String? stage;
  String? error;

  /// The capture directions the station was built from. The frame grid
  /// iterates these, not the saved frames, so a missing photograph is visible
  /// as a gap instead of silently shortening the list.
  List<CaptureTargetSpec> specs = buildCaptureSphere();

  /// Whether the 38-direction sphere flow owns this tour.
  bool _sphereEngine = false;

  /// The 38-point flow's own session store, for the backend handoff state and
  /// the saved frames a handoff retry reads. `null` unless this tour is a
  /// sphere-engine tour in a live build.
  SitewiseSphereSessionStore? _sphereSessions;

  /// The per-pair stitching verifier for this tour. The capture screen owns
  /// one while shooting; this one restores the persisted document so the
  /// review phase still shows what each frame registered against and what
  /// failed.
  IncrementalStitchService? stitchService;

  PanoramaUploadRecord? upload;

  /// The local handoff record for a 38-point tour in a live build: the sync
  /// status, the backend session/job ids and the last failure, exactly as the
  /// coordinator recorded them.
  CaptureSession? backendSession;

  /// The canonical panorama the backend stitched, when one exists. In a live
  /// build THIS is what the preview shows — the device-local file is the
  /// offline fallback, never a substitute for the backend result.
  CanonicalPanorama? canonical;

  /// Why the canonical state could not be read, when it could not. Kept
  /// separate from [error] so a metadata outage never masks the local review.
  String? canonicalError;

  TourPreviewViewModel({required this.tourId});

  SiteWiseCaptureRepository _repository() => SiteWiseCaptureRepository(
    tourId: tourId,
    frameStore: ServiceLocator.frameStore,
    onProgress: _syncFrameCount,
  );

  /// The tour record carries the real number of confirmed frames, so clearing
  /// one for a retake cannot leave the header claiming a complete sphere.
  void _syncFrameCount(int count) {
    unawaited(
      () async {
        try {
          final saved = await ServiceLocator.tourRepo.tourById(tourId);
          if (saved == null || saved.frameCount == count) return;
          await ServiceLocator.tourRepo.updateTour(
            saved.copyWith(frameCount: count, sceneCount: count),
          );
        } catch (error) {
          CaptureLog.log('Frame count could not be recorded: $error');
        }
      }(),
    );
  }

  Future<void> load() async {
    loading = true;
    error = null;
    notifyListeners();
    try {
      tour = await ServiceLocator.tourService.tourById(tourId);
      final repository = _repository();
      records = await repository.loadRecords(tourId);
      // The engine marker decides the layout and the stitcher. It is written
      // before the 38-flow's camera starts, so a station that holds records
      // but no marker is a legacy 26-point capture and keeps that flow's
      // behaviour below.
      _sphereEngine = await SitewiseSphereSessionStore.hasSessionMarker(
        frameStore: ServiceLocator.frameStore,
        tourId: tourId,
      );
      specs = _sphereEngine ? _sphereSpecs() : buildCaptureSphere();
      final manifest = await ServiceLocator.frameStore.loadManifest(tourId);
      final entries = manifest.entries.toList()
        ..sort((a, b) => a.key.compareTo(b.key));
      frames = [for (final e in entries) e.value];
      upload = await ServiceLocator.frameStore.loadPanoramaUpload(tourId);
      if (!_sphereEngine) _ensureStitchService(repository);
      if (_sphereEngine && MobileConfig.usesLiveApi) {
        _sphereSessions = SitewiseSphereSessionStore(
          frameStore: ServiceLocator.frameStore,
          tourId: tourId,
        );
        await _refreshBackendState();
      }
    } catch (e) {
      error = e.toString();
    }
    loading = false;
    notifyListeners();
  }

  /// The 38-direction layout mapped onto the preview's chip model. Ids,
  /// angles and ring names come straight from the capture flow's own target
  /// list, so the grid the user reviews is the grid they were guided through.
  static List<CaptureTargetSpec> _sphereSpecs() => <CaptureTargetSpec>[
    for (final SphereTargetSpec target in buildSphereTargets())
      CaptureTargetSpec(
        targetId: target.targetId,
        yawDegrees: target.yawDeg,
        pitchDegrees: target.pitchDeg,
        direction: target.direction,
        ringName: target.ringName,
        indexInRing: target.indexInRing,
        isPole: target.isZenith || target.isNadir,
        isZenith: target.isZenith,
        isNadir: target.isNadir,
      ),
  ];

  void _ensureStitchService(SiteWiseCaptureRepository repository) {
    if (stitchService != null || records.isEmpty) return;
    final service = IncrementalStitchService(
      stationId: tourId,
      resolveStationDir: () => _resolveStationDirectory(repository),
      loadRecords: () => repository.loadRecords(tourId),
      worker: runIncrementalStitchJob,
      onChanged: () {
        if (_disposed) return;
        notifyListeners();
      },
    );
    stitchService = service;
    unawaited(service.load());
  }

  /// The station directory, recovered from a saved record's frame path
  /// (`…/<stationId>/frames/tNN.jpg`), so the layout convention lives in one
  /// place. `null` while nothing is saved, which the service handles by
  /// deferring persistence.
  Future<String?> _resolveStationDirectory(
    SiteWiseCaptureRepository repository,
  ) async {
    for (final record in records) {
      final framesDir = p.dirname(record.imagePath);
      if (p.basename(framesDir) == 'frames') return p.dirname(framesDir);
    }
    final saved = await repository.loadRecords(tourId);
    for (final record in saved) {
      final framesDir = p.dirname(record.imagePath);
      if (p.basename(framesDir) == 'frames') return p.dirname(framesDir);
    }
    return null;
  }

  /// The saved photograph for one capture direction, `null` when that target
  /// was never captured. Keyed by the record, because the record is the
  /// evidence the file exists.
  CaptureRecord? recordFor(int targetId) {
    for (final record in records) {
      if (record.targetId == targetId) return record;
    }
    return null;
  }

  CapturedFrame? frameFor(int targetId) {
    for (final frame in frames) {
      if (frame.frameIndex == targetId - 1) return frame;
    }
    return null;
  }

  List<int> get missingTargetIds => <int>[
    for (final spec in specs)
      if (frameFor(spec.targetId) == null) spec.targetId,
  ];

  bool get hasPanorama => tour?.panoramaPath != null;

  /// True for a 38-point tour in a live build, where the backend handoff —
  /// not the legacy panorama upload record — decides what the Sitewise card
  /// and the panorama panel show. Demo builds and 26-point legacy tours keep
  /// the device-local behaviour untouched.
  bool get liveBackend => _sphereEngine && MobileConfig.usesLiveApi;

  /// True when the backend has a finished canonical panorama for this
  /// property, so the preview shows the backend result.
  bool get canonicalReady => liveBackend && canonical != null;

  /// What the Sitewise card should offer, mapped from the local handoff
  /// record and the canonical metadata onto the spec §14 states. The values
  /// follow the real lifecycle: a finished job is visible as canonical
  /// metadata, a failed handoff as the recorded failure, everything in
  /// between as work in progress.
  BackendHandoffUiState get handoffUiState {
    if (canonicalReady) return BackendHandoffUiState.ready;
    return switch (backendSession?.syncStatus ?? FrameSyncStatus.none) {
      FrameSyncStatus.failed => BackendHandoffUiState.failedRetryable,
      FrameSyncStatus.uploadPending ||
      FrameSyncStatus.uploading ||
      FrameSyncStatus.processing =>
        BackendHandoffUiState.working,
      FrameSyncStatus.none || FrameSyncStatus.ready =>
        BackendHandoffUiState.canStart,
    };
  }

  /// The failure the coordinator recorded against this session, for the
  /// card's honest retry message.
  String? get handoffError => backendSession?.lastError;

  /// True when a panorama exists on this device but Sitewise has never
  /// accepted this exact file. The upload is the only step that makes a
  /// capture visible to buyers, so an interrupted one stays on screen.
  bool get uploadPending {
    // A 38-point live tour has no legacy upload record by design: its
    // Sitewise state is the backend handoff, not this record.
    if (liveBackend) return false;
    final path = tour?.panoramaPath;
    if (path == null || !MobileConfig.usesLiveApi) return false;
    final record = upload;
    return record == null || !record.accepted || record.panoramaPath != path;
  }

  /// True when the current panorama is the copy Sitewise accepted, so the
  /// review screen can say so instead of offering a second upload.
  bool get panoramaPublished =>
      !liveBackend &&
      MobileConfig.usesLiveApi &&
      hasPanorama &&
      !uploadPending;

  String get propertyId => tour?.propertyId ?? '';

  Future<bool> regenerate() async {
    if (generating) return false;
    generating = true;
    stage = 'Validating frames...';
    error = null;
    notifyListeners();
    try {
      if (_sphereEngine) return await _regenerateSphere();
      final service = stitchService;
      unawaited(service?.beginFinalPanorama());
      final manifest = await ServiceLocator.frameStore.loadManifest(tourId);
      final entries = manifest.entries.toList()
        ..sort((a, b) => a.key.compareTo(b.key));
      final result = await ServiceLocator.panoramas.generate(
        tourId: tourId,
        frames: [for (final e in entries) e.value],
        onStage: (s) {
          stage = s;
          notifyListeners();
        },
      );
      unawaited(
        service?.completeFinalPanorama(
          success: result.success && result.panoramaPath != null,
          panoramaPath: result.panoramaPath,
          errorReason: result.success ? null : result.message,
        ),
      );
      if (result.success) {
        await load();
        return true;
      }
      // The photographs stay exactly as they are: a failed stitch is a
      // stitching problem, never a reason to recapture.
      error = result.message;
      return false;
    } catch (e) {
      error = 'Generation error: $e';
      return false;
    } finally {
      generating = false;
      notifyListeners();
    }
  }

  /// Stitches the 38 saved photographs with the sphere flow's own pipeline and
  /// records the result on the tour record. The 26-frame generation service
  /// cannot run here — it validates against 26 targets and would read the
  /// 38-frame set as broken — and the per-pair verifier is likewise a
  /// 26-point-flow component.
  Future<bool> _regenerateSphere() async {
    try {
      final records = await _repository().loadRecords(tourId);
      final result = await const PanoramaGenerationService(
        EquirectangularStitcher(),
      ).generate(
        records: records,
        total: kSphereTargetCount,
        onStage: (s) {
          stage = s;
          notifyListeners();
        },
      );
      if (!result.success || result.panoramaPath == null) {
        // The photographs stay exactly as they are: a failed stitch is a
        // stitching problem, never a reason to recapture.
        error = result.message;
        return false;
      }
      final saved = await ServiceLocator.tourRepo.tourById(tourId);
      if (saved != null) {
        await ServiceLocator.tourRepo.updateTour(
          saved.copyWith(
            panoramaPath: result.panoramaPath,
            status: VirtualTourStatus.ready,
          ),
        );
      }
      await load();
      return true;
    } catch (e) {
      error = 'Generation error: $e';
      return false;
    }
  }

  /// Uploads the device panorama to the property it belongs to.
  ///
  /// Nothing here re-stitches or re-captures: the frames and the stitched JPEG
  /// are read from disk and sent again, which is what makes this safe to retry
  /// as often as the network needs. A repeat of an already accepted file is
  /// refused rather than written to storage a second time.
  Future<bool> pushPanorama() async {
    if (generating) return false;
    final path = tour?.panoramaPath;
    final property = tour?.propertyId;
    if (path == null || property == null || property.isEmpty) {
      error = 'There is no panorama on this device to upload yet.';
      notifyListeners();
      return false;
    }
    if (!MobileConfig.usesLiveApi) {
      error =
          'Uploading needs the live Sitewise service '
          '(a demo build keeps no property records).';
      notifyListeners();
      return false;
    }
    generating = true;
    stage = 'Uploading panorama to Sitewise…';
    error = null;
    notifyListeners();
    try {
      final file = File(path);
      final bytes = await file.readAsBytes();
      final previous = upload;
      if (previous != null &&
          previous.accepted &&
          previous.covers(path, bytes.length)) {
        error = 'Sitewise already holds this panorama.';
        return false;
      }
      final record = PanoramaUploadRecord(
        tourId: tourId,
        propertyId: property,
        panoramaPath: path,
        bytes: bytes.length,
      );
      await ServiceLocator.frameStore.savePanoramaUpload(record);
      await ServiceLocator.virtualTours.uploadPanorama(
        propertyId: property,
        bytes: bytes,
        filename: p.basename(path),
      );
      final accepted = record.copyWith(uploadedAt: DateTime.now());
      await ServiceLocator.frameStore.savePanoramaUpload(accepted);
      upload = accepted;
      CaptureLog.log('Panorama uploaded for property $property');
      return true;
    } catch (e) {
      error =
          'The panorama was generated on this device, but the Sitewise upload '
          'failed: $e The frames and the panorama are kept — you can retry.';
      return false;
    } finally {
      generating = false;
      stage = null;
      notifyListeners();
    }
  }

  /// Re-reads the handoff record and the canonical panorama metadata. Both
  /// reads are allowed to fail independently: a metadata outage must not
  /// erase the recorded handoff state, and vice versa.
  Future<void> _refreshBackendState() async {
    final sessions = _sphereSessions;
    if (sessions == null) return;
    try {
      backendSession = await sessions.getSession(tourId);
    } on Object {
      backendSession = null;
    }
    final property = int.tryParse(tour?.propertyId ?? '');
    if (property == null) {
      canonical = null;
      canonicalError = null;
      return;
    }
    try {
      canonical = await ServiceLocator.panoramaViews.latestForProperty(property);
      canonicalError = null;
    } on Object catch (e) {
      canonical = null;
      canonicalError = readableFailure(
        e,
        fallback: 'The Sitewise panorama state could not be read.',
      );
    }
  }

  /// Runs (or re-runs) the backend-authoritative handoff from the preview —
  /// the same coordinator the capture banner uses, against the same saved
  /// frames. Nothing on this device is deleted or restitched by it.
  Future<bool> retryHandoff() async {
    if (generating || !liveBackend) return false;
    final sessions = _sphereSessions;
    if (sessions == null) return false;
    final property = int.tryParse(tour?.propertyId ?? '');
    if (property == null) {
      error =
          'The property draft must be saved before a Sitewise capture '
          'session can start. The photographs are kept on this device.';
      notifyListeners();
      return false;
    }
    generating = true;
    stage = 'Preparing the Sitewise handoff…';
    error = null;
    notifyListeners();
    try {
      final frames = await sessions.loadFrames(tourId);
      await BackendCaptureCoordinator(
        client: ServiceLocator.apiClient,
        store: sessions,
      ).handOff(
        stationId: tourId,
        propertyId: property,
        frames: frames,
        expectedFrames: kSphereTargetCount,
        onStage: (s) {
          stage = s;
          notifyListeners();
        },
      );
      await _refreshBackendState();
      return true;
    } on Object catch (e) {
      error =
          'The Sitewise handoff failed: '
          '${readableFailure(e, fallback: 'handoff error')} '
          'The frames and the panorama are kept on this device — you can '
          'retry.';
      return false;
    } finally {
      generating = false;
      stage = null;
      notifyListeners();
    }
  }

  Future<bool> submit() async {
    try {
      await ServiceLocator.tourService.submitTour(tourId);
      await load();
      return true;
    } catch (e) {
      error = e.toString();
      notifyListeners();
      return false;
    }
  }

  Future<bool> remove() async {
    try {
      await ServiceLocator.tourService.deleteTour(tourId);
      return true;
    } catch (e) {
      error = e.toString();
      notifyListeners();
      return false;
    }
  }

  /// Prepare a retake of capture target [targetId]: delete that one photograph
  /// and its record, then let the caller reopen the live session. The capture
  /// controller rebuilds its target list from the records on disk, so this
  /// target reads as pending again while the other saved frames are untouched.
  Future<void> retakeTarget(int targetId) async {
    await _repository().clearRecord(tourId, targetId);
    // The verdict document reconciles against the photographs that exist when
    // it loads, so rebuilding it drops the retaken target's stale row instead
    // of leaving a "passed" verdict on a photograph that is gone.
    stitchService?.dispose();
    stitchService = null;
    CaptureLog.log('Retake prepared for target $targetId');
    await load();
  }

  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    stitchService?.dispose();
    super.dispose();
  }
}

/// What the preview's Sitewise card offers for a 38-point live tour. Derived
/// state, not a status value invented for the UI: every branch maps onto the
/// backend lifecycle (canonical metadata, recorded sync status).
enum BackendHandoffUiState {
  /// The canonical panorama exists — show it.
  ready,

  /// A handoff is recorded as in flight (pending, uploading or processing).
  working,

  /// The last handoff failed and can be retried from here.
  failedRetryable,

  /// No handoff has run (or the session was recreated) — offer to start it.
  canStart,
}
