import 'package:fyp/features/capture_360/domain/models/capture_record.dart';
import 'package:fyp/features/capture_360/domain/sphere/sphere_target.dart';
import 'package:fyp/features/capture_360/domain/virtual_tour/math/quaternions.dart';
import 'package:fyp/features/capture_360/domain/virtual_tour/math/vectors.dart';

/// Where a 38-target capture session is in its local lifecycle.
///
/// These are **local** states. SiteWise Mobile has no cloud capture-job table:
/// the property/tour association lives in the tour record and the panorama
/// upload goes through the existing virtual-tour API, so these statuses only
/// describe what is on this device.
enum CaptureSessionStatus {
  /// The row exists; no photograph has been saved yet.
  draft('draft'),

  /// At least one target has been captured and the session is resumable.
  capturing('capturing'),

  /// All [CaptureSession.requiredTargetCount] targets are on disk.
  complete('complete'),

  /// The panorama was generated and the file is on disk.
  panoramaReady('panorama_ready'),

  /// The panorama could not be generated; the frames are still intact.
  panoramaFailed('panorama_failed'),

  /// The user abandoned the session. Never produced automatically.
  abandoned('abandoned');

  const CaptureSessionStatus(this.wireName);

  /// The value stored in `session.json`'s `status` field. Snake case, matching
  /// the source implementation's wire format, so a session file written by
  /// either build reads back the same.
  final String wireName;

  static CaptureSessionStatus fromWire(String? value) {
    for (final status in CaptureSessionStatus.values) {
      if (status.wireName == value) return status;
    }
    return CaptureSessionStatus.draft;
  }

  /// Whether reopening the app should offer to continue this session.
  bool get isResumable =>
      this == CaptureSessionStatus.draft ||
      this == CaptureSessionStatus.capturing ||
      this == CaptureSessionStatus.complete;
}

/// Whether a panorama exists locally, and whether generating it failed.
enum PanoramaGenerationStatus {
  pending,
  generating,
  ready,
  failed;

  static PanoramaGenerationStatus fromWire(String? value) {
    for (final status in PanoramaGenerationStatus.values) {
      if (status.name == value) return status;
    }
    return PanoramaGenerationStatus.pending;
  }
}

/// Where this session stands in the SiteWise backend handoff.
///
/// These mirror the backend lifecycle rather than inventing values: the
/// session row exists server-side once [uploadPending] is reached, the
/// processing job runs while [processing], and the canonical panorama row
/// exists when [ready]. [failed] is the honest terminal state of any handoff
/// step — the local frames and the device panorama are never touched by it.
enum FrameSyncStatus {
  /// No backend session: a demo build, or the draft was never authorized.
  none,

  /// A backend session exists; the original frames are not fully uploaded.
  uploadPending,

  /// Originals are being uploaded / confirmed through the backend API.
  uploading,

  /// The backend stitching job owns the session; status is being polled.
  processing,

  /// The backend confirmed the canonical panorama is stored.
  ready,

  /// A handoff step failed; Retry re-runs the coordinator from here.
  failed;

  static FrameSyncStatus fromWire(String? value) {
    for (final status in FrameSyncStatus.values) {
      if (status.name == value) return status;
    }
    return FrameSyncStatus.none;
  }
}

/// One 38-target capture session.
///
/// The primary key is the session id, which is also the station directory name
/// the SiteWise tour repository uses. Keeping them equal is what makes the
/// session file and the JPEG paths on disk describe the same thing, so the
/// stitching implementation keeps reading the paths it always read.
///
/// SiteWise adaptation: [propertyId] is kept for interface parity with the
/// source implementation, but SiteWise draft identifiers are strings carried by
/// the tour record, so the capture host leaves it `null` rather than coercing a
/// string id into an integer. The session file lives *inside* the tour
/// directory, which is the real property association.
class CaptureSession {
  const CaptureSession({
    required this.sessionId,
    required this.userId,
    required this.propertyId,
    required this.requiredTargetCount,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    required this.panoramaStatus,
    this.localPanoramaPath,
    this.lastError,
    this.backendSessionId,
    this.backendJobId,
    this.syncStatus = FrameSyncStatus.none,
    this.panoramaSyncStatus = FrameSyncStatus.none,
    this.backupSyncStatus = FrameSyncStatus.none,
    this.backupUploaded = 0,
    this.backupTotal = 0,
    this.backendPanoramaId,
  });

