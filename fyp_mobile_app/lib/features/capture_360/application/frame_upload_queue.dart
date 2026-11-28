import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:shared_logic/shared_logic.dart' show readableFailure;

import 'package:fyp/core/di/service_locator.dart';
import 'package:fyp/core/utils/capture_log.dart';
import 'package:fyp/features/capture_360/application/backend_capture_coordinator.dart';
import 'package:fyp/features/capture_360/data/capture_frame_store.dart';
import 'package:fyp/features/capture_360/data/sphere/processing_derivative.dart';
import 'package:fyp/features/capture_360/data/sphere/sitewise_sphere_session_store.dart';
import 'package:fyp/features/capture_360/domain/quality/capture_quality_models.dart';
import 'package:fyp/features/capture_360/domain/sphere/sphere_capture_session.dart';
import 'package:fyp/features/capture_360/domain/sphere/sphere_target.dart'
    show
        kSphereEnhancedPlanVersion,
        kSpherePlanV11TargetCount,
        planForVersion,
        planIsBackendStitched,
        sitewisePlanVersionForCount;

/// One active photograph transfer. The previous direct-to-Supabase queue ran
/// three; the FastAPI receive endpoint is deliberately serialised so capture,
/// ORB and the upload stream cannot compete for the same memory and radio.
const int kFrameUploadConcurrency = 1;

/// Per-item attempts inside one drain before the item parks as
/// `failed_retryable`. `resume()` re-arms parked items — nothing is ever
/// deleted because an upload failed.
const int kMaxDrainAttempts = 5;

/// The durable upload states of one queued unit. These are the spec's states
/// verbatim; `uploading` is transitory (crash-safe: it re-reads as `pending`
/// after a restart because nothing else could have finished it).
enum FrameUploadState {
  pending('pending'),
  uploading('uploading'),
  confirmed('confirmed'),
  failedRetryable('failed_retryable');

  const FrameUploadState(this.wireName);
  final String wireName;

  static FrameUploadState fromWire(String? value) =>
      FrameUploadState.values.firstWhere(
        (s) => s.wireName == value,
        orElse: () => FrameUploadState.pending,
      );
}

/// One queued photograph's persistent upload record.
class FrameUploadRecord {
  FrameUploadRecord({
    required this.targetId,
    required this.localFilePath,
    required this.checksumSha256,
    this.status = FrameUploadState.pending,
    this.storagePath,
    this.retryCount = 0,
    this.lastError,
    this.derivative,
    DateTime? updatedAt,
  }) : updatedAt = updatedAt ?? DateTime.now().toUtc();

  final int targetId;

  /// The original photograph on this device. Never modified or removed by
  /// the queue.
  final String localFilePath;

  /// Digest of the original bytes sent to FastAPI.
  String checksumSha256;

  /// Legacy queue documents may still carry a derivative descriptor. It is
  /// ignored and cleared on the first retry; the current transport sends the
  /// original.
  ProcessingDerivative? derivative;

  FrameUploadState status;
  String? storagePath;
  int retryCount;
  String? lastError;
  DateTime updatedAt;

  /// The file this record sends. The original is the only payload now.
  String get uploadFilePath => localFilePath;

  Map<String, Object?> toJson() => <String, Object?>{
    'target_id': targetId,
    'local_file_path': localFilePath,
    'checksum_sha256': checksumSha256,
    'upload_status': status.wireName,
    'storage_path': storagePath,
    'retry_count': retryCount,
    'last_error': lastError,
    'derivative': derivative?.toJson(),
    'updated_at': updatedAt.toIso8601String(),
  };

  static FrameUploadRecord fromJson(Map<String, Object?> json) =>
      FrameUploadRecord(
        targetId: (json['target_id'] as num?)?.toInt() ?? 0,
        localFilePath: json['local_file_path'] as String? ?? '',
        checksumSha256: json['checksum_sha256'] as String? ?? '',
        status: FrameUploadState.fromWire(json['upload_status'] as String?),
        storagePath: json['storage_path'] as String?,
        retryCount: (json['retry_count'] as num?)?.toInt() ?? 0,
        lastError: json['last_error'] as String?,
        derivative: ProcessingDerivative.fromJson(json['derivative']),
        updatedAt:
            DateTime.tryParse(json['updated_at'] as String? ?? '') ??
            DateTime.now().toUtc(),
      );
}

/// The queued panorama's persistent upload record (the cloud draft).
class PanoramaQueueRecord {
  PanoramaQueueRecord({
    required this.localFilePath,
    required this.checksumSha256,
    this.status = FrameUploadState.pending,
    this.storagePath,
    this.panoramaId,
    this.retryCount = 0,
    this.lastError,
    DateTime? updatedAt,
  }) : updatedAt = updatedAt ?? DateTime.now().toUtc();

  final String localFilePath;
  final String checksumSha256;
  FrameUploadState status;
  String? storagePath;
  String? panoramaId;
  int retryCount;
  String? lastError;
  DateTime updatedAt;

  bool get confirmed =>
      status == FrameUploadState.confirmed && (panoramaId?.isNotEmpty ?? false);

  Map<String, Object?> toJson() => <String, Object?>{
    'local_path': localFilePath,
    'checksum_sha256': checksumSha256,
    'upload_status': status.wireName,
    'storage_path': storagePath,
    'panorama_id': panoramaId,
    'retry_count': retryCount,
    'last_error': lastError,
    'updated_at': updatedAt.toIso8601String(),
  };

  static PanoramaQueueRecord fromJson(Map<String, Object?> json) =>
      PanoramaQueueRecord(
        localFilePath: json['local_path'] as String? ?? '',
        checksumSha256: json['checksum_sha256'] as String? ?? '',
        status: FrameUploadState.fromWire(json['upload_status'] as String?),
        storagePath: json['storage_path'] as String?,
        panoramaId: json['panorama_id'] as String?,
        retryCount: (json['retry_count'] as num?)?.toInt() ?? 0,
        lastError: json['last_error'] as String?,
        updatedAt:
            DateTime.tryParse(json['updated_at'] as String? ?? '') ??
            DateTime.now().toUtc(),
      );
}

/// The on-disk queue document:
/// `<tourRoot>/ar_capture/<stationId>/upload_queue.json`.
///
/// It carries the capture ATTEMPT KEY — the stable per-attempt identity the
/// backend session is derived from. One attempt key per capture attempt is
/// what makes "create one stable backend session per capture attempt" hold
/// without hashing all 38 checksums (impossible after photograph 1), while a
/// replacement capture starts a new attempt and a new session. The document
/// is archived together with the station directory, so an archived attempt
/// can never collide with a new one.
class _QueueDoc {
  _QueueDoc({
    required this.attemptKey,
    this.propertyId,
    Map<int, FrameUploadRecord>? frames,
    this.panorama,
  }) : frames = frames ?? <int, FrameUploadRecord>{};

  final String attemptKey;
  int? propertyId;
  final Map<int, FrameUploadRecord> frames;
  PanoramaQueueRecord? panorama;

