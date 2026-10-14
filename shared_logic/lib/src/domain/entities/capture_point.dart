/// Business concept for the 360° panorama capture flow.
///
/// Pure Dart — no Flutter, AR plugin, or vector_math imports. Describes a
/// single guided capture target (one frame of the panorama), including its
/// expected spherical position, alignment tolerances, and stitching metadata
/// (frame links + overlap neighbours).
class CapturePoint {
  final String name;
  final double pitch;
  final double yaw;
  final double roll;
  final double pitchTolerance;
  final double yawTolerance;
  final double rollTolerance;
  final int frameIndex;
  final int? previousFrame;
  final int? nextFrame;
  final double expectedYawDelta;
  final double expectedPitchDelta;
  final List<int> overlapNeighbors;

  const CapturePoint({
    required this.name,
    required this.pitch,
    required this.yaw,
    required this.roll,
    required this.pitchTolerance,
    required this.yawTolerance,
    required this.rollTolerance,
    required this.frameIndex,
    this.previousFrame,
    this.nextFrame,
    required this.expectedYawDelta,
    required this.expectedPitchDelta,
    required this.overlapNeighbors,
  });

  /// Whether a measured camera offset (degrees, relative to this target)
  /// counts as aligned and ready to capture.
  bool isAligned({required double yawDeg, required double pitchDeg}) =>
      yawDeg.abs() <= yawTolerance && pitchDeg.abs() <= pitchTolerance;
}