  final String sessionId;

  /// The signed-in account, or `null` for an anonymous capture.
  final String? userId;

  /// Kept `null` by the SiteWise host: the string draft identifier stays on
  /// the tour record and is never converted to an integer.
  final int? propertyId;

  /// Always [kSphereTargetCount] for this flow; stored rather than assumed so
  /// a future layout change is a data migration, not a code hunt.
  final int requiredTargetCount;

  int get capturePlanVersion => sitewisePlanVersionForCount(requiredTargetCount);

  static int _readPlanCount(Map<String, Object?> row) {
    final raw = row['required_target_count'];
    final count = raw ?? kSphereTargetCount;
    if (count is! int || (count != 38 && count != 56)) {
      throw const FormatException('Invalid saved capture plan count');
    }
    final version = row['capture_plan_version'];
    if (version != null && '$version' != '${sitewisePlanVersionForCount(count)}') {
      throw const FormatException('Saved capture plan version does not match its count');
    }
    return count;
  }

  final CaptureSessionStatus status;

  final DateTime createdAt;
  final DateTime updatedAt;

  /// Absolute path of the stitched equirectangular JPEG, when it exists.
  final String? localPanoramaPath;

  final PanoramaGenerationStatus panoramaStatus;

  /// The last user-facing failure for this session, or `null`.
  final String? lastError;

  /// The `fyp.capture_sessions` row id on the SiteWise backend, once the
  /// handoff has created it. Absent for a demo build or an offline capture.
  final String? backendSessionId;

  /// The backend stitching job id currently associated with the session,
  /// while polling is (or was last) in flight.
  final String? backendJobId;

  /// Where the backend handoff stands. Written by the coordinator only.
  final FrameSyncStatus syncStatus;

  /// The device-generated panorama's cloud state, tracked independently from
  /// the 38 original photographs' backup queue.
  final FrameSyncStatus panoramaSyncStatus;

  /// The 38 original photographs' backup state. A completed panorama upload
  /// and a completed backup are different milestones.
  final FrameSyncStatus backupSyncStatus;

  /// How many originals the cloud backup has confirmed so far.
  final int backupUploaded;

  /// Total originals the backup queue expects.
  final int backupTotal;

  /// The canonical `fyp.panoramas` row id, once the device panorama is
  /// confirmed by FastAPI.
  final String? backendPanoramaId;

  bool get isComplete =>
      status == CaptureSessionStatus.complete ||
      status == CaptureSessionStatus.panoramaReady;

  bool get hasPanorama =>
      panoramaStatus == PanoramaGenerationStatus.ready &&
      localPanoramaPath != null;

  CaptureSession copyWith({
    String? userId,
    int? propertyId,
    bool clearProperty = false,
    CaptureSessionStatus? status,
    DateTime? updatedAt,
    String? localPanoramaPath,
    bool clearPanoramaPath = false,
    PanoramaGenerationStatus? panoramaStatus,
    String? lastError,
    bool clearLastError = false,
    String? backendSessionId,
    bool clearBackendSessionId = false,
    String? backendJobId,
    bool clearBackendJobId = false,
    FrameSyncStatus? syncStatus,
    FrameSyncStatus? panoramaSyncStatus,
    FrameSyncStatus? backupSyncStatus,
    int? backupUploaded,
    int? backupTotal,
    String? backendPanoramaId,
    bool clearBackendPanoramaId = false,
  }) => CaptureSession(
    sessionId: sessionId,
    userId: userId ?? this.userId,
    propertyId: clearProperty ? null : (propertyId ?? this.propertyId),
    requiredTargetCount: requiredTargetCount,
    status: status ?? this.status,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    localPanoramaPath: clearPanoramaPath
        ? null
        : (localPanoramaPath ?? this.localPanoramaPath),
    panoramaStatus: panoramaStatus ?? this.panoramaStatus,
    lastError: clearLastError ? null : (lastError ?? this.lastError),
    backendSessionId: clearBackendSessionId
        ? null
        : (backendSessionId ?? this.backendSessionId),
    backendJobId: clearBackendJobId
        ? null
        : (backendJobId ?? this.backendJobId),
    syncStatus: syncStatus ?? this.syncStatus,
    panoramaSyncStatus: panoramaSyncStatus ?? this.panoramaSyncStatus,
    backupSyncStatus: backupSyncStatus ?? this.backupSyncStatus,
    backupUploaded: backupUploaded ?? this.backupUploaded,
    backupTotal: backupTotal ?? this.backupTotal,
    backendPanoramaId: clearBackendPanoramaId
        ? null
        : (backendPanoramaId ?? this.backendPanoramaId),
  );