  Map<String, Object?> toJson() => <String, Object?>{
    'version': 1,
    'attempt_key': attemptKey,
    'property_id': propertyId,
    'frames': <String, Object?>{
      for (final entry in frames.entries) '${entry.key}': entry.value.toJson(),
    },
    'panorama': panorama?.toJson(),
  };

  static _QueueDoc fromJson(Map<String, Object?> json) {
    final rawFrames = json['frames'];
    final frames = <int, FrameUploadRecord>{};
    if (rawFrames is Map) {
      rawFrames.forEach((key, value) {
        final id = int.tryParse('$key');
        if (id != null && value is Map) {
          frames[id] = FrameUploadRecord.fromJson(
            value.cast<String, Object?>(),
          );
        }
      });
    }
    final rawPanorama = json['panorama'];
    return _QueueDoc(
      attemptKey: json['attempt_key'] as String? ?? _newAttemptKey(),
      propertyId: (json['property_id'] as num?)?.toInt(),
      frames: frames,
      panorama: rawPanorama is Map
          ? PanoramaQueueRecord.fromJson(rawPanorama.cast<String, Object?>())
          : null,
    );
  }
}

String _newAttemptKey() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// The reliable per-photograph upload pipeline.
///
/// After EVERY capture the photograph is persisted locally, its queue record
/// is written to disk (checksum included), and the worker streams one original
/// at a time to FastAPI. FastAPI owns the Supabase write and frame
/// confirmation, so the device never requests signed frame-upload URLs.
/// Panorama drafts join the same document and are drained FIRST, because the
/// panorama is the deliverable.
///
/// Everything here is restart-safe by construction:
///  * every state change is flushed to `upload_queue.json` before the next
///    unit starts;
///  * `uploading` re-reads as `pending` on resume (a killed app cannot have
///    confirmed it — confirmation is the last write);
///  * a failed upload never deletes the local JPEG or the panorama;
///  * the drain is single-flight: repeated wake-ups join the running loop
///    instead of double-uploading.
class FrameUploadQueue {
  FrameUploadQueue._({
    required this.frameStore,
    required this.tourId,
    required String stationId,
  }) : _stationId = stationId,
       _sessions = SitewiseSphereSessionStore(
         frameStore: frameStore,
         tourId: tourId,
         stationId: stationId,
       ),
       _coordinator = BackendCaptureCoordinator(
         client: ServiceLocator.apiClient,
         store: SitewiseSphereSessionStore(
           frameStore: frameStore,
           tourId: tourId,
           stationId: stationId,
         ),
       );

  /// One queue instance per station, process-wide. The capture host, the
  /// preview and the property detail each construct "their" queue, but the
  /// drain must be single-flight across ALL of them — two concurrent drains
  /// of the same document would upload the same frame twice.
  static final Map<String, FrameUploadQueue> _instances =
      <String, FrameUploadQueue>{};

  /// Whether the backend worker produces this session's panorama.
  ///
  /// True for the 56-target enhanced plan and for the adaptive five-ring plan
  /// — both upload originals and wait on the worker, and neither may upload a
  /// device panorama, which the panorama endpoint refuses. The check is by
  /// plan version rather than by count because the adaptive count is derived
  /// from the camera, not fixed.
  static bool _backendStitched(int? requiredTargetCount, {int? planVersion}) {
    if (requiredTargetCount == null) return false;
    if (planVersion != null) {
      return planVersion == kSphereEnhancedPlanVersion &&
              requiredTargetCount == 56 ||
          planIsBackendStitched(planVersion);
    }
    // V4 and V11 both contain 44 targets. An absent version must never pick
    // either geometry based on count alone.
    if (requiredTargetCount == kSpherePlanV11TargetCount) return false;
    if (requiredTargetCount == 56) return true;
    return planIsBackendStitched(
      sitewisePlanVersionForCount(requiredTargetCount),
    );
  }

  /// The queue for one capture station. [stationId] defaults to the tour id
  /// — the same convention the session store uses.
  factory FrameUploadQueue.forTour({
    required CaptureFrameStore frameStore,
    required String tourId,
    String? stationId,
  }) {
    final key = '$tourId|${stationId ?? tourId}';
    return _instances.putIfAbsent(
      key,
      () => FrameUploadQueue._(
        frameStore: frameStore,
        tourId: tourId,
        stationId: stationId ?? tourId,
      ),
    );
  }

  /// Recover device drafts belonging to the signed-in agent on workspace entry.
  static Future<void> restorePanoramaUploads(String accountId) async {
    try {
      final tours = await ServiceLocator.tourService.toursForOwner(accountId);
      for (final tour in tours) {
        try {
          final store = ServiceLocator.frameStore;
          final stationId = await SitewiseSphereSessionStore.stationIdForTour(
            frameStore: store,
            tourId: tour.id,
          );
          final state = await readState(store, tour.id, stationId: stationId);
          if (state.panoramaConfirmed) continue;
          if (await ServiceLocator.tourRepo.tourById(tour.id) == null) continue;
          final path = tour.panoramaPath;
          if (state.panorama != null) {
            FrameUploadQueue.forTour(
              frameStore: store,
              tourId: tour.id,
              stationId: stationId,
            ).resumeInBackground();
          } else if (path != null && await File(path).exists()) {
            await FrameUploadQueue.forTour(
              frameStore: store,
              tourId: tour.id,
              stationId: stationId,
            ).enqueuePanorama(path, propertyId: int.tryParse(tour.propertyId));
          }
        } catch (error) {
          CaptureLog.log(
            'Could not restore panorama upload for ${tour.id}: $error',
          );
        }
      }
    } catch (error) {
      CaptureLog.log('Could not restore panorama uploads: $error');
    }
  }

  final CaptureFrameStore frameStore;
  final String tourId;
  final String _stationId;
  final SitewiseSphereSessionStore _sessions;
  final BackendCaptureCoordinator _coordinator;

  _QueueDoc? _doc;
  Future<_QueueDoc>? _loadingDoc;
  Future<void>? _draining;
  Future<void> _writing = Future<void>.value();
  bool _wakeRequested = false;
  Timer? _panoramaRetry;
  final Map<int, List<Completer<void>>> _frameWaiters =
      <int, List<Completer<void>>>{};
  bool _transfersCancelled = false;
  bool _transportPaused = false;
  Timer? _transportRetry;

  // ------------------------------------------------------------------
  // Document IO.
  // ------------------------------------------------------------------

  Future<File> _docFile() async {
    final root = await frameStore.tourRoot(tourId);
    return File(p.join(root, 'ar_capture', _stationId, 'upload_queue.json'));
  }

  Future<_QueueDoc> _loadOrCreate() async {
    final doc = _doc;
    if (doc != null) return doc;
    final loading = _loadingDoc;
    if (loading != null) return loading;
    final pending = _readOrCreateDocument();
    _loadingDoc = pending;
    try {
      return await pending;
    } finally {
      _loadingDoc = null;
    }
  }

