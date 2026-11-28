/// The legacy 26-target ARCore layout's constants, kept verbatim.
///
/// The VIO/ARCore capture engine that computed these poses has been removed;
/// the tour preview's station bookkeeping ([targetSphere], [capture_station])
/// still names its ring layout through this table, so the constants survive as
/// the historical layout's record. Nothing here is used by the active sphere
/// capture flow.
abstract final class VioSphereConstants {
  /// How far in front of the station every target sits, in metres.
  static const double targetRadiusM = 1.0;

  /// Maximum allowed station-centre drift, in metres. **Inclusive**: exactly
  /// 0.20 m is inside, 0.2000001 m is not.
  static const double maxStationDriftM = 0.20;

  /// Maximum allowed 3D alignment error, in degrees. **Inclusive**.
  static const double maxAlignmentErrorDeg = 3.0;

  /// How long the pose must hold still before the shutter may fire.
  static const Duration stabilityWindow = Duration(milliseconds: 600);

  /// The oldest pose that may still be acted on, in milliseconds.
  static const Duration maxPoseAge = Duration(milliseconds: 250);

  /// How far the orientation may wander across the window, in degrees.
  static const double maxWindowOrientationDriftDeg = 1.5;

  /// How far the position may wander across the window, in metres.
  static const double maxWindowPositionDriftM = 0.03;

  /// The fastest rotation that still counts as "held still", in degrees/second.
  static const double maxAngularVelocityDegPerSec = 5.0;

  /// The largest gap between two consecutive poses that may still count as a
  /// continuous hold, in milliseconds.
  static const Duration maxSampleGap = Duration(milliseconds: 150);

  /// The baseline the angular rate is measured over, in milliseconds.
  static const Duration rateBaseline = Duration(milliseconds: 100);

  /// How much horizontal forward component calibration needs.
  static const double minCalibrationHorizontalComponent = 0.17364817766693041;

  /// Horizontal ring: 8 targets at 0°, every 45°.
  static const int horizontalCount = 8;
  static const double horizontalAzimuthStepDeg = 45.0;

  /// Upper and lower rings: 8 targets each at ±40°, every 45°.
  static const int upperCount = 8;
  static const int lowerCount = 8;
  static const double upperElevationDeg = 40.0;
  static const double lowerElevationDeg = -40.0;
  static const double ringAzimuthStepDeg = 45.0;

  /// The two exact poles.
  static const double zenithElevationDeg = 90.0;
  static const double nadirElevationDeg = -90.0;

  /// 8 + 8 + 8 + 1 + 1.
  static const int nodeCount = 26;

  /// Index boundaries:
  /// horizontal 0–7, upper 8–15, lower 16–23, zenith 24, nadir 25.
  static const int upperFirstIndex = horizontalCount;
  static const int lowerFirstIndex = upperFirstIndex + upperCount;
  static const int zenithIndex = lowerFirstIndex + lowerCount;
  static const int nadirIndex = zenithIndex + 1;

  static const String horizontalRingName = 'Horizontal';
  static const String upperRingName = 'Upper';
  static const String lowerRingName = 'Lower';
  static const String zenithRingName = 'Zenith';
  static const String nadirRingName = 'Nadir';
}

/// The AR tracking states the legacy station model persisted.
///
/// The ARCore session that produced them is gone; the values survive because
/// stored station rows still carry `trackingStatus` as a string and
/// [CaptureStation.isCalibrated] reads it.
enum TrackingState {
  /// AR is present but no pose has arrived yet.
  initialising,

  /// A valid pose is being reported.
  tracking,

  /// AR lost confidence but has not given up. The pose may be stale.
  paused,

  /// AR stopped. The session has to be torn down and restarted.
  stopped,

  /// There is no AR system on this device.
  unavailable;

  /// Whether a pose from this state may be used to guide the user.
  bool get usable => this == TrackingState.tracking;
}
