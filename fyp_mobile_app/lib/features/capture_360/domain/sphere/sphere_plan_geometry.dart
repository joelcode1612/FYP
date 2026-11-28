import 'dart:math' as math;

import 'package:fyp/features/capture_360/domain/sphere/adaptive_sphere_plan.dart';
import 'package:fyp/features/capture_360/domain/sphere/sphere_target.dart';
import 'package:fyp/features/capture_360/domain/virtual_tour/math/vectors.dart';

/// Version-neutral rows and geometry operations shared by capture plans.
/// One capture direction.
class PlanTarget {
  const PlanTarget(this.targetId, this.ringKey, this.yawDeg, this.pitchDeg);

  final int targetId;
  final String ringKey;
  final double yawDeg;
  final double pitchDeg;

  Map<String, Object?> toJson() => <String, Object?>{
    'targetId': targetId,
    'yawDeg': yawDeg,
    'pitchDeg': pitchDeg,
    'ring': ringKey,
  };
}

const List<String> kPlanRingOrder = <String>[
  'middle',
  'upper',
  'lower',
  'ceiling',
  'floor',
  'upper_polar',
  'lower_polar',
];
String planRingName(String key) => switch (key) {
  'middle' => 'Middle ring',
  'upper' => 'Upper ring',
  'lower' => 'Lower ring',
  'ceiling' => 'Ceiling ring',
  'floor' => 'Floor ring',
  'upper_polar' => 'Upper polar ring',
  'lower_polar' => 'Lower polar ring',
  _ => 'Ring',
};
String planStageTitle(String key) => planRingName(key);

/// One validated capture transition.
///
/// `x`/`y` are the previous target's position in the active target's camera
/// frame as a fraction of the half-frame: `+x` screen-right, `+y` screen-up.
/// `1.0` is the frame edge, so [isVisible] is the requirement itself rather
/// than a proxy for it.
class PlanTransition {
  const PlanTransition({
    required this.previousId,
    required this.currentId,
    required this.separationDeg,
    required this.x,
    required this.y,
    required this.imageOverlap,
  });

  final int previousId;
  final int currentId;

  /// Spherical (great-circle) angle between the two directions.
  final double separationDeg;

  final double x;
  final double y;

  /// Fraction of the previous photograph that also lies inside the current
  /// one, measured by projecting a sample grid through both frames.
  final double imageOverlap;

  /// Whether the previous target is inside the frame.
  bool get isVisible => x.abs() <= 1.0 && y.abs() <= 1.0;

  /// The larger of the two half-frame fractions — what the margin is measured
  /// against.
  double get worstFraction => math.max(x.abs(), y.abs());

  Map<String, Object?> toJson() => <String, Object?>{
    'previousId': previousId,
    'currentId': currentId,
    'separationDeg': separationDeg,
    'x': x,
    'y': y,
    'visible': isVisible,
    'imageOverlap': imageOverlap,
  };
}

/// Camera basis for a direction: `+x` screen-right, `+y` screen-up.
({Vec3 forward, Vec3 right, Vec3 up}) _planBasis(
  double yawDeg,
  double pitchDeg,
) {
  final forward = sphereDirection(yawDeg, pitchDeg);
  var right = forward.cross(const Vec3(0, 1, 0));
  if (right.length < 1e-6) right = const Vec3(1, 0, 0);
  right = right.normalized;
  return (forward: forward, right: right, up: right.cross(forward));
}

/// Fraction of the previous frame that also falls inside the current frame.
///
/// Sampled rather than assumed: two rectangles on a sphere do not overlap by
/// the yaw/pitch difference, and the whole point of the plan is that the
/// overlap is real. 24 × 24 samples are enough for a percentage that is
/// reported to one decimal.
double _planImageOverlap(
  double previousYaw,
  double previousPitch,
  double currentYaw,
  double currentPitch,
  SphereCameraProfile camera, {
  int samples = 24,
}) {
  final a = _planBasis(previousYaw, previousPitch);
  final b = _planBasis(currentYaw, currentPitch);
  var inside = 0;
  for (var iy = 0; iy < samples; iy++) {
    final ty = (iy + 0.5) / samples * 2 - 1;
    for (var ix = 0; ix < samples; ix++) {
      final tx = (ix + 0.5) / samples * 2 - 1;
      final direction = Vec3(
        a.forward.x +
            a.right.x * tx * camera.halfWidthRatio +
            a.up.x * ty * camera.halfHeightRatio,
        a.forward.y +
            a.right.y * tx * camera.halfWidthRatio +
            a.up.y * ty * camera.halfHeightRatio,
        a.forward.z +
            a.right.z * tx * camera.halfWidthRatio +
            a.up.z * ty * camera.halfHeightRatio,
      );
      final depth = direction.dot(b.forward);
      if (depth <= 1e-9) continue;
      if ((direction.dot(b.right) / depth).abs() > camera.halfWidthRatio) {
        continue;
      }
      if ((direction.dot(b.up) / depth).abs() > camera.halfHeightRatio) {
        continue;
      }
      inside++;
    }
  }
  return inside / (samples * samples);
}