  Future<_QueueDoc> _readOrCreateDocument() async {
    final file = await _docFile();
    if (await file.exists()) {
      try {
        _doc = _QueueDoc.fromJson(
          jsonDecode(await file.readAsString()).cast<String, Object?>(),
        );
        return _doc!;
      } on Object {
        // A corrupt document must not lose the capture: start fresh. The
        // session store still knows the backend session id, and re-queued
        // frames re-confirm idempotently against it.
        CaptureLog.log('Upload queue doc unreadable; starting fresh');
      }
    }
    _doc = _QueueDoc(attemptKey: _newAttemptKey());
    await _flush();
    return _doc!;
  }

  Future<void> _flush() {
    final write = _writing.then((_) async {
      final doc = _doc;
      if (doc == null) return;
      final file = await _docFile();
      await file.parent.create(recursive: true);
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(jsonEncode(doc.toJson()), flush: true);
      await temporary.rename(file.path);
    });
    _writing = write.catchError((Object _) {});
    return write;
  }

  /// The stable attempt key for this station, creating the document if this
  /// is the first touch. Callers that only need the key (the coordinator's
  /// handoff) use this without building the whole queue.
  static Future<String> attemptKeyFor(
    CaptureFrameStore frameStore,
    String tourId, {
    String? stationId,
  }) async {
    final queue = FrameUploadQueue.forTour(
      frameStore: frameStore,
      tourId: tourId,
      stationId: stationId,
    );
    final doc = await queue._loadOrCreate();
    return doc.attemptKey;
  }

  // ------------------------------------------------------------------
  // Streaming SHA-256 (never a whole JPEG in memory).
  // ------------------------------------------------------------------

  Future<String> _checksum(String path) async {
    if (!await File(path).exists()) {
      throw const BackendHandoffFailure('The file to upload is missing.');
    }
    try {
      // Hashing a 10 MB original is CPU work. Keep it off the UI isolate so
      // the CameraX preview and shutter stay responsive while the queue works.
      return await Isolate.run(
        () => _checksumSync(path),
      ).timeout(const Duration(seconds: 20));
    } on Object {
      throw const BackendHandoffFailure('The file could not be read.');
    }
  }

  static String _checksumSync(String path) {
    final sink = _DigestSink();
    final digest = sha256.startChunkedConversion(sink);
    final file = File(path).openSync();
    try {
      while (true) {
        final chunk = file.readSync(1024 * 1024);
        if (chunk.isEmpty) break;
        digest.add(chunk);
      }
    } finally {
      file.closeSync();
    }
    digest.close();
    final value = sink.value;
    if (value == null) {
      throw const BackendHandoffFailure('The file could not be read.');
    }
    return value.toString();
  }

  // ------------------------------------------------------------------
  // Enqueueing.
  // ------------------------------------------------------------------

  /// Queues one saved photograph for upload. Called by the capture host the
  /// moment the JPEG is on disk; returns immediately after the durable write
  /// and wakes the worker. [propertyId] pins the queue to the property the
  /// first time it is seen — before that, the session store's association
  /// (or the handoff) supplies it.
  ///
  /// The original JPEG is the transfer payload and stays untouched on the
  /// device until FastAPI confirms durable receipt.
  Future<void> enqueueFrame(
    CapturedFrame frame, {
    int? propertyId,
  }) async {
    if (_transfersCancelled) return;
    final doc = await _loadOrCreate();
    doc.propertyId ??= propertyId;
    // The FastAPI endpoint receives the original. A scaled derivative is no
    // longer part of the transport: it would be a second byte stream for the
    // same canonical object and would reduce the server's source quality.
    final checksum = await _checksum(frame.imagePath);
    final existing = doc.frames[frame.targetId];
    if (existing != null &&
        existing.status == FrameUploadState.confirmed &&
        existing.checksumSha256 == checksum &&
        existing.derivative == null) {
      // The same bytes are already confirmed. Re-queueing them would reset a
      // confirmed frame to pending and re-upload a photograph the server has
      // already accepted.
      return;
    }
    doc.frames[frame.targetId] = FrameUploadRecord(
      targetId: frame.targetId,
      localFilePath: frame.imagePath,
      checksumSha256: checksum,
    );
    await _flush();
    _wake();
  }

  /// Waits until the single FastAPI transfer path has confirmed [targetId].
  ///
  /// Capture-time verification uses this instead of uploading a second copy
  /// itself. The wait is bounded and does not hold the shutter: the next
  /// photograph can still be captured while this future is pending.
  Future<void> ensureFrameUploaded(
    int targetId, {
    Duration timeout = const Duration(seconds: 90),
  }) async {
    var doc = await _loadOrCreate();
    if (doc.frames[targetId]?.status == FrameUploadState.confirmed) return;
    if (doc.frames[targetId]?.status == FrameUploadState.failedRetryable) {
      doc.frames[targetId]!
        ..status = FrameUploadState.pending
        ..lastError = null;
      await _flush();
    }
    if (!doc.frames.containsKey(targetId)) {
      final frames = await _safeLoadFrames();
      for (final frame in frames) {
        if (frame.targetId == targetId) {
          await enqueueFrame(frame);
          break;
        }
      }
      doc = await _loadOrCreate();
      if (doc.frames[targetId]?.status == FrameUploadState.confirmed) return;
    }
    final completer = Completer<void>();
    _frameWaiters.putIfAbsent(targetId, () => <Completer<void>>[]).add(completer);
    _wake();
    try {
      await completer.future.timeout(timeout);
    } on TimeoutException {
      throw BackendHandoffFailure(
        'Target $targetId has not reached Sitewise yet. Your photograph is '
        'saved; retry the upload when the connection is back.',
      );
    } finally {
      _frameWaiters[targetId]?.remove(completer);
      if (_frameWaiters[targetId]?.isEmpty ?? false) {
        _frameWaiters.remove(targetId);
      }
    }
  }

  void _settleFrameWaiters(int targetId, Object? error) {
    final waiters = _frameWaiters.remove(targetId);
    if (waiters == null) return;
    for (final waiter in waiters) {
      if (waiter.isCompleted) continue;
      if (error == null) {
        waiter.complete();
      } else {
        waiter.completeError(error);
      }
    }
  }

  /// Drops the local candidate pointer after an explicit cancellation. The
  /// candidate JPEG and the session row are retained for audit; only the
  /// "ready for review" marker is cleared so the property keeps showing the
  /// previous active panorama.
  Future<void> discardPanoramaCandidate() async {
    _transfersCancelled = true;
    _transportPaused = true;
    _transportRetry?.cancel();
    _transportRetry = null;
    final doc = await _loadOrCreate();
    if (doc.panorama == null) return;
    doc.panorama = null;
    await _flush();
  }

