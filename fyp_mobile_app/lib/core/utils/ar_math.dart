import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart' as v;

/// Pure-Dart AR math helpers for the panorama capture flow.
///
/// No Flutter or ar_flutter_plugin dependencies — safe to use from any layer.

v.Vector3 sphericalToVector(
  double pitchDeg,
  double yawDeg, {
  double radius = 3,
}) {
  final p = pitchDeg * math.pi / 180;
  final y = yawDeg * math.pi / 180;
  return v.Vector3(
    radius * math.cos(p) * math.sin(y),
    radius * math.sin(p),
    -radius * math.cos(p) * math.cos(y),
  );
}

/// Camera offset of [targetPosition] expressed in camera-local space.
/// [yawDeg]/[pitchDeg] are the signed errors (target relative to where the
/// camera currently looks); both are wrapped to [-180, 180], so a target at
/// 0° seen from 355° reports +5°, not 355°.
class AlignmentReading {
  final double yawDeg;
  final double pitchDeg;
  final bool aligned;

  const AlignmentReading({
    required this.yawDeg,
    required this.pitchDeg,
    required this.aligned,
  });

  double get yawError => yawDeg.abs();
  double get pitchError => pitchDeg.abs();
}

/// Wraps any angle in degrees to [-180, 180).
double wrapAngleDeg(double degrees) {
  var a = degrees % 360;
  if (a >= 180) a -= 360;
  if (a < -180) a += 360;
  return a;
}

/// Signed smallest angular difference from [from] to [to] in degrees,
/// in [-180, 180]. `angleDifferenceDeg(355, 0)` is `+5`, not `-355`.
double angleDifferenceDeg(double from, double to) => wrapAngleDeg(to - from);

/// Transforms [targetPosition] into camera-local space using [cameraPosition]
/// and [cameraRotation], then derives the yaw/pitch offset in degrees and
/// whether it falls within ([yawTolerance], [pitchTolerance]).
///
/// Behaviour matches the original implementation; a zero-length direction
/// (camera exactly on the target) is guarded to `(0, 0, not aligned)` instead
/// of producing NaN.
AlignmentReading computeAlignment({
  required v.Vector3 cameraPosition,
  required v.Quaternion cameraRotation,
  required v.Vector3 targetPosition,
  required double yawTolerance,
  required double pitchTolerance,
}) {
  final toTarget = targetPosition - cameraPosition;
  final localDir = cameraRotation.conjugated().rotated(toTarget);
  final length = localDir.length;
  if (length == 0) {
    return const AlignmentReading(yawDeg: 0, pitchDeg: 0, aligned: false);
  }
  final yawDeg = wrapAngleDeg(
    math.atan2(localDir.x, -localDir.z) * 180 / math.pi,
  );
  final cosine = (localDir.y / length).clamp(-1.0, 1.0);
  final pitchDeg = wrapAngleDeg(math.asin(cosine) * 180 / math.pi);
  return AlignmentReading(
    yawDeg: yawDeg,
    pitchDeg: pitchDeg,
    aligned: yawDeg.abs() <= yawTolerance && pitchDeg.abs() <= pitchTolerance,
  );
}
