import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'package:fyp/core/di/service_locator.dart';
import 'package:fyp/core/utils/capture_log.dart';
import 'package:fyp/features/capture_360/application/backend_capture_coordinator.dart';
import 'package:fyp/features/capture_360/data/capture_frame_store.dart';
import 'package:fyp/features/capture_360/data/sphere/sitewise_sphere_session_store.dart';
import 'package:fyp/features/capture_360/domain/sphere/sphere_capture_session.dart';

/// How many original photographs upload at once. Two keeps the queue moving
/// without competing with the OpenCV stitcher for memory.
const int kFrameUploadConcurrency = 2;

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
    DateTime? updatedAt,
  }) : updatedAt = updatedAt ?? DateTime.now().toUtc();

  final int targetId;
  final String localFilePath;
  final String checksumSha256;
  FrameUploadState status;
  String? storagePath;
  int retryCount;
  String? lastError;
  DateTime updatedAt;

  Map<String, Object?> toJson() => <String, Object?>{
    'target_id': targetId,
    'local_file_path': localFilePath,
    'checksum_sha256': checksumSha256,
    'upload_status': status.wireName,
    'storage_path': storagePath,
    'retry_count': retryCount,
    'last_error': lastError,
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
/// is written to disk (checksum included), and the worker drains it to
/// Supabase Storage through FastAPI's signed URLs — without blocking the
/// camera or waiting for stitching. Panorama drafts join the same document
/// and are drained FIRST, because the panorama is the deliverable.
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
          final state = await readState(store, tour.id);
          if (state.panoramaConfirmed) continue;
          if (await ServiceLocator.tourRepo.tourById(tour.id) == null) continue;
          final path = tour.panoramaPath;
          if (state.panorama != null) {
            FrameUploadQueue.forTour(
              frameStore: store,
              tourId: tour.id,
            ).resumeInBackground();
          } else if (path != null && await File(path).exists()) {
            await FrameUploadQueue.forTour(
              frameStore: store,
              tourId: tour.id,
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
    final file = File(path);
    if (!await file.exists()) {
      throw const BackendHandoffFailure('The file to upload is missing.');
    }
    // Incremental hashing: a multi-megabyte JPEG is never held in memory,
    // which is what keeps the queue from competing with the stitcher.
    final sink = _DigestSink();
    final digest = sha256.startChunkedConversion(sink);
    await file.openRead().forEach(digest.add);
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
  Future<void> enqueueFrame(CapturedFrame frame, {int? propertyId}) async {
    final doc = await _loadOrCreate();
    doc.propertyId ??= propertyId;
    final record = FrameUploadRecord(
      targetId: frame.targetId,
      localFilePath: frame.imagePath,
      checksumSha256: await _checksum(frame.imagePath),
    );
    doc.frames[frame.targetId] = record;
    await _flush();
    _wake();
  }

  /// Queues the stitched panorama (the cloud draft). The panorama is drained
  /// with priority over the frame backups.
  Future<void> enqueuePanorama(String panoramaPath, {int? propertyId}) async {
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
    final doc = await _loadOrCreate();
    final propertyId = doc.propertyId ?? await _resolvePropertyId();
    if (propertyId == null) {
      // No property association yet (demo build or unsaved draft): keep the
      // queue pending. The capture host attaches the property on handoff.
      return;
    }
    doc.propertyId = propertyId;

    String? sessionId;
    try {
      sessionId = await _coordinator.ensureSession(
        stationId: _stationId,
        propertyId: propertyId,
        attemptKey: doc.attemptKey,
      );
    } on Object catch (error) {
      CaptureLog.log('Upload queue could not open a session: $error');
      // Offline or unauthorized: everything stays pending for the next wake.
      return;
    }

    await _drainPanorama(doc, sessionId, propertyId);
    await _drainFrames(doc, sessionId, propertyId);
    await _recordTotals(doc);
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
    final total = doc.frames.length;

    while (true) {
      // A panorama may be queued while a frame batch is uploading.
      if (doc.panorama?.status == FrameUploadState.pending) {
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
      return;
    }
    if (frame == null) {
      record
        ..status = FrameUploadState.failedRetryable
        ..lastError = 'The saved frame metadata could not be loaded.';
      await _flush();
      return;
    }
    record
      ..status = FrameUploadState.uploading
      ..updatedAt = DateTime.now().toUtc();
    await _flush();
    var attempts = 0;
    while (attempts < kMaxDrainAttempts) {
      attempts++;
      try {
        final storagePath = await _coordinator.uploadFrame(
          sessionId: sessionId,
          frame: frame,
          checksum: record.checksumSha256,
        );
        record
          ..status = FrameUploadState.confirmed
          ..storagePath = storagePath
          ..lastError = null
          ..retryCount = 0
          ..updatedAt = DateTime.now().toUtc();
        await _flush();
        return;
      } on Object catch (error) {
        record
          ..retryCount = attempts
          ..lastError = '$error'
          ..updatedAt = DateTime.now().toUtc();
        await _flush();
        await Future<void>.delayed(Duration(seconds: attempts));
      }
    }
    record.status = FrameUploadState.failedRetryable;
    await _flush();
  }

  Future<void> _recordTotals(_QueueDoc doc) async {
    final total = doc.frames.length;
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
    final file = File(
      p.join(
        await frameStore.tourRoot(tourId),
        'ar_capture',
        stationId ?? tourId,
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

/// Receives the completed digest from [sha256.startChunkedConversion].
class _DigestSink implements Sink<Digest> {
  Digest? _value;

  Digest? get value => _value;

  @override
  void add(Digest data) => _value = data;

  @override
  void close() {}
}