  /// Queues the stitched panorama (the cloud draft). The panorama is drained
  /// with priority over the frame backups.
  Future<void> enqueuePanorama(String panoramaPath, {int? propertyId}) async {
    final plan = await _sessions.getSession(_stationId);
    if (_backendStitched(
      plan?.requiredTargetCount,
      planVersion: plan?.capturePlanVersion,
    )) {
      // This is the cached backend result, not an upload candidate.
      if (plan?.localPanoramaPath == panoramaPath &&
          plan?.panoramaSyncStatus == FrameSyncStatus.ready) {
        return;
      }
      throw StateError('Enhanced captures use the server-generated panorama.');
    }
    final checksum = await _checksum(panoramaPath);
    var doc = await _loadOrCreate();
    final existing = doc.panorama;
    if (existing != null && existing.checksumSha256 == checksum) {
      if (!existing.confirmed) {
        if (doc.propertyId == null && propertyId != null) {
          doc.propertyId = propertyId;
          await _flush();
        }
        resumeInBackground();
      }
      return;
    }
    if (existing != null) {
      // Cloud objects are immutable within an attempt. Give changed bytes a
      // new session and back up the current originals against that session.
      await _draining;
      doc = _QueueDoc(
        attemptKey: _newAttemptKey(),
        propertyId: doc.propertyId ?? propertyId,
      );
      for (final frame in await _safeLoadFrames()) {
        doc.frames[frame.targetId] = FrameUploadRecord(
          targetId: frame.targetId,
          localFilePath: frame.imagePath,
          checksumSha256: await _checksum(frame.imagePath),
        );
      }
      _doc = doc;
    }
    doc.propertyId ??= propertyId;
    doc.panorama = PanoramaQueueRecord(
      localFilePath: panoramaPath,
      checksumSha256: checksum,
      status: FrameUploadState.pending,
    );
    await _flush();
    _wake();
  }

  // ------------------------------------------------------------------
  // The worker.
  // ------------------------------------------------------------------

  /// Drains the queue until every unit is confirmed or parked as
  /// failed_retryable. Single-flight: a call while a drain runs joins it.
  Future<void> drain() async {
    final running = _draining;
    if (running != null) return running;
    final future = _drainUntilIdle();
    _draining = future;
    try {
      await future;
    } finally {
      if (identical(_draining, future)) {
        _draining = null;
        _panoramaRetry?.cancel();
        final panorama = _doc?.panorama;
        if (panorama != null &&
            !panorama.confirmed &&
            _doc?.propertyId != null) {
          _panoramaRetry = Timer(
            const Duration(minutes: 5),
            _retryForCurrentAccount,
          );
        }
      }
    }
  }

  Future<void> _retryForCurrentAccount() async {
    try {
      if (await ServiceLocator.tourRepo.tourById(tourId) != null) {
        resumeInBackground();
      }
    } catch (error) {
      CaptureLog.log('Could not look up the panorama draft for retry: $error');
    }
  }

  bool _isTransportFailure(Object error) {
    final text = error.toString().toLowerCase();
    return text.contains('unable to reach sitewise') ||
        text.contains('connection') ||
        text.contains('network') ||
        text.contains('socket') ||
        text.contains('timed out') ||
        text.contains('timeout');
  }

  void _pauseTransport() {
    if (_transportPaused) return;
    _transportPaused = true;
    CaptureLog.log(
      'Frame upload transport paused for 30s after a network failure',
    );
    _transportRetry?.cancel();
    // One bounded retry window instead of hammering a dead network for every
    // queued photograph. The photographs stay pending and are retried later.
    _transportRetry = Timer(const Duration(seconds: 30), () {
      _transportRetry = null;
      if (_transfersCancelled) return;
      _transportPaused = false;
      _wake();
    });
  }

  void _wake() {
    _wakeRequested = true;
    unawaited(
      drain().catchError((Object error) {
        CaptureLog.log('Saved captures could not sync: $error');
      }),
    );
  }

  Future<void> _drainUntilIdle() async {
    do {
      _wakeRequested = false;
      await _drainLoop();
    } while (_wakeRequested);
  }

  Future<void> _drainLoop() async {
    if (_transfersCancelled || _transportPaused) return;
    final doc = await _loadOrCreate();
    final propertyId = doc.propertyId ?? await _resolvePropertyId();
    if (propertyId == null) {
      // No property association yet (demo build or unsaved draft): keep the
      // queue pending. The capture host attaches the property on handoff.
      return;
    }
    doc.propertyId = propertyId;
    final plan = await _sessions.getSession(_stationId);
    if (plan == null) return;
    if (doc.frames.keys.any((id) => id < 1 || id > plan.requiredTargetCount)) {
      throw StateError('Queued photos do not match the saved plan.');
    }
    // Adaptive sessions are stitched by the backend from the originals, so
    // they take the same path as the 56-target enhanced mode: drain the
    // frames, then wait on the worker. There is no device panorama to upload
    // for either, and the panorama endpoint refuses one.
    final backendStitched = _backendStitched(
      plan.requiredTargetCount,
      planVersion: plan.capturePlanVersion,
    );
    if (doc.frames.isEmpty && doc.panorama == null) return;
    if (backendStitched &&
        doc.panorama?.confirmed == true &&
        plan.panoramaSyncStatus == FrameSyncStatus.ready &&
        plan.backendPanoramaId == doc.panorama?.panoramaId &&
        plan.localPanoramaPath == doc.panorama?.localFilePath &&
        File(doc.panorama!.localFilePath).existsSync()) {
      return;
    }

    String? sessionId;
    try {
      sessionId = await _coordinator.ensureSession(
        stationId: _stationId,
        propertyId: propertyId,
        attemptKey: doc.attemptKey,
        // The plan decides how many photographs the session expects and which
        // directions they were taken at, so the exact geometry must reach the
        // server before the session exists. `planForVersion` selects the same
        // plan the capture screen guided: the adaptive five-ring plan for new
        // sessions or the explicit saved geometry when resuming a backup.
        plan:
            _backendStitched(
              plan.requiredTargetCount,
              planVersion: plan.capturePlanVersion,
            )
            ? planForVersion(plan.capturePlanVersion)
            : null,
      );
    } on Object catch (error) {
      CaptureLog.log('Upload queue could not open a session: $error');
      // Offline or unauthorized: everything stays pending for the next wake.
      return;
    }

    if (backendStitched) {
      await _drainFrames(doc, sessionId, propertyId);
      // Job creation only. The panorama is followed by [completeHandoff], which
      // the capture screen and the preview drive with a real stage. A drain
      // that waited for the stitch is what used to turn a healthy five-minute
      // job into "Retry Handoff".
      await _ensurePanoramaJob(doc, sessionId);
    } else {
      await _drainPanorama(doc, sessionId, propertyId);
      await _drainFrames(doc, sessionId, propertyId);
      await _recordTotals(doc);
    }
  }