  Map<String, Object?> toRow() => <String, Object?>{
    'session_id': sessionId,
    'user_id': userId,
    'property_id': propertyId,
    'required_target_count': requiredTargetCount,
    'capture_plan_version': capturePlanVersion,
    'status': status.wireName,
    'created_at': createdAt.toUtc().millisecondsSinceEpoch,
    'updated_at': updatedAt.toUtc().millisecondsSinceEpoch,
    'local_panorama_path': localPanoramaPath,
    'panorama_status': panoramaStatus.name,
    'last_error': lastError,
    'backend_session_id': backendSessionId,
    'backend_job_id': backendJobId,
    'sync_status': syncStatus.name,
    'panorama_sync_status': panoramaSyncStatus.name,
    'backup_sync_status': backupSyncStatus.name,
    'backup_uploaded': backupUploaded,
    'backup_total': backupTotal,
    'backend_panorama_id': backendPanoramaId,
  };

  static CaptureSession fromRow(Map<String, Object?> row) => CaptureSession(
    sessionId: row['session_id']! as String,
    userId: row['user_id'] as String?,
    propertyId: (row['property_id'] as num?)?.toInt(),
    requiredTargetCount: _readPlanCount(row),
    status: CaptureSessionStatus.fromWire(row['status'] as String?),
    createdAt: _time(row['created_at']),
    updatedAt: _time(row['updated_at']),
    localPanoramaPath: row['local_panorama_path'] as String?,
    panoramaStatus: PanoramaGenerationStatus.fromWire(
      row['panorama_status'] as String?,
    ),
    lastError: row['last_error'] as String?,
    backendSessionId: row['backend_session_id'] as String?,
    backendJobId: row['backend_job_id'] as String?,
    syncStatus: FrameSyncStatus.fromWire(row['sync_status'] as String?),
    panoramaSyncStatus: FrameSyncStatus.fromWire(
      row['panorama_sync_status'] as String?,
    ),
    backupSyncStatus: FrameSyncStatus.fromWire(
      row['backup_sync_status'] as String?,
    ),
    backupUploaded: (row['backup_uploaded'] as num?)?.toInt() ?? 0,
    backupTotal: (row['backup_total'] as num?)?.toInt() ?? 0,
    backendPanoramaId: row['backend_panorama_id'] as String?,
  );
}

/// One saved photograph, as the session file records it.
///
/// The JPEG itself stays in application file storage — only its path is stored
/// here. Duplicating 38 multi-megabyte frames as embedded bytes would triple
/// the app's storage use and make every read decode megabytes it does not
/// need.
class CapturedFrame {
  const CapturedFrame({
    required this.sessionId,
    required this.targetId,
    required this.imagePath,
    required this.capturedAt,
    required this.targetYawDegrees,
    required this.targetPitchDegrees,
    required this.cameraOrientation,
    required this.imageWidth,
    required this.imageHeight,
    required this.alignmentErrorDeg,
    this.sourceImageWidth = 0,
    this.sourceImageHeight = 0,
    this.cropOffsetX = 0,
    this.cropOffsetY = 0,
    this.toleranceDeg = 0,
    this.captureStatus = 'captured',
    this.qualityJson,
  });

  final String sessionId;

  /// 1…38.
  final int targetId;

  /// Absolute path of the JPEG on this device.
  final String imagePath;

  final DateTime capturedAt;

  final double targetYawDegrees;
  final double targetPitchDegrees;

  /// The device quaternion at the shutter.
  final Quat cameraOrientation;

  final int imageWidth;
  final int imageHeight;
  final int sourceImageWidth;
  final int sourceImageHeight;
  final int cropOffsetX;
  final int cropOffsetY;

  /// The 3-D alignment error at the shutter, in degrees.
  final double alignmentErrorDeg;

  /// The tolerance in force when the shutter fired.
  final double toleranceDeg;

