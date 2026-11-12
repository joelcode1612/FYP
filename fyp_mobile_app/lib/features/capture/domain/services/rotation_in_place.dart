import 'dart:math' as math;

import 'package:fyp/core/math/vio_sphere_math.dart' as vio;

/// The result of comparing one camera pose with the frozen capture station.
class RotationInPlaceAssessment {
  const RotationInPlaceAssessment({
    required this.rawDriftM,
    required this.effectiveDriftM,
    required this.rotatingInPlace,
    required this.withinAllowance,
    this.driftReference,
    this.rotationRadiusM,
  });

  /// TRUE 3-D distance from the camera to the frozen station origin.
  ///
  /// Never filtered or compensated: this is the physical measurement the
  /// diagnostics display and log.
  final double rawDriftM;

  /// The distance the capture gate applies. Equals [rawDriftM] unless a
  /// verified in-place rotation supplies a [driftReference].
  final double effectiveDriftM;

  /// Whether the pose belongs to a verified rotation about a stable centre.
  final bool rotatingInPlace;

  /// Whether [rawDriftM] is inside the rotation allowance (hard cap).
  final bool withinAllowance;

  /// Point on the established rotation arc the camera should currently occupy.
  ///
  /// `null` when no rotation has been verified, in which case the strict
  /// frozen-origin gate applies.
  final vio.Vec3? driftReference;

  /// The frozen radius of the established arc, when known.
  final double? rotationRadiusM;

  bool get compensationActive => rotatingInPlace && driftReference != null;
}

class _Sample {
  const _Sample(this.at, this.radiusM, this.yawDeg);

  final DateTime at;
  final double radiusM;
  final double yawDeg;
}

/// Distinguishes "turning around in place" from "walking away".
///
/// The 26 targets are world-locked positions around the position the phone had
/// at calibration. The original 0.20 m gate therefore treats a perfectly valid
/// body-spin as a station abandonment: the camera traces an arc 0.3–0.6 m from
/// where calibration happened, and every frame is refused with the amber
/// "too far from station" ring.
///
/// A rotation about a stable centre has a signature that a walk-away does not:
/// the yaw sweeps while the *radius* from the station stays constant. This
/// monitor waits for that signature over a short window, freezes the radius,
/// and then measures drift as the deviation from that arc rather than from the
/// calibration point. The frozen arc is a measurement, not a target rewrite —
/// the station origin, its orientation and all 26 world anchors are untouched,
/// and alignment still uses the live camera → anchor direction.
///
/// Safety properties, deliberately conservative:
/// * no compensation before a yaw sweep AND a stable radius are both observed;
/// * the radius is frozen once, so a slow walk-away cannot ratchet it upward;
/// * a hard cap on the raw distance cannot be compensated away;
/// * radial deviation beyond tolerance drops straight back to the raw gate;
/// * a tracking break or recalibration calls [reset]/[invalidate].
class RotationInPlaceMonitor {
  RotationInPlaceMonitor({
    required this.stationOrigin,
    this.maxRotationRadiusM = 0.75,
    this.radialToleranceM = 0.10,
    this.minYawSweepDeg = 30,
    this.window = const Duration(milliseconds: 1400),
    this.minSamples = 8,
    this.maxRadiusSpreadM = 0.06,
  });

  /// The frozen station origin (calibration camera position). Immutable: the
  /// 26 anchors were built around it and must never be recomputed.
  final vio.Vec3 stationOrigin;

  /// Hard cap on the raw distance. Beyond this, no compensation is allowed —
  /// the phone has left the capture volume, not merely rotated within it.
  final double maxRotationRadiusM;

  /// How far the current radius may depart from the frozen arc before the
  /// compensation is withdrawn.
  final double radialToleranceM;

  /// Yaw sweep required before an arc may be established.
  final double minYawSweepDeg;

  /// Length of the observation window.
  final Duration window;

  /// Minimum number of poses in the window.
  final int minSamples;

  /// Maximum radius spread tolerated while establishing the arc.
  final double maxRadiusSpreadM;

  final List<_Sample> _samples = <_Sample>[];
  double? _rotationRadiusM;

  double? get rotationRadiusM => _rotationRadiusM;

  /// Clears everything and permits a fresh arc to be established.
  void reset() {
    _samples.clear();
    _rotationRadiusM = null;
  }

  /// Withdraws a previously established arc without clearing the window.
  ///
  /// Used after a tracking break: ARCore may rebase its world origin, so an arc
  /// measured in the old coordinate frame must not be trusted. The controller
  /// already requires recalibration in that case.
  void invalidate() {
    _rotationRadiusM = null;
    _samples.clear();
  }

  RotationInPlaceAssessment observe({
    required vio.Vec3 position,
    required double yawDeg,
    required DateTime at,
  }) {
    final displacement = position - stationOrigin;
    final rawDriftM = displacement.length;
    _samples.add(_Sample(at, rawDriftM, yawDeg));
    while (_samples.isNotEmpty &&
        at.difference(_samples.first.at) > window) {
      _samples.removeAt(0);
    }

    if (_rotationRadiusM == null) _tryEstablish();

    final radius = _rotationRadiusM;
    final withinAllowance = rawDriftM <= maxRotationRadiusM;
    final deviation = radius == null ? rawDriftM : (rawDriftM - radius).abs();
    final active =
        radius != null && withinAllowance && deviation <= radialToleranceM;

    if (!active) {
      return RotationInPlaceAssessment(
        rawDriftM: rawDriftM,
        effectiveDriftM: rawDriftM,
        rotatingInPlace: false,
        withinAllowance: withinAllowance,
        rotationRadiusM: radius,
      );
    }

    // The expected point on the frozen arc in the direction the camera
    // currently occupies. Distance to it is the radial deviation only; a
    // change of yaw at constant radius contributes nothing.
    final direction = displacement.normalized;
    final reference = radius < 1e-4
        ? stationOrigin
        : stationOrigin + direction * radius;
    return RotationInPlaceAssessment(
      rawDriftM: rawDriftM,
      effectiveDriftM: (position - reference).length,
      rotatingInPlace: true,
      withinAllowance: withinAllowance,
      driftReference: reference,
      rotationRadiusM: radius,
    );
  }

  void _tryEstablish() {
    if (_samples.length < minSamples) return;
    if (_samples.last.at.difference(_samples.first.at) <
        Duration(milliseconds: window.inMilliseconds ~/ 2)) {
      return;
    }

    final sweep = _yawSweep();
    if (sweep < minYawSweepDeg) return;

    final radii = <double>[for (final s in _samples) s.radiusM]..sort();
    final spread = radii.last - radii.first;
    if (spread > maxRadiusSpreadM) return;
    if (radii.last > maxRotationRadiusM) return;

    // Median, frozen once: a later walk-away increases the spread or the
    // deviation and therefore drops the compensation, it never re-fits.
    _rotationRadiusM = radii[radii.length ~/ 2];
  }

  /// Wrapped yaw sweep across the window, in degrees.
  double _yawSweep() {
    var total = 0.0;
    for (var i = 1; i < _samples.length; i++) {
      var delta = _samples[i].yawDeg - _samples[i - 1].yawDeg;
      while (delta > 180) {
        delta -= 360;
      }
      while (delta < -180) {
        delta += 360;
      }
      total += delta.abs();
    }
    return math.min(total, 360);
  }
}