  /// Creates (idempotently) the backend panorama job once every photograph is
  /// confirmed. Returns the job id, or `null` when the uploads are unfinished.
  Future<String?> _ensurePanoramaJob(_QueueDoc doc, String sessionId) async {
    final plan = await _sessions.getSession(_stationId);
    final expectedCount = plan?.requiredTargetCount;
    // The count comes from the session's own plan: a plan-driven capture needs
    // however many targets its geometry produced, and waiting for a fixed
    // number would leave a finished sweep parked forever.
    if (expectedCount == null ||
        expectedCount < 1 ||
        doc.frames.length != expectedCount ||
        !List<int>.generate(
          expectedCount,
          (i) => i + 1,
        ).every((id) => doc.frames[id]?.status == FrameUploadState.confirmed)) {
      return null;
    }
    final frames = await _sessions.loadFrames(_stationId);
    if (frames.length != expectedCount ||
        frames.map((f) => f.targetId).toSet().length != expectedCount ||
        frames.any(
          (f) =>
              f.targetId < 1 ||
              f.targetId > expectedCount ||
              !File(f.imagePath).existsSync(),
        )) {
      throw StateError('Enhanced capture is incomplete.');
    }
    // Prevent replacing an existing device-generated or different artifact.
    final previous = doc.panorama;
    if (previous != null && !previous.confirmed) {
      throw StateError(
        'Unexpected queued device panorama in enhanced session.',
      );
    }
    final job = await _coordinator.ensurePanoramaJob(
      stationId: _stationId,
      sessionId: sessionId,
    );
    final jobId = job['jobId'] as String?;
    if (jobId != null && jobId.isNotEmpty) {
      await _sessions.saveBackendHandoff(
        sessionId: _stationId,
        syncStatus: FrameSyncStatus.processing,
        backendSessionId: sessionId,
        backendJobId: jobId,
        backupSyncStatus: FrameSyncStatus.ready,
        backupUploaded: expectedCount,
        backupTotal: expectedCount,
      );
    }
    return jobId;
  }

  /// Drives the whole backend handoff for a completed plan-driven capture and
  /// reports its real stage.
  ///
  /// This is the single entry point the capture screen and the preview use.
  /// It is safe to call repeatedly and from several screens at once: uploads
  /// are skipped when already confirmed, job creation is idempotent, and the
  /// same job id is followed rather than a second job being created.
  Future<PanoramaHandoffOutcome> completeHandoff({
    void Function(PanoramaJobStage stage, String message)? onStage,
  }) async {
    // Wall-clock per stage, logged once at the end. These are measurements,
    // never inputs: nothing in this method is timed out or shortened to hit a
    // target, and the numbers are what the report quotes.
    final started = DateTime.now();
    var uploadsMs = 0;
    var doc = await _loadOrCreate();
    final plan = await _sessions.getSession(_stationId);
    if (plan == null) {
      return const PanoramaHandoffOutcome.failed(
        'The saved capture could not be read. Your photographs are kept.',
      );
    }
    if (!_backendStitched(
      plan.requiredTargetCount,
      planVersion: plan.capturePlanVersion,
    )) {
      return const PanoramaHandoffOutcome.unsupported();
    }
    final propertyId =
        doc.propertyId ?? plan.propertyId ?? await _resolvePropertyId();
    if (propertyId == null) {
      return const PanoramaHandoffOutcome.failed(
        'The panorama needs a saved property. Save the property draft first.',
      );
    }
    doc.propertyId ??= propertyId;

    // 1. Uploads. `resume()` returns once every photograph is confirmed (or a
    //    real upload failure parked it), never while the stitch runs.
    onStage?.call(PanoramaJobStage.processing, 'Finishing photo uploads…');
    final uploadsStarted = DateTime.now();
    try {
      await resume();
    } on Object catch (error) {
      CaptureLog.log('Handoff could not finish uploading: $error');
    }
    uploadsMs = DateTime.now().difference(uploadsStarted).inMilliseconds;
    // `resume()` writes confirmations to the queue document. Reload before
    // deciding the uploads are incomplete, or a healthy handoff reads the
    // pre-drain snapshot and falsely reports missing frames.
    doc = await _loadOrCreate();
    final frames = doc.frames.values;
    final confirmed = frames
        .where((record) => record.status == FrameUploadState.confirmed)
        .length;
    if (frames.length < plan.requiredTargetCount ||
        confirmed < plan.requiredTargetCount) {
      final missing = frames.length < plan.requiredTargetCount
          ? plan.requiredTargetCount - frames.length
          : plan.requiredTargetCount - confirmed;
      return PanoramaHandoffOutcome.failed(
        '$confirmed of ${plan.requiredTargetCount} photographs are on '
        'Sitewise. $missing still need to upload — your photos are kept, '
        'retry when the connection is back.',
      );
    }

    // 2. Job creation, then 3. follow it.
    String? sessionId = plan.backendSessionId;
    try {
      sessionId ??= await _coordinator.ensureSession(
        stationId: _stationId,
        propertyId: propertyId,
        attemptKey: doc.attemptKey,
        // The session's own saved version, never just its target count.
        plan: planForVersion(plan.capturePlanVersion),
      );
    } on Object catch (error) {
      CaptureLog.log('Handoff could not open the session: $error');
      return PanoramaHandoffOutcome.failed(
        'Sitewise could not be reached. Your photos are saved — retry the '
        'panorama when the connection is back.',
      );
    }
    String? jobId;
    try {
      jobId = await _ensurePanoramaJob(doc, sessionId);
    } on UploadsIncompleteFailure {
      return const PanoramaHandoffOutcome.failed(
        'The uploads have not finished yet. Retry to continue.',
      );
    } on Object catch (error) {
      CaptureLog.log('Handoff could not create the panorama job: $error');
      return PanoramaHandoffOutcome.failed(
        'The panorama could not be queued: '
        '${readableFailure(error, fallback: 'service error')} '
        'Your photographs are saved — retry to continue.',
      );
    }
    if (jobId == null) {
      return const PanoramaHandoffOutcome.failed(
        'The capture is not complete yet. Your photographs are saved.',
      );
    }

    final result = await _coordinator.followPanoramaJob(
      stationId: _stationId,
      sessionId: sessionId,
      jobId: jobId,
      directory: await frameStore.tourRoot(tourId),
      onStage: (stage, job) => onStage?.call(
        stage,
        stage == PanoramaJobStage.queued
            ? 'Your photos are saved. Panorama processing will begin shortly.'
            : 'Creating your 360° panorama…',
      ),
    );
    if (result.ready) {
      final saved = await _persistPanorama(
        result.panorama!,
        propertyId: propertyId,
        sessionId: sessionId,
        expectedCount: plan.requiredTargetCount,
        jobId: jobId,
      );
      if (!saved) {
        return PanoramaHandoffOutcome.failed(
          'Your panorama was created but could not be attached to this '
          'property. Retry to finish saving it — it does not need to be '
          'generated again.',
          panoramaId: result.panoramaId,
        );
      }
      CaptureLog.log(
        'HANDOFF_TIMING: uploads=${uploadsMs}ms '
        'total=${DateTime.now().difference(started).inMilliseconds}ms '
        'job=$jobId',
      );
      return PanoramaHandoffOutcome.ready(
        localPath: result.panorama!['localPath'] as String? ?? '',
        panoramaId: result.panorama!['id'] as String? ?? '',
        sessionId: sessionId,
        verificationStatus:
            result.panorama!['verificationStatus'] as String?,
      );
    }
    if (result.pending) {
      return PanoramaHandoffOutcome.pending(
        result.failureMessage ?? 'Your panorama is still being created.',
      );
    }
    return PanoramaHandoffOutcome.failed(
      result.failureMessage ?? 'The panorama could not be created.',
      panoramaId: result.panoramaId,
    );
  }

