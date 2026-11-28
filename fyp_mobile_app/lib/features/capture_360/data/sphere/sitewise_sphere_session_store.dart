import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:path/path.dart' as p;

import 'package:fyp/core/errors/failures.dart';
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

  /// The small pointer that remembers which station a tour is currently using.
  ///
  /// Normally this is the tour id. After an explicit recovery from an
  /// unreadable session it is a fresh sibling station; without this pointer a
  /// restart would look at the archived station again and lose the new
  /// capture. The pointer is bookkeeping only — it never changes a photograph
  /// or an archived session file.
  static Future<File> activeStationFile({
    required CaptureFrameStore frameStore,
    required String tourId,
  }) async {
    final root = await frameStore.tourRoot(tourId);
    return File(p.join(root, 'ar_capture', 'active_station.txt'));
  }

  /// The station id to reopen, or `null` when the tour has never written one.
  static Future<String?> readActiveStationId({
    required CaptureFrameStore frameStore,
    required String tourId,
  }) async {
    final file = await activeStationFile(
      frameStore: frameStore,
      tourId: tourId,
    );
    if (!await file.exists()) return null;
    final id = (await file.readAsString()).trim();
    return id.isEmpty ? null : id;
  }

  /// The station to use for [tourId], defaulting to the tour id itself.
  ///
  /// Every reader (preview, draft sync, upload-queue recovery) must use this
  /// instead of assuming the station id equals the tour id: after an explicit
  /// recovery they differ, and reading the archived station would show a
  /// stale panorama or resume the wrong attempt.
  static Future<String> stationIdForTour({
    required CaptureFrameStore frameStore,
    required String tourId,
  }) async =>
      await readActiveStationId(frameStore: frameStore, tourId: tourId) ??
      tourId;

  /// Persist this store's station as the tour's current one.
  ///
  /// [createSession] writes the pointer as part of creating a session, but an
  /// explicit recovery archives the old station and switches to a fresh one
  /// *before* any session exists. Without this call, a process death between
  /// those two moments would leave the pointer blank, and the next launch
  /// would resolve the tour back to the station that was just archived away.
  /// Bookkeeping only: no session file, photograph or upload document changes.
  Future<void> markActiveStation() => _writeActiveStation();

  Future<void> _writeActiveStation() async {
    final file = await activeStationFile(
      frameStore: frameStore,
      tourId: tourId,
    );
    await file.parent.create(recursive: true);
    await file.writeAsString(_stationId, flush: true);
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

  /// Renames this station directory to a timestamped sibling and returns the
  /// archive path. Nothing is deleted: every JPEG, manifest, session row and
  /// upload-queue document stays byte-for-byte intact under the new name, so
  /// the user can explicitly start a new capture without losing the evidence
  /// that could not be reinterpreted.
  Future<String> archiveStation({String reason = 'previous'}) async {
    final root = await frameStore.tourRoot(tourId);
    final parent = Directory(p.join(root, 'ar_capture'))
      ..createSync(recursive: true);
    final source = Directory(p.join(parent.path, _stationId));
    if (!await source.exists()) {
      await _clearActiveStationIfCurrent();
      return source.path;
    }
    final stamp = DateTime.now().toUtc().millisecondsSinceEpoch;
    final safeReason = reason.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    var archive = Directory(
      p.join(parent.path, '$_stationId.$safeReason-$stamp'),
    );
    var attempt = 1;
    while (await archive.exists()) {
      archive = Directory(
        p.join(parent.path, '$_stationId.$safeReason-$stamp-$attempt'),
      );
      attempt++;
    }
    await source.rename(archive.path);
    // The pointer is rewritten, not deleted: the archived directory keeps
    // everything it had, and a restart can no longer reopen it by mistake.
    await _clearActiveStationIfCurrent();
    debugPrint('SPHERE_SESSION_ARCHIVE: ${source.path} -> ${archive.path}');
    return archive.path;
  }

  Future<void> _clearActiveStationIfCurrent() async {
    final pointer = await activeStationFile(
      frameStore: frameStore,
      tourId: tourId,
    );
    if (!await pointer.exists()) return;
    if ((await pointer.readAsString()).trim() != _stationId) return;
    await pointer.writeAsString('', flush: true);
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
    } catch (error, stackTrace) {
      // Never silently replace an unreadable plan with a fresh session: that
      // is how a 44-target capture used to be reopened as a 38-target one and
      // have its saved frames reinterpreted. Log the ACTUAL FormatException /
      // StateError here; the user-facing message deliberately says only what
      // is safe and actionable.
      debugPrint('SPHERE_SESSION_READ: ${file.path} could not be read: $error');
      debugPrint('SPHERE_SESSION_READ_STACK: $stackTrace');
      throw IncompatibleCaptureSessionFailure(
        'The saved capture plan for this station could not be read. '
        'Your photographs and uploads are kept. Use “Start a new capture” '
        'to leave this attempt intact and begin another.',
      );
    }
  }

  Future<T> _enqueue<T>(Future<T> Function() action) {
    final next = _queue.then((_) => action());
    _queue = next.then<void>((_) {}, onError: (Object _) {});
    return next;
  }

  /// Persist the plan **atomically**.
  ///
  /// `writeAsString` truncates the target before it writes. A process death
  /// between those two steps leaves a half-written plan, and the next launch
  /// cannot read it — which strands every photograph already captured, since
  /// the frames are keyed by target id and the ids come from this document.
  ///
  /// Writing to a sibling temporary file and renaming it into place makes the
  /// switch atomic on the same filesystem: a reader either sees the previous
  /// complete document or the new complete one, never a truncated one. The
  /// temporary file is removed on failure so an aborted write leaves no
  /// residue that a later recovery pass might mistake for a session.
  Future<void> _write(_SessionDocument document) async {
    final file = await _sessionFile();
    await file.parent.create(recursive: true);
    final payload = jsonEncode(document.toJson());
    final temporary = File('${file.path}.tmp');
    try {
      await temporary.writeAsString(payload, flush: true);
      await temporary.rename(file.path);
    } on Object {
      try {
        if (await temporary.exists()) await temporary.delete();
      } on Object {
        // Best effort: a leftover .tmp is inert — it is never read as a plan.
      }
      rethrow;
    }
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
      final existing = document.session;
      // A new session must use the adaptive reference plan. A saved session is
      // authoritative instead: historical 38/56 captures must still reopen
      // under their own geometry rather than being rejected by a newer default.
      if (existing == null) {
        if (requiredTargetCount != kSphereTargetCount) {
          throw StateError(
            'New capture sessions must use the adaptive five-ring plan '
            '($kSphereTargetCount reference targets).',
          );
        }
        sitewisePlanVersionForCount(requiredTargetCount);
      } else if (existing.requiredTargetCount != requiredTargetCount) {
        throw StateError(
          'The saved capture session has a different target count.',
        );
      }
      final now = DateTime.now().toUtc();
      final session =
          document.session ??
          CaptureSession(
            sessionId: sessionId,
            userId: userId,
            propertyId: propertyId,
            requiredTargetCount: requiredTargetCount,
            planVersion: kSphereCapturePlanVersion,
            status: CaptureSessionStatus.draft,
            createdAt: now,
            updatedAt: now,
            panoramaStatus: PanoramaGenerationStatus.pending,
          );
      // Create-or-restore in one call: an existing session keeps its own
      // association, so a double tap on Start cannot fork it.
      document.session = session.copyWith(userId: userId, updatedAt: now);
      await _write(document);
      // Persist the station choice with the session. A recovered capture uses
      // a fresh sibling directory, and a restart must reopen that directory
      // rather than the archived one.
      await _writeActiveStation();
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
      if (plan == null ||
          frame.sessionId != plan.sessionId ||
          frame.targetId < 1 ||
          frame.targetId > plan.requiredTargetCount) {
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
