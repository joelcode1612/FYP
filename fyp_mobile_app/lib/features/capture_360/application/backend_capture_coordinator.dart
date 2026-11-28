import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
// shared_logic also declares a `CapturedFrame` entity; this coordinator works
// with the 38-target capture domain one.
import 'package:shared_logic/shared_logic.dart' hide CapturedFrame;

import 'package:fyp/core/utils/capture_log.dart';
import 'package:fyp/features/capture_360/data/sphere/processing_derivative.dart';
import 'package:fyp/features/capture_360/domain/sphere/adaptive_sphere_plan.dart'
    show AdaptiveSpherePlan;
import 'package:fyp/features/capture_360/domain/sphere/sphere_capture_session.dart';
import 'package:fyp/features/capture_360/domain/sphere/sphere_target.dart'
    show planIsBackendStitched;

/// One successful cloud synchronization.
class BackendHandoffResult {
  const BackendHandoffResult({
    required this.backendSessionId,
    required this.panoramaId,
    required this.storagePath,
    required this.viewUrl,
    required this.width,
    required this.height,
    required this.panoramaUploaded,
    required this.backupUploaded,
    required this.backupTotal,
  });

  final String backendSessionId;
  final String panoramaId;
  final String storagePath;
  final String viewUrl;
  final int width;
  final int height;
  final bool panoramaUploaded;
  final int backupUploaded;
  final int backupTotal;
}

/// The stage the device-panorama workflow is currently in. These are
/// application states, never raw storage or OpenCV messages.
enum BackendHandoffStage {
  /// The 38 originals exist on the device and the workflow is being prepared.
  captured,

  /// The device is generating the 2:1 equirectangular panorama.
  processing,

  /// The completed device panorama is being PUT to Supabase Storage and
  /// confirmed through FastAPI.
  panoramaUploading,

  /// The 38 original JPEGs are being backed up through a resumable queue.
  framesBackingUp,

  /// The canonical panorama exists and has a viewing URL.
  ready,
}

/// Honest, bounded progress for the capture UI. [processed]/[total] describe
/// backed-up originals; [percent] is optional and only used when a stage has a
/// natural percentage.
class BackendHandoffProgress {
  const BackendHandoffProgress({
    required this.stage,
    this.processed = 0,
    this.total = 0,
    this.percent,
  });

  final BackendHandoffStage stage;
  final int processed;
  final int total;
  final int? percent;
}

/// A synchronization step the caller can act on. The message is written for
/// the capture banner: honest, retry-oriented, and never blaming the frames.
class BackendHandoffFailure implements Exception {
  const BackendHandoffFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

enum _PutOutcome { stored, expired, retryable, fatal }

/// The stage of the backend panorama job, as the server reports it.
///
/// These are the real states of the durable worker — `queued` means the job is
/// waiting for a worker, `processing` means one has claimed it. The capture
/// screen maps them onto its own copy; it never invents a percentage.
enum PanoramaJobStage { queued, processing, downloading }

/// The uploads are not finished yet.
///
/// Deliberately NOT a [BackendHandoffFailure]: the handoff has not failed, it
/// has not finished uploading. Treating the two as one is what made the capture
/// screen offer "Retry Handoff" for a capture that was still working normally.
class UploadsIncompleteFailure implements Exception {
  const UploadsIncompleteFailure({required this.count, required this.confirmed});

  final int count;
  final int confirmed;

  int get missing => (count - confirmed).clamp(0, count);

  @override
  String toString() =>
      '$confirmed of $count photographs are confirmed on Sitewise.';
}

/// The outcome of following one panorama job.
class PanoramaFollowResult {
  const PanoramaFollowResult._({
    required this.ready,
    required this.pending,
    this.failureMessage,
    this.panorama,
    this.panoramaId,
  });

  /// The panorama is downloaded and on disk.
  const PanoramaFollowResult.ready(Map<String, dynamic> panorama)
    : this._(ready: true, pending: false, panorama: panorama);

  /// Still working on the server. Call again later; the job keeps running.
  const PanoramaFollowResult.pending(String message)
    : this._(ready: false, pending: true, failureMessage: message);

  /// A genuine failure that needs the user or a stage-aware retry.
  const PanoramaFollowResult.failed(String message, {String? panoramaId})
    : this._(
        ready: false,
        pending: false,
        failureMessage: message,
        panoramaId: panoramaId,
      );

  final bool ready;
  final bool pending;
  final String? failureMessage;
  final Map<String, dynamic>? panorama;
  final String? panoramaId;

  bool get failed => !ready && !pending;
}

/// The device-generated-panorama cloud synchronization.
///
/// Flutter has already stitched the 38 originals into one 2:1 equirectangular
/// JPEG before this class runs. This coordinator therefore NEVER calls
/// `POST /api/v1/360/sessions/{id}/process` and never waits for a Python
/// stitching job. It:
///
///   1. creates or resumes the authorized capture session (idempotent key),
///   2. uploads and confirms the completed panorama first, so the cloud
///      result is not blocked behind 38 backup uploads,
///   3. then backs the originals up through a resumable queue, two files at
///      a time, skipping frames FastAPI already confirmed byte-for-byte.
///
/// The canonical `fyp.panoramas` row is created by the panorama confirmation
/// endpoint, not by a worker, and the local panorama/frames are never deleted
/// by any failure here.
class BackendCaptureCoordinator {
  BackendCaptureCoordinator({required this._client, required this._store});

  static const _api = '/api/v1/360';
  static const _uploadConcurrency = 2;
  static const _maxUploadAttempts = 3;
  static const _uploadTimeout = Duration(minutes: 5);

  final ApiClient _client;
  final CaptureSessionStore _store;
  final HttpClient _http = HttpClient();

  /// Poll jitter. Two devices following the same job must not tick in lockstep
  /// against the backend.
  static final math.Random _random = math.Random();

  /// Legacy device-panorama handoff. The active adaptive capture uses
  /// [FrameUploadQueue] and [sendFrameToBackend]; this path is retained only
  /// for historical device-38 sessions and is not called by the adaptive UI.
  Future<BackendHandoffResult> handOff({
    required String stationId,
    required int propertyId,
    required List<CapturedFrame> frames,
    required int expectedFrames,
    String? panoramaPath,

    /// The stable per-attempt key the session identity is derived from.
    /// Supplied by the upload queue document; when absent (a caller that
    /// never persisted one) the coordinator keeps the legacy checksum key.
    String? attemptKey,
    void Function(String stage)? onStage,
    void Function(int processed, int total)? onFrameProcessed,
    void Function(BackendHandoffProgress progress)? onProgress,
  }) async {
    try {
      return await _handOff(
        stationId: stationId,
        propertyId: propertyId,
        frames: frames,
        expectedFrames: expectedFrames,
        panoramaPath: panoramaPath,
        attemptKey: attemptKey,
        onStage: onStage,
        onFrameProcessed: onFrameProcessed,
        onProgress: onProgress,
      );
    } on Object catch (error) {
      final failure = _friendlyFailure(error);
      await _record(
        stationId,
        FrameSyncStatus.failed,
        panoramaSyncStatus: panoramaPath == null
            ? null
            : FrameSyncStatus.failed,
        backupSyncStatus: FrameSyncStatus.failed,
        error: failure.message,
      );
      throw failure;
    }
  }

  /// One sentence a person can act on. HTTP statuses, storage codes and SDK
  /// text are logged by [_friendlyFailure] and never reach the capture screen.
  static const _syncFallback =
      'The photographs could not be synchronized with Sitewise. They are '
      'kept on this device — retry the synchronization.';

