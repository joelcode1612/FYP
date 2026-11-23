import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
// shared_logic also declares a `CapturedFrame` entity; this coordinator works
// with the 38-target capture domain one.
import 'package:shared_logic/shared_logic.dart' hide CapturedFrame;

import 'package:fyp/core/utils/capture_log.dart';
import 'package:fyp/features/capture_360/domain/sphere/sphere_capture_session.dart';
import 'package:fyp/features/capture_360/domain/sphere/sphere_target.dart'
    show kSphereCapturePlanVersion;

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
      await _record(
        stationId,
        FrameSyncStatus.failed,
        panoramaSyncStatus: panoramaPath == null
            ? null
            : FrameSyncStatus.failed,
        backupSyncStatus: FrameSyncStatus.failed,
        error: error is BackendHandoffFailure
            ? error.message
            : error.toString(),
      );
      rethrow;
    }
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
  /// The returned id is written back into the local session store BEFORE any
  /// frame is uploaded, so an app restart always knows which session to
  /// resume. A server-side 404 (expired backend data) recreates the session
  /// under the same attempt key — the frames re-confirm idempotently.
  Future<String> ensureSession({
    required String stationId,
    required int propertyId,
    required String attemptKey,
  }) async {
    // The attempt key resolves the same session on retry. A replacement
    // panorama has a different key even when it shares the local station.
    final created = await _client.post('$_api/sessions', <String, dynamic>{
      'property_id': propertyId,
      // Identifies the new Flutter-stitched workflow without changing the
      // expected frame count or breaking legacy `device_38` sessions.
      'capture_mode': 'device_38_panorama',
      'capture_plan_version': '$kSphereCapturePlanVersion',
      'idempotency_key': _idempotencyKey(propertyId, stationId, attemptKey),
    });
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

  /// Uploads and confirms ONE original photograph against its session —
  /// the unit the durable per-capture upload queue drains. Byte-for-byte
  /// idempotent with the batched backup: the same signed-URL transport, the
  /// same confirmation endpoint, and a repeat PUT of identical bytes is the
  /// stored success case. Returns the confirmed storage path.
  Future<String> uploadFrame({
    required String sessionId,
    required CapturedFrame frame,
    required String checksum,
  }) async {
    final permission = await _issueUploadUrls(sessionId, <int>[frame.targetId]);
    await _uploadOne(
      sessionId: sessionId,
      frame: frame,
      checksum: checksum,
      permission: permission[frame.targetId],
      onProgress: () {},
    );
    return permission[frame.targetId]!['storagePath'] as String;
  }

  /// Uploads and confirms the device-stitched panorama — the cloud draft
  /// (Layer B). Verifiable server-side before any canonical row exists.
  /// Returns the confirmation payload (`panoramaId`, `storagePath`,
  /// `width`, `height`). Safe to call again: the same verified object
  /// returns the existing row untouched.
  Future<Map<String, dynamic>> syncPanoramaDraft({
    required String sessionId,
    required int propertyId,
    required String panoramaPath,
    required String checksum,
  }) async {
    return _uploadAndConfirmPanorama(
      sessionId: sessionId,
      propertyId: propertyId,
      panoramaPath: panoramaPath,
      checksum: checksum,
    );
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

    var processed = checksums.length - toUpload.length;
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
        final permissions = await _issueUploadUrls(sessionId, batch);
        await Future.wait(
          batch.map(
            (target) => _uploadOne(
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
            ),
          ),
        );
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
      await _repairConfirmed(
        sessionId: sessionId,
        propertyId: (await _store.getSession(stationId))?.propertyId,
        frames: frames,
        checksums: checksums,
        targets: toRepair,
      );
    }
    return _BackupOutcome(processed: processed, total: checksums.length);
  }

  Future<void> _repairConfirmed({
    required String sessionId,
    required int? propertyId,
    required List<CapturedFrame> frames,
    required Map<int, String> checksums,
    required List<int> targets,
  }) async {
    if (propertyId == null) return;
    final byTarget = <int, CapturedFrame>{
      for (final frame in frames) frame.targetId: frame,
    };
    for (final target in targets) {
      await _confirm(
        sessionId,
        byTarget[target]!,
        checksums[target]!,
        'properties/$propertyId/sessions/$sessionId/frames/$target.jpg',
      );
    }
  }

  Future<Map<int, Map<String, dynamic>>> _issueUploadUrls(
    String sessionId,
    List<int> targets,
  ) async {
    final issued = await _client.post(
      '$_api/sessions/$sessionId/upload-urls',
      <String, dynamic>{'targets': targets},
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

  Future<Map<String, dynamic>> _issuePanoramaUploadUrl(String sessionId) async {
    final issued = await _client.post(
      '$_api/sessions/$sessionId/panorama/upload-url',
      const <String, dynamic>{},
    );
    final uploadUrl = issued['uploadUrl'] as String?;
    final storagePath = issued['storagePath'] as String?;
    if (uploadUrl == null || uploadUrl.isEmpty || storagePath == null) {
      throw const BackendHandoffFailure(
        'The Sitewise service returned no panorama upload permission.',
      );
    }
    return <String, dynamic>{
      'uploadUrl': uploadUrl,
      'storagePath': storagePath,
      'headers': issued['headers'],
    };
  }

  Future<Map<String, dynamic>> _uploadAndConfirmPanorama({
    required String sessionId,
    required int propertyId,
    required String panoramaPath,
    required String checksum,
  }) async {
    final coverage = await _coverageFor(panoramaPath, checksum);
    var permission = await _issuePanoramaUploadUrl(sessionId);
    var expiredRefreshes = 0;
    var networkAttempts = 0;
    while (true) {
      final url = permission['uploadUrl'] as String?;
      if (url == null || url.isEmpty) {
        throw const BackendHandoffFailure(
          'The panorama upload permission is incomplete.',
        );
      }
      final outcome = await _putFile(
        filePath: panoramaPath,
        target: 0,
        uri: Uri.parse(url),
        headers: permission['headers'],
      );
      if (outcome == _PutOutcome.stored) break;
      if (outcome == _PutOutcome.expired && expiredRefreshes < 2) {
        expiredRefreshes++;
        permission = await _issuePanoramaUploadUrl(sessionId);
        continue;
      }
      if (outcome == _PutOutcome.retryable &&
          networkAttempts < _maxUploadAttempts - 1) {
        networkAttempts++;
        await Future<void>.delayed(Duration(seconds: networkAttempts));
        continue;
      }
      throw const BackendHandoffFailure(
        'The 360° panorama could not be uploaded. It is kept on this device — '
        'you can retry the synchronization.',
      );
    }

    final storagePath = permission['storagePath'] as String?;
    if (storagePath == null || storagePath.isEmpty) {
      throw const BackendHandoffFailure(
        'The panorama upload permission has no storage path.',
      );
    }
    final confirmed = await _client.post(
      '$_api/sessions/$sessionId/panorama',
      <String, dynamic>{
        'storage_path': storagePath,
        'checksum_sha256': checksum,
        'coverage_report': <String, Object?>{
          'source': 'device_capture_v2',
          'stitched_on': 'flutter',
          'photo_coverage': ?coverage,
        },
      },
    );
    return confirmed;
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
    required void Function() onProgress,
  }) async {
    if (permission == null) {
      throw BackendHandoffFailure(
        'The Sitewise service returned no upload permission for target '
        '${frame.targetId}.',
      );
    }
    var upload = permission;
    var expiredRefreshes = 0;
    var networkAttempts = 0;
    while (true) {
      final url = upload['uploadUrl'] as String?;
      if (url == null || url.isEmpty) {
        throw BackendHandoffFailure(
          'The upload permission for target ${frame.targetId} is incomplete.',
        );
      }
      final outcome = await _putFile(
        filePath: frame.imagePath,
        target: frame.targetId,
        uri: Uri.parse(url),
        headers: upload['headers'],
      );
      if (outcome == _PutOutcome.stored) break;
      if (outcome == _PutOutcome.expired && expiredRefreshes < 2) {
        expiredRefreshes++;
        upload = await _refreshUploadUrl(sessionId, frame.targetId);
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
            'Uploading target ${frame.targetId} needs a fresh permission. '
            'Your photographs are kept — retry the synchronization.',
          );
        case _PutOutcome.retryable:
          throw BackendHandoffFailure(
            'Uploading target ${frame.targetId} did not complete. Your '
            'photographs are kept — retry the synchronization.',
          );
        case _PutOutcome.fatal:
          throw BackendHandoffFailure(
            'Target ${frame.targetId} could not be uploaded to Sitewise. '
            'Your photographs are kept — retry the synchronization.',
          );
        case _PutOutcome.stored:
          break;
      }
      break;
    }

    final storagePath = upload['storagePath'] as String?;
    if (storagePath == null || storagePath.isEmpty) {
      throw BackendHandoffFailure(
        'The upload permission for target ${frame.targetId} has no storage '
        'path.',
      );
    }
    await _confirm(sessionId, frame, checksum, storagePath);
    onProgress();
  }

  Future<Map<String, dynamic>> _refreshUploadUrl(
    String sessionId,
    int target,
  ) async {
    final issued = await _issueUploadUrls(sessionId, <int>[target]);
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
    String storagePath,
  ) async {
    await _client.post('$_api/sessions/$sessionId/frames', <String, dynamic>{
      'target_index': frame.targetId,
      'storage_path': storagePath,
      'checksum_sha256': checksum,
      if (frame.imageWidth > 0) 'image_width': frame.imageWidth,
      if (frame.imageHeight > 0) 'image_height': frame.imageHeight,
      'capture_pose': <String, Object?>{
        'x': frame.cameraOrientation.x,
        'y': frame.cameraOrientation.y,
        'z': frame.cameraOrientation.z,
        'w': frame.cameraOrientation.w,
        'sourceImageWidth': frame.sourceImageWidth,
        'sourceImageHeight': frame.sourceImageHeight,
        'cropOffsetX': frame.cropOffsetX,
        'cropOffsetY': frame.cropOffsetY,
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