  /// `captured` for a normal frame. Kept as text so a future "rejected" or
  /// "superseded" state does not need a format change.
  final String captureStatus;

  /// The device quality verification report for this photograph, JSON-encoded
  /// [FrameQualityReport] (`domain/quality/`), or `null` when the frame was
  /// captured before quality checking existed. The JPEG itself is never
  /// influenced by this field: a warning keeps the photograph exactly as it
  /// was saved, and only the user decides on a retake.
  final String? qualityJson;

  /// Projects this row back into the record the stitcher consumes, so a
  /// restored session can regenerate its panorama without a second code path.
  CaptureRecord toCaptureRecord() => CaptureRecord(
    stationId: sessionId,
    targetId: targetId,
    imagePath: imagePath,
    capturedAt: capturedAt,
    targetYawDegrees: targetYawDegrees,
    targetPitchDegrees: targetPitchDegrees,
    // 3DoF measures no translation: the sphere centre is the camera position
    // by definition, which is what the capture path records too.
    cameraPosition: Vec3.zero,
    cameraOrientation: cameraOrientation,
    alignmentErrorDeg: alignmentErrorDeg,
    anchored: false,
    imageWidth: imageWidth,
    imageHeight: imageHeight,
    sourceImageWidth: sourceImageWidth,
    sourceImageHeight: sourceImageHeight,
    cropOffsetX: cropOffsetX,
    cropOffsetY: cropOffsetY,
    imageFormat: 'jpeg',
    toleranceDeg: toleranceDeg,
  );

  /// Re-attaches a quality report to this frame without touching any of the
  /// capture evidence. Used by the controller after the analyzer finishes —
  /// the JPEG and the capture metadata stay byte-for-byte identical.
  CapturedFrame withQualityJson(String? qualityJson) => CapturedFrame(
    sessionId: sessionId,
    targetId: targetId,
    imagePath: imagePath,
    capturedAt: capturedAt,
    targetYawDegrees: targetYawDegrees,
    targetPitchDegrees: targetPitchDegrees,
    cameraOrientation: cameraOrientation,
    imageWidth: imageWidth,
    imageHeight: imageHeight,
    sourceImageWidth: sourceImageWidth,
    sourceImageHeight: sourceImageHeight,
    cropOffsetX: cropOffsetX,
    cropOffsetY: cropOffsetY,
    alignmentErrorDeg: alignmentErrorDeg,
    toleranceDeg: toleranceDeg,
    captureStatus: captureStatus,
    qualityJson: qualityJson,
  );

  static CapturedFrame fromCaptureRecord(CaptureRecord record) => CapturedFrame(
    sessionId: record.stationId,
    targetId: record.targetId,
    imagePath: record.imagePath,
    capturedAt: record.capturedAt,
    targetYawDegrees: record.targetYawDegrees,
    targetPitchDegrees: record.targetPitchDegrees,
    cameraOrientation: record.cameraOrientation,
    imageWidth: record.imageWidth,
    imageHeight: record.imageHeight,
    sourceImageWidth: record.sourceImageWidth,
    sourceImageHeight: record.sourceImageHeight,
    cropOffsetX: record.cropOffsetX,
    cropOffsetY: record.cropOffsetY,
    alignmentErrorDeg: record.alignmentErrorDeg,
    toleranceDeg: record.toleranceDeg,
  );

  Map<String, Object?> toRow() => <String, Object?>{
    'session_id': sessionId,
    'target_id': targetId,
    'image_path': imagePath,
    'captured_at': capturedAt.toUtc().millisecondsSinceEpoch,
    'target_yaw_deg': targetYawDegrees,
    'target_pitch_deg': targetPitchDegrees,
    'camera_qx': cameraOrientation.x,
    'camera_qy': cameraOrientation.y,
    'camera_qz': cameraOrientation.z,
    'camera_qw': cameraOrientation.w,
    'image_width': imageWidth,
    'image_height': imageHeight,
    'source_width': sourceImageWidth,
    'source_height': sourceImageHeight,
    'crop_offset_x': cropOffsetX,
    'crop_offset_y': cropOffsetY,
    'alignment_error_deg': alignmentErrorDeg,
    'tolerance_deg': toleranceDeg,
    'capture_status': captureStatus,
    'quality_json': qualityJson,
  };