  BackendHandoffFailure _friendlyFailure(Object error) {
    if (error is BackendHandoffFailure) return error;
    CaptureLog.log('Capture synchronization error: $error');
    if (error is UnauthorizedFailure) {
      return BackendHandoffFailure(error.userMessage);
    }
    if (error is NetworkFailure) {
      return BackendHandoffFailure(error.userMessage);
    }
    if (error is ConflictFailure) {
      // Backend conflicts are written for a person: a review rule, a
      // published tour, a cancelled session.
      return BackendHandoffFailure(error.message);
    }
    return const BackendHandoffFailure(_syncFallback);
  }

  Future<BackendHandoffResult> _handOff({
    required String stationId,
    required int propertyId,
    required List<CapturedFrame> frames,
    required int expectedFrames,
    required String? panoramaPath,
    required String? attemptKey,
    void Function(String stage)? onStage,
    void Function(int processed, int total)? onFrameProcessed,
    void Function(BackendHandoffProgress progress)? onProgress,
  }) async {
    onStage?.call('Validating photographs...');
    final ordered = await _validated(frames, expectedFrames);
    onProgress?.call(
      BackendHandoffProgress(
        stage: BackendHandoffStage.captured,
        processed: expectedFrames,
        total: expectedFrames,
      ),
    );

    // One digest at a time: only the 64-character hex strings are kept.
    final checksums = <int, String>{};
    for (final frame in ordered) {
      checksums[frame.targetId] = await _checksum(frame.imagePath);
    }
    final panoramaChecksum = panoramaPath == null
        ? null
        : await _checksum(panoramaPath);

    onStage?.call('Preparing the Sitewise session...');
    final backendSessionId = await ensureSession(
      stationId: stationId,
      propertyId: propertyId,
      attemptKey:
          attemptKey ?? _legacyChecksumKey(stationId, propertyId, checksums),
    );
    await _record(
      stationId,
      FrameSyncStatus.uploadPending,
      backendSessionId: backendSessionId,
      backupSyncStatus: FrameSyncStatus.uploadPending,
      backupTotal: ordered.length,
    );

    String? panoramaId;
    String? storagePath;
    int panoramaWidth = 0;
    int panoramaHeight = 0;
    if (panoramaPath != null && panoramaChecksum != null) {
      onProgress?.call(
        const BackendHandoffProgress(
          stage: BackendHandoffStage.panoramaUploading,
        ),
      );
      onStage?.call('Uploading your 360° panorama...');
      await _record(
        stationId,
        FrameSyncStatus.uploading,
        panoramaSyncStatus: FrameSyncStatus.uploading,
        backendSessionId: backendSessionId,
      );
      final confirmed = await _uploadAndConfirmPanorama(
        sessionId: backendSessionId,
        propertyId: propertyId,
        panoramaPath: panoramaPath,
        checksum: panoramaChecksum,
      );
      panoramaId = confirmed['panoramaId'] as String?;
      storagePath = confirmed['storagePath'] as String?;
      panoramaWidth = (confirmed['width'] as num?)?.toInt() ?? 0;
      panoramaHeight = (confirmed['height'] as num?)?.toInt() ?? 0;
      await _record(
        stationId,
        FrameSyncStatus.uploading,
        panoramaSyncStatus: FrameSyncStatus.ready,
        backendSessionId: backendSessionId,
        backendPanoramaId: panoramaId,
      );
    }

    final backup = await _backupFrames(
      stationId: stationId,
      sessionId: backendSessionId,
      frames: ordered,
      checksums: checksums,
      onStage: onStage,
      onFrameProcessed: onFrameProcessed,
      onProgress: onProgress,
    );

    var viewUrl = '';
    if (panoramaId == null) {
      // A resumed sync may find the canonical row that an earlier launch
      // confirmed. It is read without ever touching a processing job.
      try {
        final canonical = await _client.get(
          '$_api/properties/$propertyId/panorama',
        );
        panoramaId = canonical['panoramaId'] as String?;
        storagePath = canonical['storagePath'] as String?;
        panoramaWidth = (canonical['width'] as num?)?.toInt() ?? 0;
        panoramaHeight = (canonical['height'] as num?)?.toInt() ?? 0;
      } on NotFoundFailure {
        panoramaId = null;
      }
    }
    if (panoramaId != null && panoramaId.isNotEmpty) {
      final view = await _client.get('$_api/panoramas/$panoramaId/view');
      viewUrl = view['viewUrl'] as String? ?? '';
    }

    await _record(
      stationId,
      panoramaId == null
          ? FrameSyncStatus.uploadPending
          : FrameSyncStatus.ready,
      clearLastError: true,
      panoramaSyncStatus: panoramaPath == null
          ? null
          : (panoramaId == null
                ? FrameSyncStatus.uploading
                : FrameSyncStatus.ready),
      backupSyncStatus: backup.processed >= ordered.length
          ? FrameSyncStatus.ready
          : FrameSyncStatus.uploading,
      backupUploaded: backup.processed,
      backupTotal: ordered.length,
      backendPanoramaId: panoramaId,
    );
    onProgress?.call(
      BackendHandoffProgress(
        stage: BackendHandoffStage.ready,
        processed: backup.processed,
        total: ordered.length,
        percent: panoramaId == null ? null : 100,
      ),
    );
    CaptureLog.log(
      'Device-panorama sync complete: session $backendSessionId, '
      'panorama $panoramaId, backup ${backup.processed}/${ordered.length}',
    );
    return BackendHandoffResult(
      backendSessionId: backendSessionId,
      panoramaId: panoramaId ?? '',
      storagePath: storagePath ?? '',
      viewUrl: viewUrl,
      width: panoramaWidth,
      height: panoramaHeight,
      panoramaUploaded: panoramaId != null && panoramaId.isNotEmpty,
      backupUploaded: backup.processed,
      backupTotal: ordered.length,
    );
  }

  /// A hex key derived from the local station, the property and the capture
  /// ATTEMPT key — never from the photograph checksums. A per-frame upload
  /// must be able to open the session after the first photograph exists,
  /// when no full manifest to hash yet. The attempt key is one stable random
  /// id per capture attempt, persisted in the local queue document, so a
  /// retry after a lost create response (or an app restart) resolves the
  /// SAME backend session; a replacement capture generates a fresh attempt
  /// key and therefore gets a fresh session with empty deterministic paths.
  String _idempotencyKey(int propertyId, String stationId, String attemptKey) {
    final digest = sha256.convert(
      utf8.encode('sitewise.capture.v2/$propertyId/$stationId/$attemptKey'),
    );
    return 'cap-${digest.toString().substring(0, 40)}';
  }

  /// The pre-attempt fallback: a key derived from the full checksum manifest,
  /// used only by a caller that never persisted an attempt key. Kept so an
  /// older capture still resolves to ITS session rather than forking a new
  /// one mid-life.
  String _legacyChecksumKey(
    String stationId,
    int propertyId,
    Map<int, String> checksums,
  ) {
    final manifest = checksums.entries
        .map((entry) => '${entry.key}:${entry.value}')
        .join('|');
    final digest = sha256.convert(
      utf8.encode('sitewise.capture.v1/$propertyId/$stationId/$manifest'),
    );
    return 'cap-${digest.toString().substring(0, 40)}';
  }

