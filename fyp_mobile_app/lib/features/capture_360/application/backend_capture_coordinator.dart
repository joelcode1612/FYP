import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
// shared_logic also declares a `CapturedFrame` entity; this coordinator works
// with the 38-target capture domain one.
import 'package:shared_logic/shared_logic.dart' hide CapturedFrame;

import 'package:fyp/core/utils/capture_log.dart';
import 'package:fyp/features/capture_360/domain/sphere/sphere_capture_session.dart';

/// One successful backend handoff.
class BackendHandoffResult {
  const BackendHandoffResult({
    required this.backendSessionId,
    required this.jobId,
    required this.panoramaId,
    required this.storagePath,
    required this.viewUrl,
    required this.width,
    required this.height,
  });

  final String backendSessionId;
  final String jobId;
  final String panoramaId;
  final String storagePath;
  final String viewUrl;
  final int width;
  final int height;
}

/// A handoff step the caller can act on. The message is written for the
/// capture banner: honest, retry-oriented, and never blaming the frames.
class BackendHandoffFailure implements Exception {
  const BackendHandoffFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The backend-authoritative handoff for a completed 38-target capture.
///
/// Sequence (spec §12): the local frames are validated, the backend session is
/// ensured, every original JPEG is PUT straight to Supabase Storage through a
/// server-issued signed URL and then confirmed with its checksum, pose and
/// dimensions, and finally the stitching job is requested and polled until the
/// canonical panorama exists. Nothing here deletes a photograph or a stored
/// object, and nothing here invents a result: only the backend's own job
/// status moves the session forward.
///
/// Every step is idempotent so a retry or a resumed session re-runs the whole
/// sequence safely:
///
///   * creating a session returns the same row for a repeated call,
///   * a repeat PUT of identical bytes is answered 409 Duplicate, which IS
///     the success case (the object is already stored),
///   * confirming a frame upserts its manifest row,
///   * requesting processing returns the live job instead of queueing a
///     second one.
///
/// A frame whose local bytes differ from the already-confirmed checksum (a
/// retake after the handoff ran) cannot overwrite its storage object — signed
/// uploads are immutable — so the coordinator starts a FRESH backend session
/// whose deterministic paths are empty. The previous session's job, if still
/// running, completes on the older frame set and its panorama is superseded
/// by the newer session's.
///
/// The Dart stitcher is NOT used here and NOT replaced by this class: it
/// remains the device-side fallback (`SphereCaptureController` still produces
/// the local panorama), while the backend result is authoritative for the
/// cloud workflow.
class BackendCaptureCoordinator {
  BackendCaptureCoordinator({
    required this._client,
    required this._store,
  });

  static const _api = '/api/v1/360';
  static const _pollInterval = Duration(seconds: 2);
  static const _consecutivePollFailuresAllowed = 5;

  final ApiClient _client;
  final CaptureSessionStore _store;
  final HttpClient _http = HttpClient();

