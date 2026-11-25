import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:fyp/features/capture_360/data/capture_frame_store.dart';
import 'package:fyp/features/capture_360/domain/sphere/sphere_target.dart';
import 'package:fyp/features/capture_360/domain/sphere/sphere_capture_session.dart';

/// The 38-target capture session store, backed by one JSON file inside the
/// SiteWise tour directory.
///
/// The source implementation persisted sessions in its own SQLite database;
/// SiteWise already owns a per-tour directory
/// (`<appDocs>/sitewise/tours/<tourId>`) that holds the frames, the records
/// and the panorama, so the session metadata lives there too:
///
/// ```
/// <appDocs>/sitewise/tours/<tourId>/
///   ar_capture/<stationId>/
///     session.json       ← this store (session row + per-frame rows)
///     records.json       ← the stitcher's input (written by the repository)
///     frames/t01.jpg …
/// ```
///
/// The file doubles as the engine marker: it is written by [createSession]
/// *before* the camera starts, so any station directory that holds records but
/// no `session.json` was captured by the retired 26-target ARCore flow and
/// must not be resumed as a 38-target session.
///
/// Every write is serialised through one queue — the shutter, the stitcher and
/// a resume can all touch the file in the same second, and a lost update would
/// silently un-capture a frame. A read failure is bookkeeping only; callers in
/// the controller guard it so it can never cost a photograph.
class SitewiseSphereSessionStore implements CaptureSessionStore {
  SitewiseSphereSessionStore({
    required this.frameStore,
    required this.tourId,
    String? stationId,
  }) : _stationId = stationId ?? tourId;

  final CaptureFrameStore frameStore;
  final String tourId;
  final String _stationId;

  Future<void> _queue = Future<void>.value();

  static Future<String> sessionFilePath({
    required CaptureFrameStore frameStore,
    required String tourId,
    String? stationId,
  }) async {
    final root = await frameStore.tourRoot(tourId);
    return p.join(root, 'ar_capture', stationId ?? tourId, 'session.json');
  }

  /// Whether the station directory carries a 38-flow session marker.
  ///
  /// `false` for a station that has never been captured with this flow, which
  /// is how a legacy 26-target capture is told apart from a fresh one.
  static Future<bool> hasSessionMarker({
    required CaptureFrameStore frameStore,
    required String tourId,
    String? stationId,
  }) async {
    final file = File(
      await sessionFilePath(
        frameStore: frameStore,
        tourId: tourId,
        stationId: stationId,
      ),
    );
    return file.exists();
  }

  Future<File> _sessionFile() => sessionFilePath(
    frameStore: frameStore,
    tourId: tourId,
    stationId: _stationId,
  ).then(File.new);

  Future<_SessionDocument> _read() async {
    final file = await _sessionFile();
    if (!await file.exists()) {
      return _SessionDocument.empty(_stationId);
    }
    try {
      final json =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return _SessionDocument.fromJson(json, fallbackId: _stationId);
    } catch (error) {
      // Do not silently replace a corrupt plan with a fresh 38-target session.
      throw StateError('Saved capture session cannot be read. Photos are kept.');
    }
  }

  Future<T> _enqueue<T>(Future<T> Function() action) {
    final next = _queue.then((_) => action());
    _queue = next.then<void>((_) {}, onError: (Object _) {});
    return next;
  }