/// Every consecutive transition of [table], validated against [camera].
///
/// This is the check the layout exists for. It uses the same perspective
/// projection as the live overlay, not a comparison of yaw/pitch differences,
/// which are foreshortened differently at every row.
List<PlanTransition> planTransitions(
  SphereCameraProfile camera, {
  required List<PlanTarget> table,
}) {
  final out = <PlanTransition>[];
  for (var i = 1; i < table.length; i++) {
    final previous = table[i - 1];
    final current = table[i];
    final a = _planBasis(previous.yawDeg, previous.pitchDeg);
    final b = _planBasis(current.yawDeg, current.pitchDeg);
    final depth = a.forward.dot(b.forward);
    final separation =
        math.acos(a.forward.dot(b.forward).clamp(-1.0, 1.0)) * 180 / math.pi;
    out.add(
      PlanTransition(
        previousId: previous.targetId,
        currentId: current.targetId,
        separationDeg: separation,
        x: depth <= 1e-9
            ? double.infinity
            : a.forward.dot(b.right) / depth / camera.halfWidthRatio,
        y: depth <= 1e-9
            ? double.infinity
            : a.forward.dot(b.up) / depth / camera.halfHeightRatio,
        imageOverlap: _planImageOverlap(
          previous.yawDeg,
          previous.pitchDeg,
          current.yawDeg,
          current.pitchDeg,
          camera,
        ),
      ),
    );
  }
  return out;
}

/// Summary of [planTransitions].
({double worstFraction, List<int> failures, double minimumOverlap}) planAudit(
  SphereCameraProfile camera, {
  required List<PlanTarget> table,
}) {
  final transitions = planTransitions(camera, table: table);
  var worst = 0.0;
  var minimumOverlap = 1.0;
  final failures = <int>[];
  for (final transition in transitions) {
    if (transition.worstFraction > worst) worst = transition.worstFraction;
    if (transition.imageOverlap < minimumOverlap) {
      minimumOverlap = transition.imageOverlap;
    }
    if (!transition.isVisible) failures.add(transition.currentId);
  }
  return (
    worstFraction: worst,
    failures: failures,
    minimumOverlap: transitions.isEmpty ? 0 : minimumOverlap,
  );
}

/// The ring specs for [table], in stage order.
///
/// Public because the plan builders are version-neutral: plan 10 reuses this
/// and [planTargetsFor] with its own table instead of a second copy of the
/// conversion from a table row to a capture target.
List<PlanRingSpec> planRingsFor(List<PlanTarget> table) => <PlanRingSpec>[
  for (final key in kPlanRingOrder)
    if (table.any((target) => target.ringKey == key))
      PlanRingSpec(
        key: key,
        title: planStageTitle(key),
        pitchDeg: table.firstWhere((target) => target.ringKey == key).pitchDeg,
        yaws: List<double>.unmodifiable(<double>[
          for (final target in table)
            if (target.ringKey == key) target.yawDeg,
        ]),
      ),
];

/// The capture targets for [table], in capture order.
List<SphereTargetSpec> planTargetsFor(List<PlanTarget> table) {
  final indexInRing = <String, int>{};
  final targets = <SphereTargetSpec>[];
  for (final target in table) {
    final next = (indexInRing[target.ringKey] ?? 0) + 1;
    indexInRing[target.ringKey] = next;
    targets.add(
      SphereTargetSpec(
        targetId: target.targetId,
        yawDeg: target.yawDeg,
        pitchDeg: target.pitchDeg,
        ringName: planRingName(target.ringKey),
        indexInRing: next,
        direction: sphereDirection(target.yawDeg, target.pitchDeg),
      ),
    );
  }
  return List<SphereTargetSpec>.unmodifiable(targets);
}