  /// Records a completed server panorama as the draft for this tour.
  ///
  /// Three writes, all idempotent: the session store (so a restart finds it),
  /// the tour record (so the property detail and the preview find it), and the
  /// queue document (so nothing re-downloads it). No server object is touched,
  /// and no second job is ever created.
  Future<bool> _persistPanorama(
    Map<String, dynamic> panorama, {
    required int propertyId,
    required String sessionId,
    required int expectedCount,
    required String jobId,
  }) async {
    final path = panorama['localPath'] as String?;
    final id = panorama['id'] as String?;
    if (path == null || path.isEmpty || id == null || id.isEmpty) return false;
    try {
      final tour = await ServiceLocator.tourRepo.tourById(tourId);
      if (tour == null || tour.propertyId != '$propertyId') {
        throw StateError(
          'Panorama property association could not be verified.',
        );
      }
      await _sessions.savePanorama(
        sessionId: _stationId,
        localPanoramaPath: path,
        status: PanoramaGenerationStatus.ready,
        error: null,
      );
      // The tour's panorama pointer is deliberately NOT moved here. A worker
      // result is an unconfirmed candidate; only acceptPanoramaCandidate()
      // may make it the active inspection panorama.
      await _sessions.saveBackendHandoff(
        sessionId: _stationId,
        syncStatus: FrameSyncStatus.ready,
        backendSessionId: sessionId,
        panoramaSyncStatus: FrameSyncStatus.ready,
        backupSyncStatus: FrameSyncStatus.ready,
        backupUploaded: expectedCount,
        backupTotal: expectedCount,
        backendPanoramaId: id,
        clearLastError: true,
      );
      final doc = await _loadOrCreate();
      doc.panorama = PanoramaQueueRecord(
        localFilePath: path,
        checksumSha256: await _checksum(path),
        status: FrameUploadState.confirmed,
        panoramaId: id,
        storagePath: panorama['storagePath'] as String?,
      );
      await _flush();
      return true;
    } on Object catch (error) {
      CaptureLog.log('Completed panorama could not be recorded: $error');
      return false;
    }
  }

  Future<void> _drainPanorama(
    _QueueDoc doc,
    String sessionId,
    int propertyId,
  ) async {
    final panorama = doc.panorama;
    if (panorama == null ||
        panorama.confirmed ||
        panorama.status == FrameUploadState.failedRetryable) {
      return;
    }
    if (!await File(panorama.localFilePath).exists()) return;
    panorama
      ..status = FrameUploadState.uploading
      ..lastError = null
      ..updatedAt = DateTime.now().toUtc();
    await _flush();
    var attempts = 0;
    while (attempts < kMaxDrainAttempts) {
      attempts++;
      try {
        final confirmed = await _coordinator.syncPanoramaDraft(
          sessionId: sessionId,
          propertyId: propertyId,
          panoramaPath: panorama.localFilePath,
          checksum: panorama.checksumSha256,
          // Device-side frame-quality evidence rides along with the
          // panorama confirmation so the backend report can show what the
          // device measured. Advisory only — it never gates the upload.
          deviceQuality: await _deviceQualitySummary(),
        );
        panorama
          ..status = FrameUploadState.confirmed
          ..storagePath = confirmed['storagePath'] as String?
          ..panoramaId = confirmed['panoramaId'] as String?
          ..lastError = null
          ..updatedAt = DateTime.now().toUtc();
        await _flush();
        await _sessions.saveBackendHandoff(
          sessionId: _stationId,
          syncStatus: FrameSyncStatus.uploading,
          backendSessionId: sessionId,
          panoramaSyncStatus: FrameSyncStatus.ready,
          backendPanoramaId: panorama.panoramaId,
        );
        return;
      } on Object catch (error) {
        panorama
          ..retryCount = attempts
          ..lastError = '$error'
          ..updatedAt = DateTime.now().toUtc();
        await _flush();
        // Brief backoff before the next attempt; the loop keeps the app
        // responsive because everything below runs on the worker future.
        await Future<void>.delayed(Duration(seconds: attempts));
      }
    }
    panorama.status = FrameUploadState.failedRetryable;
    await _flush();
    await _sessions.saveBackendHandoff(
      sessionId: _stationId,
      syncStatus: FrameSyncStatus.failed,
      backendSessionId: sessionId,
      panoramaSyncStatus: FrameSyncStatus.failed,
      error: panorama.lastError,
    );
  }

  Future<void> _drainFrames(
    _QueueDoc doc,
    String sessionId,
    int propertyId,
  ) async {
    // Restart safety: a record left `uploading` by a killed app re-reads as
    // pending here — nothing else could have confirmed it.
    var dirty = false;
    for (final record in doc.frames.values) {
      if (record.status == FrameUploadState.uploading) {
        record
          ..status = FrameUploadState.pending
          ..updatedAt = DateTime.now().toUtc();
        dirty = true;
      }
    }
    if (dirty) await _flush();

    var confirmedCount = doc.frames.values
        .where((r) => r.status == FrameUploadState.confirmed)
        .length;
    final total =
        (await _sessions.getSession(_stationId))?.requiredTargetCount ??
        doc.frames.length;

    while (!_transfersCancelled && !_transportPaused) {
      // A panorama may be queued while a frame batch is uploading.
      final currentPlan = await _sessions.getSession(_stationId);
      if (!_backendStitched(
            currentPlan?.requiredTargetCount,
            planVersion: currentPlan?.capturePlanVersion,
          ) &&
          doc.panorama?.status == FrameUploadState.pending) {
        await _drainPanorama(doc, sessionId, propertyId);
      }
      final batch = <FrameUploadRecord>[
        for (final record in doc.frames.values)
          if (record.status == FrameUploadState.pending) record,
      ]..sort((a, b) => a.targetId.compareTo(b.targetId));
      if (batch.isEmpty) break;
      final wave = batch.take(kFrameUploadConcurrency).toList();
      final byTarget = {
        for (final frame in await _safeLoadFrames()) frame.targetId: frame,
      };
      await Future.wait(
        wave.map((record) => _uploadOneFrame(doc, sessionId, record, byTarget)),
      );
      confirmedCount = doc.frames.values
          .where((r) => r.status == FrameUploadState.confirmed)
          .length;
      await _sessions.saveBackendHandoff(
        sessionId: _stationId,
        syncStatus: FrameSyncStatus.uploading,
        backendSessionId: sessionId,
        backupSyncStatus: confirmedCount >= total && total > 0
            ? FrameSyncStatus.ready
            : FrameSyncStatus.uploading,
        backupUploaded: confirmedCount,
        backupTotal: total,
      );
    }
  }