  Future<void> _write(_SessionDocument document) async {
    final file = await _sessionFile();
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(document.toJson()), flush: true);
  }

  @override
  Future<CaptureSession> createSession({
    required String sessionId,
    String? userId,
    int? propertyId,
    int requiredTargetCount = kSphereTargetCount,
  }) {
    return _enqueue(() async {
      final document = await _read();
      sitewisePlanVersionForCount(requiredTargetCount);
      final now = DateTime.now().toUtc();
      final session =
          document.session ??
          CaptureSession(
            sessionId: sessionId,
            userId: userId,
            propertyId: propertyId,
            requiredTargetCount: requiredTargetCount,
            status: CaptureSessionStatus.draft,
            createdAt: now,
            updatedAt: now,
            panoramaStatus: PanoramaGenerationStatus.pending,
          );
      // Create-or-restore in one call: an existing session keeps its own
      // association, so a double tap on Start cannot fork it.
      document.session = session.copyWith(userId: userId, updatedAt: now);
      await _write(document);
      return document.session!;
    });
  }

  @override
  Future<CaptureSession?> getSession(String sessionId) async {
    final document = await _read();
    return document.session;
  }

  @override
  Future<CaptureSession?> findResumableSession({String? userId}) async {
    final session = await getSession(_stationId);
    if (session == null || !session.status.isResumable) return null;
    if (userId != null && session.userId != userId) return null;
    return session;
  }

  @override
  Future<CapturedFrame> saveFrame(CapturedFrame frame) {
    return _enqueue(() async {
      final document = await _read();
      final plan = document.session;
      if (plan == null || frame.sessionId != plan.sessionId ||
          frame.targetId < 1 || frame.targetId > plan.requiredTargetCount) {
        throw StateError('Photo does not belong to the saved capture plan.');
      }
      document.frames.removeWhere((f) => f.targetId == frame.targetId);
      document.frames.add(frame);
      document.frames.sort((a, b) => a.targetId.compareTo(b.targetId));
      final session = document.session;
      if (session != null &&
          session.status != CaptureSessionStatus.complete &&
          session.status != CaptureSessionStatus.panoramaReady) {
        document.session = session.copyWith(
          status: CaptureSessionStatus.capturing,
        );
      }
      await _write(document);
      return frame;
    });
  }

  @override
  Future<void> markSessionStatus({
    required String sessionId,
    required CaptureSessionStatus status,
    String? error,
  }) {
    return _enqueue(() async {
      final document = await _read();
      final session = document.session;
      if (session == null) return;
      document.session = session.copyWith(status: status, lastError: error);
      await _write(document);
    });
  }

  @override
  Future<void> attachProperty({
    required String sessionId,
    required int propertyId,
  }) {
    return _enqueue(() async {
      final document = await _read();
      final session = document.session;
      if (session == null) return;
      document.session = session.copyWith(propertyId: propertyId);
      await _write(document);
    });
  }

  @override
  Future<List<CapturedFrame>> loadFrames(String sessionId) async {
    final document = await _read();
    return List<CapturedFrame>.unmodifiable(document.frames);
  }

  @override
  Future<int> countFrames(String sessionId) async {
    final document = await _read();
    return document.frames.length;
  }

  @override
  Future<void> savePanorama({
    required String sessionId,
    required String? localPanoramaPath,
    required PanoramaGenerationStatus status,
    String? error,
  }) {
    return _enqueue(() async {
      final document = await _read();
      final session = document.session;
      if (session == null) return;
      document.session = session.copyWith(
        localPanoramaPath: localPanoramaPath,
        clearPanoramaPath: localPanoramaPath == null,
        panoramaStatus: status,
        lastError: error,
        clearLastError: error == null,
        status: status == PanoramaGenerationStatus.ready
            ? CaptureSessionStatus.panoramaReady
            : session.status,
      );
      await _write(document);
    });
  }

  @override
  Future<void> saveBackendHandoff({
    required String sessionId,
    required FrameSyncStatus syncStatus,
    String? backendSessionId,
    String? backendJobId,
    bool clearBackendJobId = false,
    String? error,
    bool clearLastError = false,
    FrameSyncStatus? panoramaSyncStatus,
    FrameSyncStatus? backupSyncStatus,
    int? backupUploaded,
    int? backupTotal,
    String? backendPanoramaId,
    bool clearBackendPanoramaId = false,
  }) {
    return _enqueue(() async {
      final document = await _read();
      final session = document.session;
      if (session == null) return;
      document.session = session.copyWith(
        backendSessionId: backendSessionId,
        backendJobId: backendJobId,
        clearBackendJobId: clearBackendJobId,
        syncStatus: syncStatus,
        lastError: error,
        clearLastError: clearLastError,
        panoramaSyncStatus: panoramaSyncStatus,
        backupSyncStatus: backupSyncStatus,
        backupUploaded: backupUploaded,
        backupTotal: backupTotal,
        backendPanoramaId: backendPanoramaId,
        clearBackendPanoramaId: clearBackendPanoramaId,
      );
      await _write(document);
    });
  }

  @override
  Future<void> deleteSession(String sessionId) {
    return _enqueue(() async {
      final file = await _sessionFile();
      if (await file.exists()) await file.delete();
    });
  }
}

/// The on-disk document: one session row plus its per-frame rows, reusing the
/// source implementation's SQLite row format so the JSON is stable and
/// readable.
class _SessionDocument {
  _SessionDocument({this.session, required List<CapturedFrame> frames})
    : frames = List<CapturedFrame>.of(frames);

  factory _SessionDocument.empty(String sessionId) =>
      _SessionDocument(frames: <CapturedFrame>[]);

  factory _SessionDocument.fromJson(
    Map<String, dynamic> json, {
    required String fallbackId,
  }) {
    final sessionRow = json['session'];
    CaptureSession? session;
    if (sessionRow is Map<String, dynamic>) {
      session = CaptureSession.fromRow(sessionRow);
    } else if (sessionRow is Map) {
      session = CaptureSession.fromRow(sessionRow.cast<String, Object?>());
    }
    final frameRows = json['frames'];
    final frames = <CapturedFrame>[];
    if (frameRows is List) {
      for (final row in frameRows) {
        if (row is Map) {
          frames.add(CapturedFrame.fromRow(row.cast<String, Object?>()));
        }
      }
    }
    return _SessionDocument(session: session, frames: frames);
  }

  CaptureSession? session;
  final List<CapturedFrame> frames;

  Map<String, Object?> toJson() => <String, Object?>{
    'session': session?.toRow(),
    'frames': <Object?>[for (final frame in frames) frame.toRow()],
  };
}