  Future<BackendHandoffResult> handOff({
    required String stationId,
    required int propertyId,
    required List<CapturedFrame> frames,
    required int expectedFrames,
    void Function(String stage)? onStage,
    void Function(int processed, int total)? onFrameProcessed,
  }) async {
    try {
      return await _handOff(
        stationId: stationId,
        propertyId: propertyId,
        frames: frames,
        expectedFrames: expectedFrames,
        onStage: onStage,
        onFrameProcessed: onFrameProcessed,
      );
    } on Object catch (error) {
      // Every failure is recorded against the local session before it
      // surfaces: the banner's Retry and a later resume both start from the
      // recorded state, and the frames stay on the device untouched.
      await _record(
        stationId,
        FrameSyncStatus.failed,
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
    void Function(String stage)? onStage,
    void Function(int processed, int total)? onFrameProcessed,
  }) async {
    onStage?.call('Validating frames...');
    final ordered = await _validated(frames, expectedFrames);

    // Bytes and checksums are read once: the upload needs them, and the
    // checksum decides whether a confirmed remote frame is still this frame.
    final payloads = <int, _FramePayload>{};
    for (final frame in ordered) {
      final bytes = await File(frame.imagePath).readAsBytes();
      payloads[frame.targetId] = _FramePayload(
        frame: frame,
        bytes: bytes,
        checksum: sha256.convert(bytes).toString(),
      );
    }

    onStage?.call('Preparing the Sitewise session...');
    var backendSessionId = await _ensureSession(stationId);

    final toUpload = <int>[];
    if (backendSessionId != null) {
      final confirmed = await _confirmedChecksums(backendSessionId);
      for (final entry in payloads.entries) {
        if (confirmed[entry.key] == entry.value.checksum) continue;
        toUpload.add(entry.key);
      }
      if (confirmed.keys.any(
        (target) =>
            payloads.containsKey(target) &&
            confirmed[target] != payloads[target]!.checksum,
      )) {
        // A retake changed at least one already-stored frame. Signed upload
        // paths are immutable, so the session cannot be repaired in place.
        CaptureLog.log(
          'Backend session $backendSessionId holds superseded frames; '
          'starting a fresh session',
        );
        backendSessionId = null;
      }
    }

    if (backendSessionId == null) {
      final created = await _client.post('$_api/sessions', <String, dynamic>{
        'property_id': propertyId,
        'capture_mode': 'device_38',
      });
      backendSessionId = created['sessionId'] as String?;
      if (backendSessionId == null || backendSessionId.isEmpty) {
        throw const BackendHandoffFailure(
          'The Sitewise service accepted the capture session but returned no '
          'session id.',
        );
      }
      toUpload
        ..clear()
        ..addAll(payloads.keys);
    }
    await _record(
      stationId,
      FrameSyncStatus.uploadPending,
      backendSessionId: backendSessionId,
      clearBackendJobId: true,
    );

    await _uploadAndConfirm(
      sessionId: backendSessionId,
      payloads: payloads,
      targets: toUpload,
      onStage: onStage,
      onFrameProcessed: onFrameProcessed,
      total: payloads.length,
    );

    onStage?.call('Requesting panorama processing...');
    final jobPayload = await _client.post(
      '$_api/sessions/$backendSessionId/process',
      const <String, dynamic>{},
    );
    final jobId = jobPayload['jobId'] as String?;
    if (jobId == null || jobId.isEmpty) {
      throw const BackendHandoffFailure(
        'The Sitewise service accepted the processing request but returned no '
        'job id.',
      );
    }
    await _record(
      stationId,
      FrameSyncStatus.processing,
      backendSessionId: backendSessionId,
      backendJobId: jobId,
    );

    onStage?.call('Stitching on Sitewise...');
    await _awaitJob(jobId, onStage);

    onStage?.call('Opening the Sitewise panorama...');
    final panorama = await _client.get('$_api/properties/$propertyId/panorama');
    final panoramaId = panorama['panoramaId'] as String?;
    final storagePath = panorama['storagePath'] as String?;
    final width = (panorama['width'] as num?)?.toInt() ?? 0;
    final height = (panorama['height'] as num?)?.toInt() ?? 0;
    if (panoramaId == null || panoramaId.isEmpty) {
      throw const BackendHandoffFailure(
        'The Sitewise service finished the panorama but returned no panorama '
        'record.',
      );
    }
    final view = await _client.get('$_api/panoramas/$panoramaId/view');
    final viewUrl = view['viewUrl'] as String?;
    if (viewUrl == null || viewUrl.isEmpty) {
      throw const BackendHandoffFailure(
        'The Sitewise service stored the panorama but returned no viewing '
        'URL.',
      );
    }

    await _record(stationId, FrameSyncStatus.ready, clearLastError: true);
    CaptureLog.log(
      'Backend handoff complete: session $backendSessionId, job $jobId, '
      'panorama $panoramaId',
    );
    return BackendHandoffResult(
      backendSessionId: backendSessionId,
      jobId: jobId,
      panoramaId: panoramaId,
      storagePath: storagePath ?? '',
      viewUrl: viewUrl,
      width: width,
      height: height,
    );
  }

  Future<List<CapturedFrame>> _validated(List<CapturedFrame> frames, int total) async {
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
          'The saved photograph for target ${frame.targetId} is missing on '
          'disk (${frame.imagePath}). Retake this target and try again.',
        );
      }
    }
    if (ordered.length < total) {
      final missing = <int>[
        for (var id = 1; id <= total; id++)
          if (!seen.contains(id)) id,
      ];
      throw BackendHandoffFailure(
        'The Sitewise handoff needs all $total photographs. Missing targets: '
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

  Future<String?> _ensureSession(String stationId) async {
    final local = await _store.getSession(stationId);
    final existing = local?.backendSessionId;
    if (existing == null) return null;
    try {
      await _client.get('$_api/sessions/$existing');
      return existing;
    } on NotFoundFailure {
      // The backend no longer knows this session (expired test data, a
      // restored database). A fresh session is created below; the local
      // frames are unaffected either way.
      CaptureLog.log('Backend session $existing no longer exists; recreating');
      return null;
    }
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

  Future<void> _uploadAndConfirm({
    required String sessionId,
    required Map<int, _FramePayload> payloads,
    required List<int> targets,
    required void Function(String stage)? onStage,
    required void Function(int processed, int total)? onFrameProcessed,
    required int total,
  }) async {
    var processed = total - targets.length;
    onFrameProcessed?.call(processed, total);

    if (targets.isNotEmpty) {
      onStage?.call('Uploading originals to Sitewise...');
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
            (entry['targetIndex'] as num).toInt(): Map<String, dynamic>.from(entry),
      };

      for (final target in targets) {
        final payload = payloads[target]!;
        final upload = byTarget[target];
        if (upload == null) {
          throw BackendHandoffFailure(
            'The Sitewise service returned no upload permission for target '
            '$target.',
          );
        }
        final storagePath = upload['storagePath'] as String?;
        final uploadUrl = upload['uploadUrl'] as String?;
        if (storagePath == null || uploadUrl == null) {
          throw BackendHandoffFailure(
            'The upload permission for target $target is incomplete.',
          );
        }
        await _putBytes(target, Uri.parse(uploadUrl), upload['headers'], payload.bytes);
        await _confirm(sessionId, payload, storagePath);
        processed++;
        onFrameProcessed?.call(processed, total);
        onStage?.call('Uploading originals to Sitewise ($processed/$total)...');
      }
    } else {
      // Every frame is already confirmed byte-for-byte on the backend: a
      // resumed handoff only needs processing. The manifest is not re-sent.
      CaptureLog.log(
        'Backend session $sessionId: all frames confirmed, resuming processing',
      );
    }
  }

  Future<void> _putBytes(
    int target,
    Uri uri,
    Object? headers,
    List<int> bytes,
  ) async {
    final request = await _http.openUrl('PUT', uri);
    request.headers.contentType = ContentType('image', 'jpeg');
    if (headers is Map) {
      for (final entry in headers.entries) {
        if (entry.key is String && entry.key.toString().toLowerCase() != 'content-type') {
          request.headers.set(entry.key as String, entry.value.toString());
        }
      }
    }
    request.headers.contentLength = bytes.length;
    request.add(bytes);
    final HttpClientResponse response;
    try {
      response = await request.close().timeout(const Duration(minutes: 5));
    } on TimeoutException {
      throw BackendHandoffFailure(
        'Uploading target $target to Sitewise timed out. The frames are '
        'kept — retry the handoff.',
      );
    }
    final body = await response.transform(utf8.decoder).join();
    final status = response.statusCode;
    if (status >= 200 && status < 300) return;
    final lowered = body.toLowerCase();
    if ((status == 400 || status == 409) &&
        (lowered.contains('keyalreadyexists') ||
            lowered.contains('already exists'))) {
      // The bytes are already stored — the idempotent success a retry needs.
      return;
    }
    throw BackendHandoffFailure(
      'Target $target could not be uploaded to Sitewise '
      '(HTTP $status). The frames are kept — retry the handoff.',
    );
  }

  Future<void> _confirm(
    String sessionId,
    _FramePayload payload,
    String storagePath,
  ) async {
    final frame = payload.frame;
    await _client.post('$_api/sessions/$sessionId/frames', <String, dynamic>{
      'target_index': frame.targetId,
      'storage_path': storagePath,
      'checksum_sha256': payload.checksum,
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

  Future<void> _awaitJob(String jobId, void Function(String stage)? onStage) async {
    var consecutiveFailures = 0;
    final elapsed = Stopwatch()..start();
    while (true) {
      await Future<void>.delayed(_pollInterval);
      final Map<String, dynamic> job;
      try {
        job = await _client.get('$_api/jobs/$jobId');
        consecutiveFailures = 0;
      } on NetworkFailure {
        // A momentary connection drop while polling must not fail a handoff
        // whose job is fine on the server; only sustained silence does.
        consecutiveFailures++;
        if (consecutiveFailures > _consecutivePollFailuresAllowed) rethrow;
        continue;
      }
      final status = job['status'] as String?;
      final progress = (job['progress'] as num?)?.toInt() ?? 0;
      final stage = job['processingStage'] as String?;
      if (status == 'done') return;
      if (status == 'error') {
        throw BackendHandoffFailure(
          _jobError(job['errorMessage'] as String?),
        );
      }
      onStage?.call(
        'Stitching on Sitewise... ${stage == null || stage.isEmpty ? '' : '$stage '}'
        '($progress%)',
      );
      if (elapsed.elapsed > const Duration(minutes: 15)) {
        throw const BackendHandoffFailure(
          'The Sitewise stitching job is still running after 15 minutes. '
          'The frames are safe on the server — retry the handoff later to '
          'check again.',
        );
      }
    }
  }

  String _jobError(String? message) {
    if (message == null || message.isEmpty) {
      return 'The Sitewise stitching job failed. The frames are kept — '
          'retry the handoff.';
    }
    return '$message The frames are kept — you can retry the handoff.';
  }

  Future<void> _record(
    String stationId,
    FrameSyncStatus syncStatus, {
    String? backendSessionId,
    String? backendJobId,
    bool clearBackendJobId = false,
    bool clearLastError = false,
    String? error,
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
      );
    } on Object {
      // Bookkeeping must never cost the handoff; the backend rows are the
      // source of truth and a retry re-derives the state from the server.
      CaptureLog.log('Handoff state could not be recorded for $stationId');
    }
  }
}

/// One frame's bytes, its digest, and the manifest row it will confirm.
class _FramePayload {
  const _FramePayload({
    required this.frame,
    required this.bytes,
    required this.checksum,
  });

  final CapturedFrame frame;
  final List<int> bytes;
  final String checksum;
}