  /// Creates the authorized backend session for this capture attempt, or
  /// returns the one an earlier launch already created and persisted.
  ///
  /// [plan] carries the adaptive target geometry. It travels with the create
  /// request because it decides how many photographs the session expects: the
  /// five-ring layout is generated from the camera's measured field of view,
  /// so the count is no longer a constant the server can look up. Sending the
  /// geometry and the count in one request is what stops a device from
  /// claiming one plan while the server waits for another.
  ///
  /// The returned id is written back into the local session store BEFORE any
  /// frame is uploaded, so an app restart always knows which session to
  /// resume. A server-side 404 (expired backend data) recreates the session
  /// under the same attempt key — the frames re-confirm idempotently.
  Future<String> ensureSession({
    required String stationId,
    required int propertyId,
    required String attemptKey,
    AdaptiveSpherePlan? plan,
  }) async {
    // The attempt key resolves the same session on retry. A replacement
    // panorama has a different key even when it shares the local station.
    final local = await _store.getSession(stationId);
    if (local == null) {
      throw const BackendHandoffFailure('Save the capture plan before uploading.');
    }
    final count = local.requiredTargetCount;
    // The stored version, not the count: V4 and V11 both have 44 targets but
    // use different geometry and capture order.
    final version = local.capturePlanVersion;
    // Plan-driven sessions send originals to the worker. V4 (the adaptive
    // five-ring plan) is used for new sessions; V11 remains readable when a
    // session captured with its fixed staggered geometry is resumed.
    final planDriven = count != 56 && planIsBackendStitched(version);
    final mode = planDriven
        ? 'device_adaptive'
        : count == 56
        ? 'device_56_backend'
        : 'device_38_panorama';
    final Map<String, dynamic> created;
    try {
      created = await _client.post('$_api/sessions', <String, dynamic>{
        'property_id': propertyId,
        // Identifies the new Flutter-stitched workflow without changing the
        // expected frame count or breaking legacy `device_38` sessions.
        'capture_mode': mode,
        'capture_plan_version': '$version',
        'idempotency_key': _idempotencyKey(propertyId, stationId, attemptKey),
        if (planDriven && plan != null) 'plan': plan.toBackendPayload(),
      });
    } on Object catch (error) {
      throw _friendlyFailure(error);
    }
    if (created['expectedFrames'] != count || created['captureMode'] != mode ||
        '${created['capturePlanVersion']}' != '$version') {
      throw const BackendHandoffFailure('Server capture plan does not match the saved session.');
    }
    final id = created['sessionId'] as String?;
    if (id == null || id.isEmpty) {
      throw const BackendHandoffFailure(
        'The Sitewise service accepted the capture session but returned no '
        'session id.',
      );
    }
    // Persist BEFORE the first upload: recovery reads this value.
    await _record(
      stationId,
      FrameSyncStatus.uploadPending,
      backendSessionId: id,
      backupSyncStatus: FrameSyncStatus.uploadPending,
    );
    return id;
  }

  /// The stored plan for a session, or `null` when it predates plan storage.
  ///
  /// Resume reads this instead of regenerating target identifiers. A session
  /// whose geometry cannot be restored is not silently re-planned: the caller
  /// must start a new session, because mixing two viewpoints under one plan
  /// produces a panorama that looks plausible and is wrong.
  Future<Map<String, dynamic>?> loadPlan(String sessionId) async {
    try {
      final payload = await _client.get('$_api/sessions/$sessionId/plan');
      final plan = payload['plan'];
      return plan is Map<String, dynamic> ? plan : null;
    } on Object catch (error) {
      CaptureLog.log('Capture plan read failed: $error');
      return null;
    }
  }

  /// Asks the backend to verify one just-uploaded photograph against its
  /// overlapping neighbours.
  ///
  /// Returns the endpoint's `matches` list, which is empty when nothing
  /// overlaps yet. A transport failure returns `null` — the capture carries on
  /// and the connection stays `pending`, because a photograph is never
  /// discarded and never reported as verified on the strength of a failed
  /// request.
  Future<List<Map<String, Object?>>?> matchFrame({
    required String sessionId,
    required int targetIndex,
  }) async {
    try {
      final payload = await _client.post(
        '$_api/sessions/$sessionId/match',
        <String, dynamic>{'target_index': targetIndex},
      );
      final matches = payload['matches'];
      if (matches is! List) return const <Map<String, Object?>>[];
      return <Map<String, Object?>>[
        for (final entry in matches)
          if (entry is Map)
            <String, Object?>{
              for (final item in entry.entries)
                '${item.key}': item.value as Object?,
            },
      ];
    } on Object catch (error) {
      // A single weak request must not interrupt a sweep the user is halfway
      // through: the frame is already saved and will be re-verified by the
      // panorama worker, which matches every pair anyway.
      CaptureLog.log('Incremental match failed for target $targetIndex: $error');
      return null;
    }
  }

  /// The alignment graph recorded so far: verified, weak and refused pairs.
  Future<Map<String, dynamic>?> alignmentState(String sessionId) async {
    try {
      return await _client.get('$_api/sessions/$sessionId/alignment');
    } on Object catch (error) {
      CaptureLog.log('Alignment state read failed: $error');
      return null;
    }
  }

  /// Uploads and confirms ONE original photograph against its session —
  /// the unit the durable per-capture upload queue drains. Byte-for-byte
  /// idempotent with the batched backup: the same signed-URL transport, the
  /// same confirmation endpoint, and a repeat PUT of identical bytes is the
  /// stored success case. Returns the confirmed storage path.
  ///
  /// [qualityReport] is the device quality evidence for this photograph,
  /// optional and advisory. It rides inside the frame's `capture_pose` JSON —
  /// a field the worker already treats as an open metadata bag — so no
  /// backend schema changes and no second record are introduced. A warning
  /// never blocks or alters the upload: the photograph is confirmed exactly
  /// as captured.
  // Actual worker-generated result for a backend-stitched capture: the
  // 56-target enhanced mode and every plan-driven mode (4, 5, 6, 7 and the
  // densified 8). Never send a local panorama to the device-confirmation
  // endpoint for any of them.
  //
  // ## Why this is split into two calls
  //
  // The old `finishEnhanced` created the job and then polled it for up to six
  // minutes inside the caller's `await`. Two things went wrong with that:
  //
  //  1. A job that was still legitimately processing at the end of the poll
  //     threw, so the capture screen showed "Retry Handoff" for a *healthy*
  //     panorama. Pressing it did nothing new — the same job was resumed and
  //     the same timeout hit again.
  //  2. Because the call blocked, the caller could not distinguish "uploaded
  //     and queued" from "not uploaded yet", so the UI had only two states:
  //     spinner, or failure.
  //
  // The job is now *created* (idempotently) by [ensurePanoramaJob] and
  // *followed* by [followPanoramaJob]. The caller can therefore show the real
  // backend stage, survive an app restart mid-stitch, and reserve the Retry
  // action for a genuine failure.
  Future<Map<String, dynamic>> ensurePanoramaJob({
    required String stationId,
    required String sessionId,
  }) async {
    final saved = await _store.getSession(stationId);
    if (saved == null || saved.backendSessionId != sessionId) {
      throw const BackendHandoffFailure('Saved enhanced session does not match.');
    }
    final count = saved.requiredTargetCount;
    final version = saved.capturePlanVersion;
    final planDriven = count != 56 && planIsBackendStitched(version);
    if (!planDriven && count != 56) {
      throw const BackendHandoffFailure('Saved enhanced session does not match.');
    }
    // The mode follows the plan version, exactly as `ensureSession` chose it.
    // A plan-driven session's expected count is its plan's target count, so
    // the completeness check is the same check against a number that is no
    // longer a constant.
    final mode = planDriven ? 'device_adaptive' : 'device_56_backend';
    final server = await _client.get('$_api/sessions/$sessionId');
    if (server['captureMode'] != mode || server['expectedFrames'] != count ||
        '${server['capturePlanVersion']}' != '$version') {
      throw const BackendHandoffFailure('Saved capture plan does not match the session.');
    }
    if (server['confirmedFrames'] != count) {
      // Not a panorama failure: the uploads are not finished. The caller keeps
      // uploading and calls again; this is never surfaced as "stitching
      // failed".
      throw UploadsIncompleteFailure(
        count: count,
        confirmed: (server['confirmedFrames'] as num?)?.toInt() ?? 0,
      );
    }
    Map<String, dynamic> job;
    final savedJob = saved.backendJobId;
    if (savedJob != null && savedJob.isNotEmpty) {
      try {
        job = await _client.get('$_api/jobs/$savedJob');
      } on NotFoundFailure {
        job = const <String, dynamic>{};
      }
      if (job['sessionId'] != sessionId) {
        throw const BackendHandoffFailure(
          'Saved panorama job belongs to another session.',
        );
      }
      if (job['status'] == 'error') {
        // A failed job is retried once per explicit request. The frames are
        // untouched and the same job id is reused, so no duplicate job can be
        // created by a client that retried too often.
        job = await _client.post('$_api/jobs/$savedJob/retry', <String, dynamic>{});
      }
    } else {
      // Idempotent server-side: an existing queued/processing/done job for this
      // session is returned rather than a second one being created.
      job = await _client.post('$_api/sessions/$sessionId/process', <String, dynamic>{});
    }
    final jobId = job['jobId'] as String?;
    if (jobId == null || jobId.isEmpty || job['sessionId'] != sessionId) {
      throw const BackendHandoffFailure('Invalid panorama job response.');
    }
    // Persist BEFORE polling: an app restart resumes THIS job rather than
    // creating a second one.
    await _store.saveBackendHandoff(
      sessionId: stationId,
      syncStatus: FrameSyncStatus.processing,
      backendSessionId: sessionId,
      backendJobId: jobId,
      backupSyncStatus: FrameSyncStatus.ready,
      backupUploaded: count,
      backupTotal: count,
    );
    return job;
  }