  Future<List<CapturedFrame>> _safeLoadFrames() async {
    try {
      return await _sessions.loadFrames(_stationId);
    } on Object {
      return const <CapturedFrame>[];
    }
  }

  /// The device's own frame-quality summary, sent with the panorama
  /// confirmation as advisory evidence. Counts come from the session store's
  /// persisted per-frame reports; a frame captured before quality checking
  /// existed simply counts as "not analyzed". `null` when the session store
  /// has no frames — the field is simply omitted from the report then.
  Future<Map<String, Object?>?> _deviceQualitySummary() async {
    final frames = await _safeLoadFrames();
    if (frames.isEmpty) return null;
    var warnings = 0;
    var invalid = 0;
    var analyzed = 0;
    final warnedTargets = <int>[];
    for (final frame in frames) {
      final report = FrameQualityReport.tryDecode(frame.qualityJson);
      if (report == null) continue;
      analyzed++;
      if (report.verdict == QualityVerdict.warning) {
        warnings++;
        warnedTargets.add(frame.targetId);
      } else if (report.verdict == QualityVerdict.invalid) {
        invalid++;
        warnedTargets.add(frame.targetId);
      }
    }
    return <String, Object?>{
      'analyzed': analyzed,
      'warnings': warnings,
      'invalid': invalid,
      'warned_targets': warnedTargets,
      'total_frames': frames.length,
    };
  }

  Future<void> _uploadOneFrame(
    _QueueDoc doc,
    String sessionId,
    FrameUploadRecord record,
    Map<int, CapturedFrame> byTarget,
  ) async {
    final frame = byTarget[record.targetId];
    // Nothing to upload: the frame left the session store, or its JPEG was
    // cleared by a retake (records + file go; session rows are rebuilt on
    // the next capture). Drop the QUEUE record so the drain cannot stall on
    // a target that has nothing to send — the LOCAL file is never touched
    // by the queue itself.
    if (!await File(record.localFilePath).exists()) {
      if (identical(doc.frames[record.targetId], record)) {
        doc.frames.remove(record.targetId);
      }
      await _flush();
      _settleFrameWaiters(
        record.targetId,
        BackendHandoffFailure('The saved photograph is missing on this device.'),
      );
      return;
    }
    if (frame == null) {
      record
        ..status = FrameUploadState.failedRetryable
        ..lastError = 'The saved frame metadata could not be loaded.';
      await _flush();
      _settleFrameWaiters(
        record.targetId,
        BackendHandoffFailure('The saved frame metadata could not be loaded.'),
      );
      return;
    }
    // Older queue documents may still name a processing derivative. The
    // FastAPI transport sends the original, so migrate the record to the
    // original's digest before the first retry.
    if (record.derivative != null) {
      record.derivative = null;
      try {
        record.checksumSha256 = await _checksum(record.localFilePath);
      } on Object catch (error) {
        record
          ..status = FrameUploadState.failedRetryable
          ..lastError = '$error';
        await _flush();
        _settleFrameWaiters(
          record.targetId,
          BackendHandoffFailure('The saved photograph could not be read.'),
        );
        return;
      }
      await _flush();
    }
    record
      ..status = FrameUploadState.uploading
      ..updatedAt = DateTime.now().toUtc();
    await _flush();
    var attempts = 0;
    while (attempts < kMaxDrainAttempts) {
      attempts++;
      final uploadStarted = DateTime.now();
      try {
        final result = await _coordinator.sendFrameToBackend(
          sessionId: sessionId,
          frame: frame,
          checksum: record.checksumSha256,
          qualityReport: FrameQualityReport.tryDecode(
            frame.qualityJson,
          )?.toJson(),
        );
        final storagePath = result['storagePath'] as String?;
        if (storagePath == null || storagePath.isEmpty) {
          throw const BackendHandoffFailure(
            'The backend did not return the stored frame path.',
          );
        }
        record
          ..status = FrameUploadState.confirmed
          ..storagePath = storagePath
          ..lastError = null
          ..retryCount = 0
          ..updatedAt = DateTime.now().toUtc();
        await _flush();
        CaptureLog.log(
          'Frame upload target ${record.targetId} confirmed in '
          '${DateTime.now().difference(uploadStarted).inMilliseconds}ms',
        );
        _settleFrameWaiters(record.targetId, null);
        return;
      } on Object catch (error) {
        record
          ..retryCount = attempts
          ..lastError = '$error'
          ..updatedAt = DateTime.now().toUtc();
        await _flush();
        if (_isTransportFailure(error)) {
          _pauseTransport();
          break;
        }
        await Future<void>.delayed(Duration(seconds: attempts));
      }
    }
    record.status = FrameUploadState.failedRetryable;
    await _flush();
    _settleFrameWaiters(
      record.targetId,
      BackendHandoffFailure(
        'Target ${record.targetId} could not be uploaded. Your photograph is '
        'saved on this device.',
      ),
    );
  }

  Future<void> _recordTotals(_QueueDoc doc) async {
    final total =
        (await _sessions.getSession(_stationId))?.requiredTargetCount ??
        doc.frames.length;
    final confirmed = doc.frames.values
        .where((r) => r.status == FrameUploadState.confirmed)
        .length;
    final panoramaDone = doc.panorama?.confirmed ?? false;
    if (total == 0) return;
    await _sessions.saveBackendHandoff(
      sessionId: _stationId,
      syncStatus: panoramaDone && confirmed >= total
          ? FrameSyncStatus.ready
          : FrameSyncStatus.uploading,
      panoramaSyncStatus: panoramaDone
          ? FrameSyncStatus.ready
          : FrameSyncStatus.uploading,
      backupSyncStatus: confirmed >= total
          ? FrameSyncStatus.ready
          : FrameSyncStatus.uploading,
      backupUploaded: confirmed,
      backupTotal: total,
    );
  }

  /// The property id, recovered from the session store when the caller did
  /// not supply one at enqueue time.
  Future<int?> _resolvePropertyId() async {
    try {
      final session = await _sessions.getSession(_stationId);
      return session?.propertyId;
    } on Object {
      return null;
    }
  }

  // ------------------------------------------------------------------
  // Recovery.
  // ------------------------------------------------------------------