  static CapturedFrame fromRow(Map<String, Object?> row) => CapturedFrame(
    sessionId: row['session_id']! as String,
    targetId: (row['target_id']! as num).toInt(),
    imagePath: row['image_path']! as String,
    capturedAt: _time(row['captured_at']),
    targetYawDegrees: (row['target_yaw_deg'] as num?)?.toDouble() ?? 0,
    targetPitchDegrees: (row['target_pitch_deg'] as num?)?.toDouble() ?? 0,
    cameraOrientation: Quat(
      (row['camera_qx'] as num?)?.toDouble() ?? 0,
      (row['camera_qy'] as num?)?.toDouble() ?? 0,
      (row['camera_qz'] as num?)?.toDouble() ?? 0,
      (row['camera_qw'] as num?)?.toDouble() ?? 1,
    ),
    imageWidth: (row['image_width'] as num?)?.toInt() ?? 0,
    imageHeight: (row['image_height'] as num?)?.toInt() ?? 0,
    sourceImageWidth: (row['source_width'] as num?)?.toInt() ?? 0,
    sourceImageHeight: (row['source_height'] as num?)?.toInt() ?? 0,
    cropOffsetX: (row['crop_offset_x'] as num?)?.toInt() ?? 0,
    cropOffsetY: (row['crop_offset_y'] as num?)?.toInt() ?? 0,
    alignmentErrorDeg: (row['alignment_error_deg'] as num?)?.toDouble() ?? 0,
    toleranceDeg: (row['tolerance_deg'] as num?)?.toDouble() ?? 0,
    captureStatus: row['capture_status'] as String? ?? 'captured',
    qualityJson: row['quality_json'] as String?,
  );
}

DateTime _time(Object? value) => _timeOrNull(value) ?? DateTime.now().toUtc();

DateTime? _timeOrNull(Object? value) {
  if (value == null) return null;
  final millis = (value as num).toInt();
  return DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true);
}

/// The local-first metadata store contract for the 38-target flow.
///
/// The source implementation backed this with SQLite; SiteWise Mobile backs it
/// with one JSON file per session inside the tour directory (see
/// `SitewiseSphereSessionStore`). The controller treats it as optional
/// bookkeeping: a metadata write failing must never cost the user a photograph.
abstract class CaptureSessionStore {
  /// Creates the session, or returns the existing one with the same id.
  ///
  /// "Create or restore" in one call is what makes reopening the app safe: a
  /// double tap on Start must not produce two rows for one session.
  Future<CaptureSession> createSession({
    required String sessionId,
    String? userId,
    int? propertyId,
    int requiredTargetCount = kSphereTargetCount,
  });

  Future<CaptureSession?> getSession(String sessionId);

  /// The newest session for [userId] that still has targets to capture.
  Future<CaptureSession?> findResumableSession({String? userId});

  /// Records a saved JPEG.
  ///
  /// Replaces any existing row for the same target — a retake overwrites the
  /// evidence instead of appending a second photograph — and advances the
  /// session to `capturing`.
  Future<CapturedFrame> saveFrame(CapturedFrame frame);

  /// Moves a session to an explicit lifecycle state.
  Future<void> markSessionStatus({
    required String sessionId,
    required CaptureSessionStatus status,
    String? error,
  });

  /// Links a session to a property id. Unused by the SiteWise host, which
  /// carries the string draft id on the tour record instead.
  Future<void> attachProperty({
    required String sessionId,
    required int propertyId,
  });

  /// All saved frames for [sessionId], ordered by target id.
  Future<List<CapturedFrame>> loadFrames(String sessionId);

  /// How many of the [requiredTargetCount] targets are saved.
  Future<int> countFrames(String sessionId);

  /// Records the stitched panorama, or a stitch failure.
  Future<void> savePanorama({
    required String sessionId,
    required String? localPanoramaPath,
    required PanoramaGenerationStatus status,
    String? error,
  });

  /// Records the backend handoff state written by the capture coordinator.
  ///
  /// The identifiers are sticky: passing `null` keeps the existing value, so
  /// a failure recorded mid-upload still remembers which backend session to
  /// resume. [clearBackendJobId] / [clearLastError] drop those values instead
  /// of keeping them.
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
  });

  /// Removes the session and its metadata file. The JPEGs are untouched.
  Future<void> deleteSession(String sessionId);
}
