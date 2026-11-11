import 'dart:math' as math;

/// Device orientation reduced to the three angles the capture rig needs.
///
/// Pure Dart — no camera, sensor or Flutter imports — so the fusion that turns
/// raw accelerometer/magnetometer samples into a camera direction can be
/// unit-tested on the host.
class DevicePose {
  const DevicePose({
    required this.headingDeg,
    required this.pitchDeg,
    required this.rollDeg,
  });

  /// Compass bearing the back camera points at, 0–360 (0 = magnetic north).
  /// Undefined when the camera points straight up or down; the rig accepts any
  /// yaw for those two targets.
  final double headingDeg;

  /// Camera elevation: +90 = straight up (ZENITH), 0 = horizon, -90 = straight
  /// down (NADIR).
  final double pitchDeg;

  /// Horizon tilt, -180..180. 0 = upright portrait.
  final double rollDeg;
}

abstract final class DevicePoseMath {
  static const double _radToDeg = 180 / math.pi;

  static double wrap360(double deg) => ((deg % 360) + 360) % 360;

  static double wrap180(double deg) {
    final wrapped = wrap360(deg);
    return wrapped > 180 ? wrapped - 360 : wrapped;
  }

  /// Exponential low-pass over a 3-axis sample. [alpha] is the weight kept from
  /// the previous filtered value, so higher = smoother but slower to follow.
  static List<double> lowPass(
    List<double>? previous,
    List<double> sample, {
    double alpha = 0.8,
  }) {
    if (previous == null || previous.length != sample.length) {
      return List<double>.from(sample);
    }
    return [
      for (var i = 0; i < sample.length; i++)
        previous[i] * alpha + sample[i] * (1 - alpha),
    ];
  }

  /// Fuses gravity (accelerometer, m/s²) with the geomagnetic field (µT) into a
  /// camera pose using Android's canonical rotation matrix: H = E × A points
  /// east, M = A × H points magnetic north, A points up.
  ///
  /// The back camera looks along the device's -Z axis, so its world direction
  /// is (-Hz, -Mz, -Az). Elevation is therefore `asin(-Az)` — Android's own
  /// `asin(-Ay)` orientation pitch is the *device* tilt and would report 90°
  /// for a phone held upright taking a horizontal photo.
  ///
  /// Returns null when the vectors are degenerate (free fall, or the field
  /// parallel to gravity): a bearing derived from those is noise, not a pose.
  static DevicePose? fuse({
    required List<double> accel,
    required List<double> mag,
  }) {
    if (accel.length != 3 || mag.length != 3) return null;
    final an = math.sqrt(accel[0] * accel[0] + accel[1] * accel[1] + accel[2] * accel[2]);
    if (an < 1e-6) return null;
    final ax = accel[0] / an, ay = accel[1] / an, az = accel[2] / an;

    var hx = mag[1] * az - mag[2] * ay;
    var hy = mag[2] * ax - mag[0] * az;
    var hz = mag[0] * ay - mag[1] * ax;
    final hn = math.sqrt(hx * hx + hy * hy + hz * hz);
    if (hn < 1e-6) return null;
    hx /= hn;
    hy /= hn;
    hz /= hn;

    var mx = ay * hz - az * hy;
    var my = az * hx - ax * hz;
    var mz = ax * hy - ay * hx;
    final mn = math.sqrt(mx * mx + my * my + mz * mz);
    if (mn < 1e-6) return null;
    mx /= mn;
    my /= mn;
    mz /= mn;

    return DevicePose(
      headingDeg: wrap360(math.atan2(-hz, -mz) * _radToDeg),
      pitchDeg: math.asin((-az).clamp(-1.0, 1.0)) * _radToDeg,
      rollDeg: wrap180(math.atan2(ax, ay) * _radToDeg),
    );
  }
}