  /// Follows an existing panorama job to a terminal state.
  ///
  /// Returns a [PanoramaFollowResult]. A job that is still processing when the
  /// budget expires returns `pending`, **never** a failure: the worker is
  /// healthy and the next call resumes the same job. Only a backend `error`
  /// status or an unusable result is reported as a failure.
  ///
  /// Polling uses exponential backoff with jitter rather than a fixed two
  /// second tick, so a job that takes two minutes costs a few dozen requests
  /// instead of sixty, and the device is not held in a tight loop.
  Future<PanoramaFollowResult> followPanoramaJob({
    required String stationId,
    required String sessionId,
    required String jobId,
    required String directory,
    Duration budget = const Duration(minutes: 15),
    void Function(PanoramaJobStage stage, Map<String, dynamic> job)? onStage,
  }) async {
    final deadline = DateTime.now().add(budget);
    var attempt = 0;
    var consecutiveTransportFailures = 0;
    while (true) {
      attempt++;
      Map<String, dynamic> job;
      try {
        job = await _client.get('$_api/jobs/$jobId');
        consecutiveTransportFailures = 0;
      } on NotFoundFailure {
        return const PanoramaFollowResult.failed(
          'This panorama job no longer exists on the server. Your photographs '
          'are saved — start the panorama again from this screen.',
        );
      } on Object catch (error) {
        consecutiveTransportFailures++;
        // A temporary network problem is not a stitching failure. Keep
        // following until the budget expires; the job keeps running on the
        // server either way.
        if (consecutiveTransportFailures >= 8 ||
            DateTime.now().isAfter(deadline)) {
          CaptureLog.log('Panorama job poll gave up: $error');
          return const PanoramaFollowResult.pending(
            'Connection interrupted. Resuming automatically. '
            'Your photos are safe.',
          );
        }
        await _backoff(attempt);
        continue;
      }
      if (job['sessionId'] != sessionId) {
        return const PanoramaFollowResult.failed(
          'The panorama job belongs to a different capture.',
        );
      }
      final status = '${job['status']}';
      if (status == 'error' || status == 'failed') {
        return PanoramaFollowResult.failed(
          '${job['errorMessage'] ?? 'Panorama generation failed.'} '
          'Your photographs are saved — retry the panorama, or recapture '
          'manually if the photos themselves are the problem.',
        );
      }
      if (status == 'done') {
        onStage?.call(PanoramaJobStage.downloading, job);
        try {
          final downloaded = await _downloadPanorama(
            job: job,
            directory: directory,
          );
          return PanoramaFollowResult.ready(downloaded);
        } on Object catch (error) {
          CaptureLog.log('Panorama download failed: $error');
          // The panorama EXISTS on the server. This must never trigger another
          // stitching job — only another download.
          return PanoramaFollowResult.failed(
            'Your panorama is ready on Sitewise but could not be saved to '
            'this device yet. Retry to download it again — the panorama does '
            'not need to be generated twice.',
            panoramaId: job['panoramaId'] as String?,
          );
        }
      }
      onStage?.call(
        status == 'queued'
            ? PanoramaJobStage.queued
            : PanoramaJobStage.processing,
        job,
      );
      if (DateTime.now().isAfter(deadline)) {
        return PanoramaFollowResult.pending(
          status == 'queued'
              ? 'Your photos are saved. Panorama processing will begin shortly.'
              : 'Your panorama is still being created. This can take a few '
                  'minutes on a busy server.',
        );
      }
      await _backoff(attempt);
    }
  }

  /// Exponential backoff with jitter, capped so the UI stays responsive.
  Future<void> _backoff(int attempt) {
    final base = math.min(6000, 400 * (1 << math.min(attempt, 4)));
    final jitter = _random.nextInt(400);
    return Future<void>.delayed(Duration(milliseconds: base + jitter));
  }

