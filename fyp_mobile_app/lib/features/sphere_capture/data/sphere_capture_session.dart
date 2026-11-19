import 'package:fyp/features/capture/domain/models/capture_record.dart';
import 'package:fyp/features/sphere_capture/domain/sphere_target.dart';
import 'package:fyp/features/virtual_tour/domain/math/quaternions.dart';
import 'package:fyp/features/virtual_tour/domain/math/vectors.dart';

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

  final CaptureSessionStatus status;

  final DateTime createdAt;
  final DateTime updatedAt;

  /// Absolute path of the stitched equirectangular JPEG, when it exists.
  final String? localPanoramaPath;

  final PanoramaGenerationStatus panoramaStatus;

  /// The last user-facing failure for this session, or `null`.
  final String? lastError;

  bool get isComplete => status == CaptureSessionStatus.complete ||
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
  );

  Map<String, Object?> toRow() => <String, Object?>{
    'session_id': sessionId,
    'user_id': userId,
    'property_id': propertyId,
    'required_target_count': requiredTargetCount,
    'status': status.wireName,
    'created_at': createdAt.toUtc().millisecondsSinceEpoch,
    'updated_at': updatedAt.toUtc().millisecondsSinceEpoch,
    'local_panorama_path': localPanoramaPath,
    'panorama_status': panoramaStatus.name,
    'last_error': lastError,
  };

  static CaptureSession fromRow(Map<String, Object?> row) => CaptureSession(
    sessionId: row['session_id']! as String,
    userId: row['user_id'] as String?,
    propertyId: (row['property_id'] as num?)?.toInt(),
    requiredTargetCount:
        (row['required_target_count'] as num?)?.toInt() ?? kSphereTargetCount,
    status: CaptureSessionStatus.fromWire(row['status'] as String?),
    createdAt: _time(row['created_at']),
    updatedAt: _time(row['updated_at']),
    localPanoramaPath: row['local_panorama_path'] as String?,
    panoramaStatus: PanoramaGenerationStatus.fromWire(
      row['panorama_status'] as String?,
    ),
    lastError: row['last_error'] as String?,
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

  /// Removes the session and its metadata file. The JPEGs are untouched.
  Future<void> deleteSession(String sessionId);
}
