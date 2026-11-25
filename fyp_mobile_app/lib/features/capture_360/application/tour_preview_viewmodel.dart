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
import 'package:fyp/features/capture_360/application/frame_upload_queue.dart';
import 'package:fyp/features/capture_360/data/repositories/sitewise_capture_repository.dart';
import 'package:fyp/features/capture_360/data/api_panorama_viewer_repository.dart';
import 'package:fyp/features/capture_360/data/stitch/incremental_stitch_service.dart';
import 'package:fyp/features/capture_360/data/stitch/incremental_stitch_worker.dart';
import 'package:fyp/features/capture_360/domain/models/capture_record.dart';
import 'package:fyp/features/capture_360/domain/quality/capture_quality_models.dart';
import 'package:fyp/features/capture_360/domain/services/target_sphere.dart';
import 'package:fyp/features/capture_360/data/sphere/equirectangular_stitcher.dart';
import 'package:fyp/features/capture_360/data/sphere/sitewise_sphere_session_store.dart';
// Session/enum types only; `CapturedFrame` stays shared_logic's — the
// manifest mirror this view model reads is written in that shape.
import 'package:fyp/features/capture_360/domain/sphere/sphere_capture_session.dart'
    hide CapturedFrame;
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
    unawaited(() async {
      try {
        final saved = await ServiceLocator.tourRepo.tourById(tourId);
        if (saved == null || saved.frameCount == count) return;
        await ServiceLocator.tourRepo.updateTour(
          saved.copyWith(frameCount: count, sceneCount: count),
        );
      } catch (error) {
        CaptureLog.log('Frame count could not be recorded: $error');
      }
    }());
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
        // Keep a local, non-nullable reference: Dart cannot promote a mutable
        // field across the awaits below, so every later use goes through this.
        final sessions = SitewiseSphereSessionStore(
          frameStore: ServiceLocator.frameStore,
          tourId: tourId,
        );
        _sphereSessions = sessions;
        await _queueSavedPanorama();
        await _refreshBackendState();
        // The durable upload queue's persisted state: what the cloud line
        // reports is what the document says, never an optimistic guess.
        queueState = await FrameUploadQueue.readState(
          ServiceLocator.frameStore,
          tourId,
        );
        // Persisted device quality verdicts, so the preview can show which
        // photographs carry warnings without re-analyzing any pixels.
        final savedFrames = await sessions.loadFrames(tourId);
        final quality = <int, FrameQualityReport>{};
        for (final frame in savedFrames) {
          final report = FrameQualityReport.tryDecode(frame.qualityJson);
          if (report != null) quality[frame.targetId] = report;
        }
        deviceQuality = quality;
      }
    } catch (e) {
      error = e.toString();
    }
    loading = false;
    _watchUploadStatus();
    if (!_disposed) notifyListeners();
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
      FrameSyncStatus.processing => BackendHandoffUiState.working,
      FrameSyncStatus.none ||
      FrameSyncStatus.ready => BackendHandoffUiState.canStart,
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
      !liveBackend && MobileConfig.usesLiveApi && hasPanorama && !uploadPending;

  String get propertyId => tour?.propertyId ?? '';

  /// The one sentence a failed panorama generation shows.
  ///
  /// The stitcher's own message (frame indices, inlier counts, OpenCV
  /// failures) is a diagnostic: it goes to the internal log, never to the
  /// screen, because the agent can only retry.
  static const String _panoramaFailure =
      'Unable to generate the panorama. Please try again.';

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
      CaptureLog.log('Panorama generation failed: ${result.message}');
      error = _panoramaFailure;
      return false;
    } catch (e) {
      CaptureLog.log('Panorama generation threw: $e');
      error = _panoramaFailure;
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
      final result =
          await const PanoramaGenerationService(
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
        CaptureLog.log('Sphere panorama generation failed: ${result.message}');
        error = _panoramaFailure;
        return false;
      }
      final saved = await ServiceLocator.tourRepo.tourById(tourId);
      await _sphereSessions?.savePanorama(
        sessionId: tourId,
        localPanoramaPath: result.panoramaPath,
        status: PanoramaGenerationStatus.ready,
        error: null,
      );
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
      CaptureLog.log('Sphere panorama generation threw: $e');
      error = _panoramaFailure;
      return false;
    }
  }

  Future<void> _queueSavedPanorama() async {
    final sessions = _sphereSessions;
    final property = int.tryParse(propertyId);
    if (sessions == null || property == null) return;
    try {
      final path = await _devicePanoramaPath(sessions);
      if (path == null) return;
      final queue = _uploadQueue;
      await queue.enqueuePanorama(path, propertyId: property);
      queue.resumeInBackground();
    } on Object catch (error) {
      CaptureLog.log('Saved panorama could not be queued: $error');
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
    // Never upload an old device-rendered panorama for a live sphere tour.
    if (liveBackend) return retryHandoff();
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

  /// The server-side inspection/assignment status for a live 38-point tour,
  /// read from the provider-flow inspection endpoint. `null` when the user
  /// is not the assigned Agent, the property has no assignment yet, or the
  /// read failed — every consumer must treat null as "not verified", never
  /// as "satisfied".
  Map<String, dynamic>? inspectionStatus;
  String? inspectionError;
  Timer? _uploadStatusTimer;
  bool _refreshingUploadStatus = false;

  bool get populationRequiresAcknowledgement =>
      inspectionStatus?['population_requires_acknowledgement'] == true;

  String? get inspectionPanoramaId =>
      inspectionStatus?['panorama_id'] as String?;

  String? get previewPanoramaId {
    final record = queueState?.panorama;
    if (record != null) return record.confirmed ? record.panoramaId : null;
    return hasPanorama ? null : inspectionPanoramaId;
  }

  String get panoramaReviewStatus {
    if (panoramaUploaded) return '360° panorama ready';
    if (queueState?.panoramaInFlight ?? false) return '360° panorama syncing';
    if (queueState?.panorama?.lastError != null) {
      return '360° upload needs a retry';
    }
    if (previewPanoramaId != null) return '360° panorama needs verification';
    if (hasPanorama) return '360° panorama saved on this device';
    return '360° panorama still needed';
  }

  void _watchUploadStatus() {
    _uploadStatusTimer?.cancel();
    if (_disposed || !liveBackend || !cloudSyncing) return;
    _uploadStatusTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (_refreshingUploadStatus || submitting || generating || loading) {
        return;
      }
      _refreshingUploadStatus = true;
      try {
        final previousId = previewPanoramaId;
        queueState = await FrameUploadQueue.readState(
          ServiceLocator.frameStore,
          tourId,
        );
        if (_disposed) return;
        if (previousId != previewPanoramaId) await _refreshBackendState();
        if (!cloudSyncing) _uploadStatusTimer?.cancel();
        if (!_disposed) notifyListeners();
      } on Object {
        // The next refresh or submit can retry a transient queue read error.
      } finally {
        _refreshingUploadStatus = false;
      }
    });
  }

  /// The durable upload queue's persisted state for this tour: per-frame
  /// records and the panorama draft record. Read from disk on every load and
  /// server refresh, so the cloud line always mirrors what is actually
  /// persisted, not an in-memory assumption.
  FrameUploadQueueState? queueState;

  /// Persisted device quality verdicts per target id, read from the session
  /// store. Empty when the tour has no 38-frame session store. This is
  /// evidence for the review screen only — the photographs themselves are
  /// never modified by it and nothing is retaken automatically.
  Map<int, FrameQualityReport> deviceQuality = <int, FrameQualityReport>{};

  /// The backend's capture-quality report (registration, coverage, seam
  /// checks), when the server has produced one for this session. `null` when
  /// unavailable — never treated as a failure.
  Map<String, dynamic>? backendQuality;

  /// Diagnostic counters over [deviceQuality].
  ///
  /// These are read from the persisted per-frame verdicts and are kept for
  /// logging and for anyone debugging a capture. They are deliberately NOT
  /// rendered: a count of photographs carrying warnings is an alarm the
  /// agent cannot act on, so the preview shows no quality line at all.
  int get deviceQualityWarnings => deviceQuality.values
      .where((report) => report.verdict == QualityVerdict.warning)
      .length;

  int get deviceQualityInvalid => deviceQuality.values
      .where((report) => report.verdict == QualityVerdict.invalid)
      .length;

  /// Public re-read of the server-side state (canonical panorama, inspection
  /// status, handoff record, queue state) without touching any local file.
  /// The review card calls this after an upload or an inspection change.
  Future<void> refreshServerState() async {
    await _refreshBackendState();
    queueState = await FrameUploadQueue.readState(
      ServiceLocator.frameStore,
      tourId,
    );
    notifyListeners();
  }

  // ------------------------------------------------------------------
  // Cloud draft status (§5): three honest lines only.
  // ------------------------------------------------------------------

  /// True when Sitewise has confirmed every unit the queue knows about —
  /// the panorama AND all backed-up originals. A tour with no queue
  /// document (captured before the queue existed) falls back to the
  /// backend's own canonical state, never to a local assumption.
  bool get cloudSynced {
    final state = queueState;
    if (state == null || state.frames.isEmpty) {
      return canonicalReady || inspectionStatus?['panorama_uploaded'] == true;
    }
    return state.fullySynced ||
        (state.panoramaConfirmed && state.frames.isEmpty);
  }

  /// True while the queue still has pending or in-flight units.
  bool get cloudSyncing {
    final state = queueState;
    if (state == null) return false;
    return state.anyPending && !state.fullySynced;
  }

  /// The one line the preview's cloud status shows. "Saved to SiteWise"
  /// appears ONLY after FastAPI has confirmed the uploads.
  String get cloudStatusLine {
    if (cloudSynced) return 'Saved to SiteWise';
    final state = queueState;
    if (state?.panoramaInFlight ?? false) {
      return 'Syncing to SiteWise…';
    }
    if ((state?.failedFrames ?? 0) > 0) {
      return 'Some photographs still need to sync — Sitewise will retry.';
    }
    if (cloudSyncing) return 'Syncing to SiteWise…';
    return 'Draft saved on this device';
  }

  /// The upload-queue singleton for this tour. The same instance the capture
  /// host used, so a drain here can never double-run against the capture's
  /// drain.
  FrameUploadQueue get _uploadQueue => FrameUploadQueue.forTour(
    frameStore: ServiceLocator.frameStore,
    tourId: tourId,
  );

  /// Re-reads the handoff record, the canonical panorama metadata and the
  /// server-side inspection status. All three reads are allowed to fail
  /// independently: a metadata outage must not erase the recorded handoff
  /// state, and vice versa.
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
      inspectionStatus = null;
      return;
    }
    try {
      canonical = await ServiceLocator.panoramaViews.latestForProperty(
        property,
      );
      canonicalError = null;
    } on Object catch (e) {
      canonical = null;
      canonicalError = readableFailure(
        e,
        fallback: 'The Sitewise panorama state could not be read.',
      );
    }
    try {
      final response = await ServiceLocator.apiClient.get(
        '/api/v1/provider-flow/properties/$property/inspection',
      );
      inspectionStatus = response['data'] as Map<String, dynamic>?;
      inspectionError = null;
    } on Object catch (failure) {
      inspectionError = readableFailure(
        failure,
        fallback: 'Could not refresh the saved inspection.',
      );
    }
    // The backend's own capture-quality report, when it has run its
    // registration/coverage/seam checks for this session. Independent read:
    // a failure here never disturbs the inspection state above.
    final backendSessionId = backendSession?.backendSessionId;
    if (backendSessionId != null && backendSessionId.isNotEmpty) {
      try {
        backendQuality = await ServiceLocator.apiClient.get(
          '/api/v1/360/sessions/$backendSessionId/quality',
        );
      } on Object {
        backendQuality = null;
      }
    } else {
      backendQuality = null;
    }
  }

  /// The server-side assignment state for this property, when readable.
  /// Empty when no assignment/status could be read — never null.
  String get assignmentStatus =>
      '${inspectionStatus?['assignment_status'] ?? ''}';

  /// Whether the assignment is in a state that allows inspection and
  /// capture work (or correction after a rejection).
  bool get assignmentReady =>
      assignmentStatus == 'accepted' || assignmentStatus == 'needs_correction';

  /// The four on-site verification checks, as the SERVER recorded them.
  bool get checksComplete {
    final form = inspectionStatus?['checklist'];
    if (form is! Map) return false;
    const keys = <String>[
      'floor_area_verified',
      'condition_verified',
      'parking_verified',
      'accessibility_verified',
    ];
    return keys.every((key) => form[key] == true);
  }

  /// Whether Sitewise holds a verified canonical panorama for this property:
  /// the canonical metadata (which only exists after the confirmation
  /// endpoint verified the stored object) or the server's own
  /// `panorama_uploaded` flag.
  bool get panoramaUploaded =>
      inspectionError == null &&
      previewPanoramaId != null &&
      previewPanoramaId == inspectionPanoramaId;

  /// A complete local capture can be synced by the submission action.
  bool get submissionEligible =>
      liveBackend &&
      inspectionError == null &&
      assignmentReady &&
      checksComplete &&
      (hasPanorama || inspectionStatus?['panorama_uploaded'] == true) &&
      specs.length == kSphereTargetCount &&
      frames.length == specs.length;

  /// Re-arms the durable upload queue and drains it — the ONLY retry path a
  /// live 38-point tour needs. Every pending frame and the panorama draft
  /// resume without recapturing; confirmed units are skipped byte-for-byte.
  /// Returns true when the panorama draft reached Sitewise.
  Future<bool> retryHandoff() async {
    if (generating || !liveBackend) return false;
    generating = true;
    error = null;
    notifyListeners();
    try {
      final sessions = _sphereSessions;
      if (sessions == null) return false;
      final property = int.tryParse(tour?.propertyId ?? '');
      await _uploadQueue.reconcileFrames(
        await sessions.loadFrames(tourId),
        propertyId: property,
      );
      final queue = _uploadQueue;
      if (queueState?.panorama == null &&
          inspectionStatus?['panorama_uploaded'] != true) {
        final path = await _devicePanoramaPath(sessions);
        if (path != null) {
          await queue.enqueuePanorama(path, propertyId: property);
        }
      }
      await queue.resume();
      await refreshServerState();
      return queueState?.panoramaConfirmed ?? false;
    } on Object catch (e) {
      error =
          'The Sitewise synchronization could not resume: '
          '${readableFailure(e, fallback: 'sync error')} '
          'The frames and the panorama are kept on this device — you can '
          'retry.';
      return false;
    } finally {
      generating = false;
      stage = null;
      notifyListeners();
    }
  }

  /// Starts a NEW capture attempt (the preview's "Recapture → start a new
  /// 38-photo capture" choice).
  ///
  /// The previous attempt's evidence is preserved on every layer before the
  /// station is archived: the queue drains any pending upload first (best
  /// effort), the canonical `fyp.panoramas` row in SiteWise is untouched,
  /// and the local station directory is RENAMED — never deleted — so the
  /// previous draft stays recoverable even if the replacement capture fails.
  /// A fresh queue document gets a fresh attempt key, which gives the
  /// replacement capture its own backend session instead of overwriting the
  /// confirmed one.
  Future<bool> startNewCaptureAttempt() async {
    if (generating) return false;
    generating = true;
    stage = 'Preparing a new capture…';
    error = null;
    notifyListeners();
    try {
      // 1. Best-effort flush so the previous draft is safely in SiteWise.
      try {
        final sessions = _sphereSessions;
        if (sessions != null) {
          final property = int.tryParse(tour?.propertyId ?? '');
          await _uploadQueue.reconcileFrames(
            await sessions.loadFrames(tourId),
            propertyId: property,
          );
        }
        await _uploadQueue.resume();
      } on Object {
        // The archive below keeps everything anyway.
      }
      // 2. Archive the station directory (frames, session, queue document,
      //    panorama). The rename keeps every previous byte on disk.
      final root = await ServiceLocator.frameStore.tourRoot(tourId);
      final stationDir = Directory(p.join(root, 'ar_capture', tourId));
      if (await stationDir.exists()) {
        final archiveName =
            '${tourId}_prev_'
            '${DateTime.now().millisecondsSinceEpoch}';
        try {
          await stationDir.rename(p.join(root, 'ar_capture', archiveName));
        } on Object {
          // A rename across filesystem boundaries can fail; fall back to
          // copying is overkill — a failed archive keeps the capture as-is
          // and the caller shows the error instead of destroying anything.
          error =
              'The previous capture could not be archived, so a new capture '
              'was not started. Nothing was deleted.';
          return false;
        }
      }
      // 3. Clear the manifest mirror so the capture host starts fresh.
      await ServiceLocator.frameStore.saveManifest(
        tourId,
        const <int, CapturedFrame>{},
      );
      // 4. Detach the archived panorama from the tour record: the property
      //    detail reads the CANONICAL row from SiteWise (which still holds
      //    the previous draft), and the replacement stitch will attach the
      //    new file here.
      final saved = await ServiceLocator.tourRepo.tourById(tourId);
      if (saved != null) {
        await ServiceLocator.tourRepo.updateTour(
          VirtualTour(
            id: saved.id,
            propertyId: saved.propertyId,
            title: saved.title,
            sceneCount: 0,
            capturedAt: saved.capturedAt,
            published: saved.published,
            status: VirtualTourStatus.draft,
            frameCount: 0,
          ),
        );
      }
      queueState = null;
      await load();
      return true;
    } catch (e) {
      error = 'A new capture attempt could not be prepared: $e';
      return false;
    } finally {
      generating = false;
      stage = null;
      notifyListeners();
    }
  }

  /// The device-stitched panorama for this tour, verified on disk: the tour
  /// record's path first, then the session store's stitched panorama.
  Future<String?> _devicePanoramaPath(
    SitewiseSphereSessionStore sessions,
  ) async {
    final candidates = <String?>[
      tour?.panoramaPath,
      (await sessions.getSession(tourId))?.localPanoramaPath,
    ];
    for (final path in candidates) {
      if (path == null || path.isEmpty) continue;
      if (await File(path).exists()) return path;
    }
    return null;
  }

  /// Whether the Admin submission is in flight. Disables the submit button
  /// while the request runs, so a double tap cannot send a second workflow.
  bool submitting = false;

  /// Explicit Agent action: submit this property to Admin review through the
  /// existing provider-flow verification endpoint. The backend re-checks
  /// every precondition server-side — the accepted Agent assignment, the four
  /// saved on-site verification checks, and a verified canonical panorama
  /// created after the inspection was saved — so a refusal carries the exact
  /// precondition that is missing. The old generic `submitTour()` call is not
  /// used: it bypassed those business rules.
  Future<bool> submit({required bool acknowledgeUnavailablePopulation}) async {
    if (submitting || generating || !submissionEligible) return false;
    final property = int.tryParse(tour?.propertyId ?? '');
    if (property == null) {
      error =
          'The property draft must be saved before this tour can be '
          'submitted for review.';
      notifyListeners();
      return false;
    }
    submitting = true;
    error = null;
    notifyListeners();
    var submitted = false;
    try {
      await refreshServerState();
      if (inspectionError != null) {
        error = inspectionError;
        return false;
      }
      if (!assignmentReady || !checksComplete) {
        error = 'Review the assignment and save all four inspection checks.';
        return false;
      }
      final sessions = _sphereSessions;
      if (sessions != null) {
        final localPath = await _devicePanoramaPath(sessions);
        if (localPath != null) {
          await _uploadQueue.enqueuePanorama(localPath, propertyId: property);
          queueState = await FrameUploadQueue.readState(
            ServiceLocator.frameStore,
            tourId,
          );
        }
      }
      if (previewPanoramaId == null) await retryHandoff();
      if (inspectionError != null) {
        error = inspectionError;
        return false;
      }
      final panoramaId = previewPanoramaId;
      if (panoramaId == null) {
        error ??= 'The panorama could not sync. Tap Submit to Admin to retry.';
        return false;
      }
      await ServiceLocator.apiClient.post(
        '/api/v1/provider-flow/properties/$property/submit',
        <String, dynamic>{
          'panorama_id': panoramaId,
          'acknowledge_unavailable_population':
              acknowledgeUnavailablePopulation,
        },
      );
      submitted = true;
    } on Object catch (e) {
      error = readableFailure(e, fallback: 'The submission was refused.');
    } finally {
      submitting = false;
      notifyListeners();
    }
    if (submitted) await load();
    return submitted;
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
    _uploadStatusTimer?.cancel();
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