  Future<Map<String, dynamic>> _downloadPanorama({
    required Map<String, dynamic> job,
    required String directory,
  }) async {
    var id = job['panoramaId'] as String?;
    var path = job['outputStoragePath'] as String?;
    if (id == null || !RegExp(r'^[a-fA-F0-9-]{36}$').hasMatch(id) ||
        path == null || path.isEmpty) {
      // `done` without a panorama id means the canonical row is not linked to
      // this job's output; ask the canonical endpoint once before giving up.
      throw const BackendHandoffFailure('The completed panorama is not available.');
    }
    final view = await _client.get('$_api/panoramas/$id/view');
    if (view['panoramaId'] != id) {
      throw const BackendHandoffFailure('Panorama response does not match the job.');
    }
    final uri = Uri.tryParse('${view['viewUrl']}');
    if (uri == null || !uri.hasAuthority || uri.scheme != 'https') {
      throw const BackendHandoffFailure('The panorama viewing link is invalid.');
    }
    final file = File(p.join(directory, 'server_$id.jpg'));
    // Already downloaded by an earlier launch: the same artifact id is the
    // same bytes, so this is the resumed success case, not a second download.
    if (await file.exists()) {
      return <String, dynamic>{
        'id': id,
        'storagePath': path,
        'localPath': file.path,
        'verificationStatus': view['verificationStatus'],
      };
    }
    final temporary = File('${file.path}.partial');
    await file.parent.create(recursive: true);
    try {
      final req = await _http.getUrl(uri).timeout(_uploadTimeout);
      final response = await req.close().timeout(_uploadTimeout);
      if (response.statusCode != 200) {
        throw const BackendHandoffFailure('Could not download the generated panorama.');
      }
      await response.pipe(temporary.openWrite()).timeout(_uploadTimeout);
      if (await temporary.length() < 4) {
        throw const BackendHandoffFailure('The generated panorama is empty.');
      }
      final handle = await temporary.open();
      try {
        final first = await handle.read(2);
        await handle.setPosition(await handle.length() - 2);
        final last = await handle.read(2);
        if (first.length != 2 || last.length != 2 || first[0] != 255 ||
            first[1] != 216 || last[0] != 255 || last[1] != 217) {
          throw const BackendHandoffFailure(
            'The generated panorama is not a complete JPEG.',
          );
        }
      } finally {
        await handle.close();
      }
      await temporary.rename(file.path);
      return <String, dynamic>{
        'id': id,
        'storagePath': path,
        'localPath': file.path,
        'verificationStatus': view['verificationStatus'],
      };
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  /// Job creation and following in one call, kept for callers that want the
  /// old shape. Prefer the split methods: they can report a real stage.
  Future<Map<String, dynamic>> finishEnhanced({
    required String stationId,
    required String sessionId,
    required String directory,
  }) async {
    final job = await ensurePanoramaJob(stationId: stationId, sessionId: sessionId);
    final jobId = job['jobId'] as String;
    final result = await followPanoramaJob(
      stationId: stationId,
      sessionId: sessionId,
      jobId: jobId,
      directory: directory,
    );
    if (result.panorama != null) return result.panorama!;
    throw BackendHandoffFailure(
      result.failureMessage ?? 'Panorama is still processing. Retry to resume the same job.',
    );
  }

  /// SHA-256 of one file, streamed. Public so the capture-time verifier can
  /// confirm a single photograph without building the whole upload queue.
  Future<String> checksumOf(String path) => _checksum(path);

  /// Explicit Agent acceptance of a generated candidate. This is the only
  /// mobile call that changes the active inspection panorama reference.
  Future<Map<String, dynamic>> acceptPanoramaCandidate({
    required String sessionId,
    required String panoramaId,
    String? expectedActivePanoramaId,
  }) async {
    try {
      return await _client.post(
        '$_api/sessions/$sessionId/panoramas/$panoramaId/accept',
        <String, dynamic>{
          'expected_active_panorama_id': expectedActivePanoramaId,
        },
      );
    } on Object catch (error) {
      throw _friendlyFailure(error);
    }
  }

  /// Cancels a candidate attempt server-side. The active panorama and all
  /// uploaded originals are preserved.
  Future<void> cancelCaptureSession(String sessionId) async {
    try {
      await _client.post(
        '$_api/sessions/$sessionId/cancel',
        const <String, dynamic>{},
      );
    } on Object catch (error) {
      throw _friendlyFailure(error);
    }
  }

  /// Sends one original photograph to FastAPI. The backend owns the Supabase
  /// write; this method never requests a signed URL and never touches Storage.
  Future<Map<String, dynamic>> sendFrameToBackend({
    required String sessionId,
    required CapturedFrame frame,
    required String checksum,
    Map<String, Object?>? qualityReport,
  }) async {
    final metadata = <String, Object?>{
      'checksum_sha256': checksum,
      if (frame.imageWidth > 0) 'image_width': frame.imageWidth,
      if (frame.imageHeight > 0) 'image_height': frame.imageHeight,
      'captured_at': frame.capturedAt.toUtc().toIso8601String(),
      'capture_pose': <String, Object?>{
        'x': frame.cameraOrientation.x,
        'y': frame.cameraOrientation.y,
        'z': frame.cameraOrientation.z,
        'w': frame.cameraOrientation.w,
        'sourceImageWidth': frame.sourceImageWidth,
        'sourceImageHeight': frame.sourceImageHeight,
        'cropOffsetX': frame.cropOffsetX,
        'cropOffsetY': frame.cropOffsetY,
        'targetYawDegrees': frame.targetYawDegrees,
        'targetPitchDegrees': frame.targetPitchDegrees,
        'alignmentErrorDeg': frame.alignmentErrorDeg,
        'toleranceDeg': frame.toleranceDeg,
        'quality': ?qualityReport,
      },
    };
    try {
      return await _client.uploadFileMultipart(
        '$_api/sessions/$sessionId/frames/${frame.targetId}/photo',
        fields: <String, String>{'metadata': jsonEncode(metadata)},
        fileField: 'file',
        filename: '${frame.targetId}.jpg',
        filePath: frame.imagePath,
        contentType: 'image/jpeg',
      );
    } on Object catch (error) {
      throw _friendlyFailure(error);
    }
  }

  Future<String> uploadFrame({
    required String sessionId,
    required CapturedFrame frame,
    required String checksum,
    Map<String, Object?>? qualityReport,
    ProcessingDerivative? derivative,
  }) async {
    try {
      final permission = await _issueUploadUrls(sessionId, <int>[
        frame.targetId,
      ]);
      await _uploadOne(
        sessionId: sessionId,
        frame: frame,
        checksum: checksum,
        permission: permission[frame.targetId],
        qualityReport: qualityReport,
        derivative: derivative,
        onProgress: () {},
      );
      return permission[frame.targetId]!['storagePath'] as String;
    } on Object catch (error) {
      throw _friendlyFailure(error);
    }
  }

  /// Uploads and confirms the device-stitched panorama — the cloud draft
  /// (Layer B). Verifiable server-side before any canonical row exists.
  /// Returns the confirmation payload (`panoramaId`, `storagePath`,
  /// `width`, `height`). Safe to call again: the same verified object
  /// returns the existing row untouched.
  ///
  /// [deviceQuality] is the device's own frame-quality summary (how many
  /// photographs carry warnings, how many are unreadable). It is merged into
  /// the coverage report sent with the confirmation so the backend can store
  /// it alongside its own panorama verification — evidence, never a gate.
  Future<Map<String, dynamic>> syncPanoramaDraft({
    required String sessionId,
    required int propertyId,
    required String panoramaPath,
    required String checksum,
    Map<String, Object?>? deviceQuality,
  }) async {
    try {
      return await _uploadAndConfirmPanorama(
        sessionId: sessionId,
        propertyId: propertyId,
        panoramaPath: panoramaPath,
        checksum: checksum,
        deviceQuality: deviceQuality,
      );
    } on Object catch (error) {
      throw _friendlyFailure(error);
    }
  }

  /// The canonical panorama metadata for a property, when the backend has
  /// one. `null` on a 404 — the honest "not uploaded yet" state.
  Future<Map<String, dynamic>?> latestPropertyPanorama(int propertyId) async {
    try {
      return await _client.get('$_api/properties/$propertyId/panorama');
    } on NotFoundFailure {
      return null;
    }
  }

  /// The backend's capture-quality report for one session: the registration,
  /// coverage and seam verification the server ran, plus per-frame integrity
  /// evidence. `null` when the session does not exist or the checks have not
  /// run yet — consumers must treat null as "not available", never "failed".
  Future<Map<String, dynamic>?> fetchSessionQuality(String sessionId) async {
    try {
      return await _client.get('$_api/sessions/$sessionId/quality');
    } on NotFoundFailure {
      return null;
    }
  }

  Future<List<CapturedFrame>> _validated(
    List<CapturedFrame> frames,
    int total,
  ) async {
    final ordered = List<CapturedFrame>.of(frames)
      ..sort((a, b) => a.targetId.compareTo(b.targetId));
    final seen = <int>{};
    for (final frame in ordered) {
      if (frame.targetId < 1 || frame.targetId > total) {
        throw BackendHandoffFailure(
          'Capture frame ${frame.targetId} is outside the 1–$total target '
          'range.',
        );
      }
      if (!seen.add(frame.targetId)) {
        throw BackendHandoffFailure(
          'Duplicate capture frame for target ${frame.targetId}.',
        );
      }
      if (!await File(frame.imagePath).exists()) {
        throw BackendHandoffFailure(
          'The photograph for target ${frame.targetId} is missing on disk '
          '(${frame.imagePath}). Retake this target and try again.',
        );
      }
    }
    if (ordered.length < total) {
      final missing = <int>[
        for (var id = 1; id <= total; id++)
          if (!seen.contains(id)) id,
      ];
      throw BackendHandoffFailure(
        'All $total photographs are needed. Missing targets: '
        '${missing.take(6).join(', ')}'
        '${missing.length > 6 ? ' (+${missing.length - 6} more)' : ''}.',
      );
    }
    final paths = <String>[for (final frame in ordered) frame.imagePath];
    if (paths.toSet().length != paths.length) {
      throw const BackendHandoffFailure(
        'Two capture frames point at one image file, so the frame set is not '
        'usable.',
      );
    }
    return ordered;
  }

  /// Streams one JPEG through SHA-256 without holding it in memory.
  Future<String> _checksum(String path) async {
    final sink = _DigestSink();
    final digest = sha256.startChunkedConversion(sink);
    // File.openRead's first argument is a START OFFSET, not a chunk size.
    // Always read from byte 0; the stream's default buffering is already
    // incremental, so this never holds the whole JPEG in memory.
    await File(path).openRead().forEach(digest.add);
    digest.close();
    final value = sink.value;
    if (value == null) {
      throw BackendHandoffFailure('The photograph at $path could not be read.');
    }
    return value.toString();
  }

  Future<Map<int, String>> _confirmedChecksums(String sessionId) async {
    final rows = await _client.get('$_api/sessions/$sessionId/frames');
    final list = rows['frames'];
    final confirmed = <int, String>{};
    if (list is List) {
      for (final row in list) {
        if (row is! Map) continue;
        if ((row['uploadStatus'] as String?) != 'confirmed') continue;
        final target = (row['targetIndex'] as num?)?.toInt();
        final checksum = row['checksumSha256'] as String?;
        if (target != null && checksum != null && checksum.isNotEmpty) {
          confirmed[target] = checksum;
        }
      }
    }
    return confirmed;
  }

  Future<_BackupOutcome> _backupFrames({
    required String stationId,
    required String sessionId,
    required List<CapturedFrame> frames,
    required Map<int, String> checksums,
    required void Function(String stage)? onStage,
    required void Function(int processed, int total)? onFrameProcessed,
    required void Function(BackendHandoffProgress progress)? onProgress,
  }) async {
    final confirmed = await _confirmedChecksums(sessionId);
    final toUpload = <int>[];
    final toRepair = <int>[];
    for (final entry in checksums.entries) {
      if (confirmed[entry.key] == entry.value) continue;
      if (confirmed.containsKey(entry.key)) {
        // The object is already in Storage. Re-confirm its metadata with the
        // correct digest; FastAPI verifies the stored bytes first.
        toRepair.add(entry.key);
      } else {
        toUpload.add(entry.key);
      }
    }

    var processed = checksums.length - toUpload.length - toRepair.length;
    final byTarget = <int, CapturedFrame>{
      for (final frame in frames) frame.targetId: frame,
    };
    onFrameProcessed?.call(processed, checksums.length);
    onProgress?.call(
      BackendHandoffProgress(
        stage: BackendHandoffStage.framesBackingUp,
        processed: processed,
        total: checksums.length,
      ),
    );

    final failed = <int>[];
    if (toUpload.isNotEmpty) {
      onStage?.call('Backing up original photographs...');
      for (
        var offset = 0;
        offset < toUpload.length;
        offset += _uploadConcurrency
      ) {
        final batch = <int>[
          for (final target in toUpload.skip(offset).take(_uploadConcurrency))
            target,
        ];
        // One batch's permissions can be refused on its own (the service is
        // briefly unavailable, or a session rule changed). That must not
        // abandon the photographs that have not been attempted yet.
        Map<int, Map<String, dynamic>> permissions;
        try {
          permissions = await _issueUploadUrls(sessionId, batch);
        } on Object catch (error) {
          CaptureLog.log(
            'Upload permissions for ${batch.join(",")} were refused: $error',
          );
          failed.addAll(batch);
          continue;
        }
        final outcomes = await Future.wait(
          batch.map((target) async {
            try {
              await _uploadOne(
                sessionId: sessionId,
                frame: byTarget[target]!,
                checksum: checksums[target]!,
                permission: permissions[target],
                onProgress: () {
                  processed++;
                  onFrameProcessed?.call(processed, checksums.length);
                  onProgress?.call(
                    BackendHandoffProgress(
                      stage: BackendHandoffStage.framesBackingUp,
                      processed: processed,
                      total: checksums.length,
                    ),
                  );
                },
              );
              return true;
            } on Object catch (error) {
              // A duplicate object, a stale checksum or a transient refusal
              // is this photograph's problem, not the queue's.
              CaptureLog.log('Backup of target $target failed: $error');
              return false;
            }
          }),
        );
        for (var index = 0; index < batch.length; index++) {
          if (!outcomes[index]) failed.add(batch[index]);
        }
        await _record(
          stationId,
          FrameSyncStatus.uploading,
          backendSessionId: sessionId,
          backupSyncStatus: FrameSyncStatus.uploading,
          backupUploaded: processed,
          backupTotal: checksums.length,
        );
        onStage?.call(
          'Backing up original photographs ($processed/${checksums.length})...',
        );
      }
    }

    if (toRepair.isNotEmpty) {
      processed += await _repairConfirmed(
        sessionId: sessionId,
        propertyId: (await _store.getSession(stationId))?.propertyId,
        frames: frames,
        checksums: checksums,
        targets: toRepair,
        failed: failed,
      );
    }
    if (failed.isNotEmpty) {
      throw BackendHandoffFailure(
        '${failed.length} of ${checksums.length} photographs could not be '
        'backed up yet. They are kept on this device — retry the '
        'synchronization.',
      );
    }
    return _BackupOutcome(processed: processed, total: checksums.length);
  }

  /// Re-confirms frames whose stored object predates the current digest.
  /// Returns how many were repaired; a single failure is logged and recorded
  /// in [failed] so the remaining photographs still get their chance.
  Future<int> _repairConfirmed({
    required String sessionId,
    required int? propertyId,
    required List<CapturedFrame> frames,
    required Map<int, String> checksums,
    required List<int> targets,
    required List<int> failed,
  }) async {
    if (propertyId == null) {
      failed.addAll(targets);
      return 0;
    }
    final byTarget = <int, CapturedFrame>{
      for (final frame in frames) frame.targetId: frame,
    };
    var repaired = 0;
    for (final target in targets) {
      try {
        await _confirm(
          sessionId,
          byTarget[target]!,
          checksums[target]!,
          'properties/$propertyId/sessions/$sessionId/frames/$target.jpg',
          // Nothing was uploaded in this run, so the stored bytes must be
          // proven to be this photograph before the metadata is rewritten.
          uploaded: false,
        );
        repaired++;
      } on Object catch (error) {
        CaptureLog.log('Re-confirmation of target $target failed: $error');
        failed.add(target);
      }
    }
    return repaired;
  }

  Future<Map<int, Map<String, dynamic>>> _issueUploadUrls(
    String sessionId,
    List<int> targets, {
    List<int> overwrite = const <int>[],
  }) async {
    final issued = await _client.post(
      '$_api/sessions/$sessionId/upload-urls',
      <String, dynamic>{
        'targets': targets,
        if (overwrite.isNotEmpty) 'overwrite': overwrite,
      },
    );
    final uploads = issued['uploads'];
    if (uploads is! List) {
      throw const BackendHandoffFailure(
        'The Sitewise service returned no upload permissions.',
      );
    }
    final byTarget = <int, Map<String, dynamic>>{
      for (final entry in uploads)
        if (entry is Map && entry['targetIndex'] is num)
          (entry['targetIndex'] as num).toInt(): Map<String, dynamic>.from(
            entry,
          ),
    };
    for (final target in targets) {
      if (!byTarget.containsKey(target)) {
        throw BackendHandoffFailure(
          'The Sitewise service returned no upload permission for target '
          '$target.',
        );
      }
    }
    return byTarget;
  }

  /// True when Storage already holds this target's object, so the device must
  /// confirm the stored bytes instead of uploading them again. This is the
  /// normal resumed-backup case: Supabase refuses to mint an upload token for
  /// an occupied path, so the backend reports the object rather than failing.
  bool _alreadyStored(Map<String, dynamic>? permission) =>
      permission != null && permission['alreadyStored'] == true;

  /// A conflict the device can resolve by replacing the stored object: the
  /// bytes are not there yet, or they are not this photograph (a stale object
  /// from an interrupted attempt). Authorization, cancellation and review
  /// conflicts must NOT be retried with an overwrite.
  bool _isReplaceableConflict(Object error) {
    if (error is! ConflictFailure) return false;
    final message = error.message.toLowerCase();
    return message.contains('checksum') ||
        message.contains('not reached storage') ||
        message.contains('upload this frame again') ||
        message.contains('upload it again');
  }

  Future<Map<String, dynamic>> _issuePanoramaUploadUrl(
    String sessionId, {
    bool overwrite = false,
  }) async {
    final issued = await _client.post(
      '$_api/sessions/$sessionId/panorama/upload-url'
      '${overwrite ? '?overwrite=true' : ''}',
      const <String, dynamic>{},
    );
    final storagePath = issued['storagePath'] as String?;
    if (storagePath == null || storagePath.isEmpty) {
      throw const BackendHandoffFailure(
        'The Sitewise service returned no panorama upload permission.',
      );
    }
    final uploadUrl = issued['uploadUrl'] as String?;
    final alreadyStored = issued['alreadyStored'] == true;
    if (!alreadyStored && (uploadUrl == null || uploadUrl.isEmpty)) {
      throw const BackendHandoffFailure(
        'The Sitewise service returned no panorama upload permission.',
      );
    }
    return <String, dynamic>{
      'uploadUrl': uploadUrl,
      'storagePath': storagePath,
      'headers': issued['headers'],
      'alreadyStored': alreadyStored,
    };
  }

  /// Streams one file to Storage, refreshing an expired permission and
  /// retrying transient failures. Returns the permission that finally
  /// succeeded (it may be a refreshed one). Never called for an object the
  /// backend already reported as stored.
  Future<Map<String, dynamic>> _putWithRetries({
    required String filePath,
    required int target,
    required Map<String, dynamic> permission,
    required bool overwrite,
    required Future<Map<String, dynamic>> Function({required bool overwrite})
    refresh,
  }) async {
    var upload = permission;
    var expiredRefreshes = 0;
    var networkAttempts = 0;
    while (true) {
      final url = upload['uploadUrl'] as String?;
      if (url == null || url.isEmpty) {
        throw BackendHandoffFailure(
          'The upload permission for target $target is incomplete.',
        );
      }
      final outcome = await _putFile(
        filePath: filePath,
        target: target,
        uri: Uri.parse(url),
        headers: upload['headers'],
      );
      if (outcome == _PutOutcome.stored) return upload;
      if (outcome == _PutOutcome.expired && expiredRefreshes < 2) {
        expiredRefreshes++;
        upload = await refresh(overwrite: overwrite);
        continue;
      }
      if (outcome == _PutOutcome.retryable &&
          networkAttempts < _maxUploadAttempts - 1) {
        networkAttempts++;
        await Future<void>.delayed(Duration(seconds: networkAttempts));
        continue;
      }
      switch (outcome) {
        case _PutOutcome.expired:
          throw BackendHandoffFailure(
            'Uploading target $target needs a fresh permission. Your '
            'photographs are kept — retry the synchronization.',
          );
        case _PutOutcome.retryable:
          throw BackendHandoffFailure(
            'Uploading target $target did not complete. Your photographs '
            'are kept — retry the synchronization.',
          );
        case _PutOutcome.fatal:
          throw BackendHandoffFailure(
            'Target $target could not be uploaded to Sitewise. Your '
            'photographs are kept — retry the synchronization.',
          );
        case _PutOutcome.stored:
          return upload;
      }
    }
  }

  Future<Map<String, dynamic>> _uploadAndConfirmPanorama({
    required String sessionId,
    required int propertyId,
    required String panoramaPath,
    required String checksum,
    Map<String, Object?>? deviceQuality,
  }) async {
    final coverage = await _coverageFor(panoramaPath, checksum);
    var permission = await _issuePanoramaUploadUrl(sessionId);
    var replaced = false;
    while (true) {
      final stored = _alreadyStored(permission);
      if (!stored) {
        permission = await _putWithRetries(
          filePath: panoramaPath,
          target: 0,
          permission: permission,
          overwrite: replaced,
          refresh: ({required bool overwrite}) =>
              _issuePanoramaUploadUrl(sessionId, overwrite: overwrite),
        );
      }
      final storagePath = permission['storagePath'] as String?;
      if (storagePath == null || storagePath.isEmpty) {
        throw const BackendHandoffFailure(
          'The panorama upload permission has no storage path.',
        );
      }
      try {
        return await _client.post(
          '$_api/sessions/$sessionId/panorama',
          <String, dynamic>{
            'storage_path': storagePath,
            'checksum_sha256': checksum,
            'coverage_report': <String, Object?>{
              'source': 'device_capture_v2',
              'stitched_on': 'flutter',
              'photo_coverage': ?coverage,
              'frame_quality': ?deviceQuality,
            },
          },
        );
      } on ConflictFailure catch (error) {
        // The stored object is not this panorama (a stale upload from an
        // earlier attempt). Replace it once, then confirm again. A published
        // or approved tour refuses the replacement — that refusal is final.
        if (replaced || !_isReplaceableConflict(error)) rethrow;
        replaced = true;
        permission = await _issuePanoramaUploadUrl(sessionId, overwrite: true);
      }
    }
  }

  Future<Map<String, Object?>?> _coverageFor(
    String panoramaPath,
    String checksum,
  ) async {
    final file = File(p.join(p.dirname(panoramaPath), 'coverage_report.json'));
    if (!await file.exists()) return null;
    try {
      final report = jsonDecode(await file.readAsString());
      if (report is! Map || report['panoramaSha256'] != checksum) return null;
      final percentages = report['coveragePercent'];
      return {
        'panorama_sha256': checksum,
        'photo_coverage_percent': percentages is Map
            ? percentages['single']
            : null,
        'worst_viewport_gap_percent': report['worstViewportGapPercent'],
        'gap_filled_pixels': report['gapFilledPixels'],
      };
    } on FormatException {
      return null;
    } on FileSystemException {
      return null;
    }
  }

  Future<void> _uploadOne({
    required String sessionId,
    required CapturedFrame frame,
    required String checksum,
    required Map<String, dynamic>? permission,
    Map<String, Object?>? qualityReport,
    ProcessingDerivative? derivative,
    required void Function() onProgress,
  }) async {
    if (permission == null) {
      throw BackendHandoffFailure(
        'The Sitewise service returned no upload permission for target '
        '${frame.targetId}.',
      );
    }
    var upload = permission;
    var replaced = false;
    while (true) {
      final stored = _alreadyStored(upload);
      if (!stored) {
        upload = await _putWithRetries(
          // The derivative when one exists: the same photograph, scaled down
          // for transfer, with the original still on the device. Its digest is
          // the one the queue declared, so the server's integrity check is
          // against the bytes it actually receives.
          filePath: derivative?.path ?? frame.imagePath,
          target: frame.targetId,
          permission: upload,
          overwrite: replaced,
          refresh: ({required bool overwrite}) => _refreshUploadUrl(
            sessionId,
            frame.targetId,
            overwrite: overwrite,
          ),
        );
      }
      final storagePath = upload['storagePath'] as String?;
      if (storagePath == null || storagePath.isEmpty) {
        throw BackendHandoffFailure(
          'The upload permission for target ${frame.targetId} has no storage '
          'path.',
        );
      }
      try {
        // `uploaded: false` tells the backend the object predates this
        // confirmation, so it reads the stored bytes back and compares them
        // with this photograph's digest before registering the frame.
        await _confirm(
          sessionId,
          frame,
          checksum,
          storagePath,
          qualityReport: qualityReport,
          uploaded: !stored,
          derivative: derivative,
        );
        onProgress();
        return;
      } on ConflictFailure catch (error) {
        // Storage holds bytes that are not this photograph, or the object is
        // not there yet. Ask for an authorized replacement and upload once;
        // any other conflict (authorization, cancelled session, review rules)
        // is final and must not be overwritten.
        if (replaced || !_isReplaceableConflict(error)) rethrow;
        replaced = true;
        upload = await _refreshUploadUrl(
          sessionId,
          frame.targetId,
          overwrite: true,
        );
      }
    }
  }

  Future<Map<String, dynamic>> _refreshUploadUrl(
    String sessionId,
    int target, {
    bool overwrite = false,
  }) async {
    final issued = await _issueUploadUrls(sessionId, <int>[
      target,
    ], overwrite: overwrite ? <int>[target] : const <int>[]);
    return issued[target]!;
  }

  /// Opens one JPEG, streams it to Storage, then closes it. No byte buffer is
  /// retained between uploads.
  Future<_PutOutcome> _putFile({
    required String filePath,
    required int target,
    required Uri uri,
    Object? headers,
  }) async {
    final file = File(filePath);
    try {
      final length = await file.length();
      final request = await _http.openUrl('PUT', uri);
      request.headers.contentType = ContentType('image', 'jpeg');
      request.headers.contentLength = length;
      if (headers is Map) {
        for (final entry in headers.entries) {
          final key = entry.key.toString().toLowerCase();
          if (key != 'content-type') {
            request.headers.set(entry.key as String, entry.value.toString());
          }
        }
      }
      await request.addStream(file.openRead());
      final response = await request.close().timeout(_uploadTimeout);
      final body = await response.transform(utf8.decoder).join();
      final status = response.statusCode;
      if (status >= 200 && status < 300) return _PutOutcome.stored;
      if (status == 409) {
        // Supabase signed uploads are immutable: a repeat PUT of the same
        // bytes answers Duplicate. That is the idempotent success case.
        return _PutOutcome.stored;
      }
      final lowered = body.toLowerCase();
      if (status == 400 &&
          (lowered.contains('keyalreadyexists') ||
              lowered.contains('already exists'))) {
        return _PutOutcome.stored;
      }
      if (status == 401 || status == 403) return _PutOutcome.expired;
      if (status == 408 || status == 429 || status >= 500) {
        return _PutOutcome.retryable;
      }
      return _PutOutcome.fatal;
    } on TimeoutException {
      return _PutOutcome.retryable;
    } on SocketException {
      return _PutOutcome.retryable;
    } on HttpException {
      return _PutOutcome.retryable;
    } on Object catch (error) {
      CaptureLog.log('Upload of target $target failed locally: $error');
      return _PutOutcome.fatal;
    }
  }

  Future<void> _confirm(
    String sessionId,
    CapturedFrame frame,
    String checksum,
    String storagePath, {
    Map<String, Object?>? qualityReport,
    bool uploaded = true,
    ProcessingDerivative? derivative,
  }) async {
    // Every geometric number is expressed in the pixels that were actually
    // uploaded. When the upload is a uniformly scaled derivative, the declared
    // dimensions, the pre-crop source size and the crop origin all scale by
    // the same factor — which keeps the derived focal length and the principal
    // point exact (the server reconstructs the lens from the declared height).
    // Declaring the *original* size for a smaller upload would make the server
    // believe the lens is twice as long as it is.
    final scale = derivative?.scale ?? 1.0;
    final imageWidth = derivative?.width ?? frame.imageWidth;
    final imageHeight = derivative?.height ?? frame.imageHeight;
    final sourceWidth = scale == 1.0
        ? frame.sourceImageWidth
        : (frame.sourceImageWidth * scale).round();
    final sourceHeight = scale == 1.0
        ? frame.sourceImageHeight
        : (frame.sourceImageHeight * scale).round();
    final cropX = scale == 1.0
        ? frame.cropOffsetX
        : (frame.cropOffsetX * scale).round();
    final cropY = scale == 1.0
        ? frame.cropOffsetY
        : (frame.cropOffsetY * scale).round();
    await _client.post('$_api/sessions/$sessionId/frames', <String, dynamic>{
      'target_index': frame.targetId,
      'storage_path': storagePath,
      'checksum_sha256': checksum,
      // False = the object was already in storage and this confirmation must
      // verify the stored bytes against the digest above.
      'uploaded': uploaded,
      if (imageWidth > 0) 'image_width': imageWidth,
      if (imageHeight > 0) 'image_height': imageHeight,
      'capture_pose': <String, Object?>{
        'x': frame.cameraOrientation.x,
        'y': frame.cameraOrientation.y,
        'z': frame.cameraOrientation.z,
        'w': frame.cameraOrientation.w,
        'sourceImageWidth': sourceWidth,
        'sourceImageHeight': sourceHeight,
        'cropOffsetX': cropX,
        'cropOffsetY': cropY,
        // These are the guided target and capture gate observations, not
        // claimed camera calibration. The quaternion above is the device pose.
        'targetYawDegrees': frame.targetYawDegrees,
        'targetPitchDegrees': frame.targetPitchDegrees,
        'alignmentErrorDeg': frame.alignmentErrorDeg,
        'toleranceDeg': frame.toleranceDeg,
        // Device quality evidence rides inside the open pose metadata — the
        // worker reads only the keys it knows, so this stays additive.
        'quality': ?qualityReport,
      },
      'captured_at': frame.capturedAt.toUtc().toIso8601String(),
    });
  }

  Future<void> _record(
    String stationId,
    FrameSyncStatus syncStatus, {
    String? backendSessionId,
    String? backendJobId,
    bool clearBackendJobId = false,
    bool clearLastError = false,
    String? error,
    FrameSyncStatus? panoramaSyncStatus,
    FrameSyncStatus? backupSyncStatus,
    int? backupUploaded,
    int? backupTotal,
    String? backendPanoramaId,
    bool clearBackendPanoramaId = false,
  }) async {
    try {
      await _store.saveBackendHandoff(
        sessionId: stationId,
        syncStatus: syncStatus,
        backendSessionId: backendSessionId,
        backendJobId: backendJobId,
        clearBackendJobId: clearBackendJobId,
        clearLastError: clearLastError,
        error: error,
        panoramaSyncStatus: panoramaSyncStatus,
        backupSyncStatus: backupSyncStatus,
        backupUploaded: backupUploaded,
        backupTotal: backupTotal,
        backendPanoramaId: backendPanoramaId,
        clearBackendPanoramaId: clearBackendPanoramaId,
      );
    } on Object {
      // Bookkeeping must never cost the handoff; the backend rows are the
      // source of truth and a retry re-derives the state from the server.
      CaptureLog.log('Handoff state could not be recorded for $stationId');
    }
  }
}

class _BackupOutcome {
  const _BackupOutcome({required this.processed, required this.total});

  final int processed;
  final int total;
}

/// Receives the completed digest from [sha256.startChunkedConversion].
/// The crypto package keeps its own DigestSink private, so the coordinator
/// supplies the one-line Sink implementation here.
class _DigestSink implements Sink<Digest> {
  Digest? _value;

  Digest? get value => _value;

  @override
  void add(Digest data) => _value = data;

  @override
  void close() {}
}