  /// Adds every saved photograph the queue document does not know about —
  /// frames captured before the queue existed, or a frame whose record was
  /// lost with a corrupt document. Already-confirmed targets are untouched,
  /// so recovery never re-uploads a confirmed photograph.
  Future<void> reconcileFrames(
    List<CapturedFrame> frames, {
    int? propertyId,
  }) async {
    if (frames.isEmpty) return;
    final doc = await _loadOrCreate();
    doc.propertyId ??= propertyId;
    var dirty = false;
    for (final frame in frames) {
      // A retake deletes the JPEG before the replacement is shot; a frame
      // whose file is gone has nothing to queue (and hashing it would
      // throw). The replacement capture re-enqueues the target.
      if (!await File(frame.imagePath).exists()) continue;
      final existing = doc.frames[frame.targetId];
      final fileGone =
          existing != null && existing.localFilePath != frame.imagePath;
      if (existing == null || fileGone) {
        doc.frames[frame.targetId] = FrameUploadRecord(
          targetId: frame.targetId,
          localFilePath: frame.imagePath,
          checksumSha256: await _checksum(frame.imagePath),
        );
        dirty = true;
      }
    }
    if (dirty) await _flush();
  }

  /// Re-arms everything unfinished and drains. Called when the capture
  /// session is reopened, the property detail is opened, or the preview
  /// loads: an app restart or a temporary disconnection resumes here without
  /// recapturing anything.
  Future<void> resume() async {
    await _draining;
    _transportPaused = false;
    _transportRetry?.cancel();
    _transportRetry = null;
    final doc = await _loadOrCreate();
    var dirty = false;
    for (final record in doc.frames.values) {
      if (record.status == FrameUploadState.uploading ||
          record.status == FrameUploadState.failedRetryable) {
        record
          ..status = FrameUploadState.pending
          ..retryCount = 0
          ..updatedAt = DateTime.now().toUtc();
        dirty = true;
      }
    }
    final panorama = doc.panorama;
    if (panorama != null &&
        (panorama.status == FrameUploadState.uploading ||
            panorama.status == FrameUploadState.failedRetryable)) {
      panorama
        ..status = FrameUploadState.pending
        ..retryCount = 0
        ..updatedAt = DateTime.now().toUtc();
      dirty = true;
    }
    if (dirty) await _flush();
    await drain();
  }

  void resumeInBackground() {
    if (_draining != null) return;
    unawaited(
      resume().catchError((Object error) {
        CaptureLog.log('Saved captures could not resume syncing: $error');
      }),
    );
  }

  // ------------------------------------------------------------------
  // Read-only state for the UI.
  // ------------------------------------------------------------------

  /// Reads the persisted queue state without touching the network. Used by
  /// the preview and the property detail to render "Cloud: Uploading /
  /// Saved" honestly.
  static Future<FrameUploadQueueState> readState(
    CaptureFrameStore frameStore,
    String tourId, {
    String? stationId,
  }) async {
    // Readers that omit the station still get the CURRENT attempt, not the
    // archived one. After an explicit recovery the station id differs from
    // the tour id, and assuming equality would show a stale queue state.
    final resolvedStation =
        stationId ??
        await SitewiseSphereSessionStore.stationIdForTour(
          frameStore: frameStore,
          tourId: tourId,
        );
    final file = File(
      p.join(
        await frameStore.tourRoot(tourId),
        'ar_capture',
        resolvedStation,
        'upload_queue.json',
      ),
    );
    if (!await file.exists()) return const FrameUploadQueueState.empty();
    try {
      final doc = _QueueDoc.fromJson(
        jsonDecode(await file.readAsString()).cast<String, Object?>(),
      );
      final frames = doc.frames.values.toList()
        ..sort((a, b) => a.targetId.compareTo(b.targetId));
      return FrameUploadQueueState(
        attemptKey: doc.attemptKey,
        frames: frames,
        panorama: doc.panorama,
      );
    } on Object {
      return const FrameUploadQueueState.empty();
    }
  }
}

/// The persisted queue state, read for UI rendering.
class FrameUploadQueueState {
  const FrameUploadQueueState({
    required this.attemptKey,
    required this.frames,
    this.panorama,
  });

  const FrameUploadQueueState.empty()
    : this(attemptKey: '', frames: const <FrameUploadRecord>[]);

  final String attemptKey;
  final List<FrameUploadRecord> frames;
  final PanoramaQueueRecord? panorama;

  int get confirmedFrames =>
      frames.where((r) => r.status == FrameUploadState.confirmed).length;

  int get uploadingFrames =>
      frames.where((r) => r.status == FrameUploadState.uploading).length;

  int get pendingFrames =>
      frames.where((r) => r.status == FrameUploadState.pending).length;

  int get failedFrames =>
      frames.where((r) => r.status == FrameUploadState.failedRetryable).length;

  bool get panoramaConfirmed => panorama?.confirmed ?? false;

  bool get panoramaInFlight =>
      panorama != null &&
      (panorama!.status == FrameUploadState.uploading ||
          panorama!.status == FrameUploadState.pending);

  bool get anyPending =>
      pendingFrames > 0 ||
      uploadingFrames > 0 ||
      failedFrames > 0 ||
      panoramaInFlight ||
      (panorama != null && !panorama!.confirmed);

  /// True when every unit the queue knows about is confirmed.
  bool get fullySynced =>
      frames.isNotEmpty &&
      confirmedFrames == frames.length &&
      panoramaConfirmed;

  String? get firstError {
    for (final record in frames) {
      if (record.lastError != null) return record.lastError;
    }
    return panorama?.lastError;
  }
}

/// The result of driving a backend panorama handoff to a terminal state.
///
/// Three outcomes, not two. Collapsing `pending` into `failed` is what made the
/// capture screen offer "Retry Handoff" for a job the worker was still
/// processing normally.
class PanoramaHandoffOutcome {
  const PanoramaHandoffOutcome._({
    required this.ready,
    required this.pending,
    required this.supported,
    this.localPath,
    this.panoramaId,
    this.sessionId,
    this.verificationStatus,
    this.message,
  });

  const PanoramaHandoffOutcome.ready({
    required String localPath,
    required String panoramaId,
    required String sessionId,
    String? verificationStatus,
  }) : this._(
         ready: true,
         pending: false,
         supported: true,
         localPath: localPath,
         panoramaId: panoramaId,
         sessionId: sessionId,
         verificationStatus: verificationStatus,
       );

  const PanoramaHandoffOutcome.pending(String message)
    : this._(ready: false, pending: true, supported: true, message: message);

  const PanoramaHandoffOutcome.failed(String message, {String? panoramaId})
    : this._(
        ready: false,
        pending: false,
        supported: true,
        message: message,
        panoramaId: panoramaId,
      );

  /// This plan's panorama is produced on the device, not by the worker.
  const PanoramaHandoffOutcome.unsupported()
    : this._(ready: false, pending: false, supported: false);

  final bool ready;
  final bool pending;
  final bool supported;
  final String? localPath;
  final String? panoramaId;
  final String? sessionId;
  final String? verificationStatus;
  final String? message;

  bool get failed => !ready && !pending && supported;
}

/// Receives the completed digest from [sha256.startChunkedConversion].
class _DigestSink implements Sink<Digest> {
  Digest? _value;

  Digest? get value => _value;

  @override
  void add(Digest data) => _value = data;

  @override
  void close() {}
}
