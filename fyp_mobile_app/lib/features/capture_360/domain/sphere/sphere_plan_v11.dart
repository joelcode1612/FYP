import 'package:fyp/features/capture_360/domain/sphere/adaptive_sphere_plan.dart';
import 'package:fyp/features/capture_360/domain/sphere/sphere_plan_geometry.dart';

// Plan 11 — the enhanced adaptive 44-target layout.
//
// ## What it restores
//
// Plan 4 is the original adaptive 44-target five-ring layout: 4 upper polar,
// 12 upper, 12 middle, 12 lower, 4 lower polar, with every ring sharing the
// same yaw positions. Plan 11 keeps that count, the ring pitches, the
// adaptive nearest-target guidance and the same cap yaws; it changes only
// what the independent 44-photograph analysis showed to be broken.
//
// ## Why the caps moved
//
// Plan 4 put the four ceiling targets at +65° directly above middle targets.
// At the documented 51.08° × 65° frame, the nearest upper target was then
// 30° of yaw and 35° of pitch away, projecting to 1.18 of the half-frame —
// outside the photograph. The ceiling frames therefore shared no visible
// neighbour with the ring beneath them, which is the mechanical reason the
// independent audit found 0 of 4 ceiling photographs registered.
//
// Plan 11 places each cap between two upper targets instead of above one:
//
//     M330 → U345 → C0 → U15 → M30
//
// so the cap is reached from a photograph that already contains the
// wall-to-ceiling boundary, and left towards another. The pitch drops from 65°
// to 60° because the *exit* transition is the binding one: at 62° the cap →
// upper step projects to 1.012 of the half-frame (outside), at 61° to 0.976
// (0.8° of margin, inside the 2.0° alignment cone), and at 60° to 0.938
// (2.0° of margin). 60° is the largest cap pitch that satisfies the
// previous-target requirement in both directions, so it is the one shipped.
// The cap still covers the pole: 60° + 32.5° of half-height = 92.5°.
//
// Floors are placed the same way, between two lower targets. Their yaw offset
// is 30° rather than the ceiling's 0° so that a floor arch and a ceiling arch
// never claim the same middle-ring step.
//
// ## The four transitions that cannot be visible
//
// A Hamiltonian path over this geometry cannot keep the previous target in
// frame on every step. Counting the edges such a path must spend:
//
//     e(M-U) + e(M-L) = 2 × 12          middle-ring slots
//     e(M-U) = 2 × 12 − 2 × 4           upper slots consumed by ceiling caps
//     e(M-L) = 2 × 12 − 2 × 4           lower slots consumed by floor caps
//
// 32 edges are demanded from 24 slots. Four upper→lower steps therefore fall
// outside the frame, and no reordering removes them: they are the price of
// 4 + 4 caps on 12-target rings at this field of view. Plan 11 keeps 44
// photographs, names those four transitions in
// [kSpherePlanV11PreviousVisibilityExempt], and the controller exempts exactly
// those four from the readiness gate instead of blocking capture forever.
//
// Every other transition is inside the frame, with a worst case of 0.938 of
// the half-frame (2.0° of margin at the 65° vertical field of view).

/// Plan version of the enhanced adaptive 44-target layout.
const int kSpherePlanV11Version = 11;

/// Target count. Fixed: this plan never densifies.
const int kSpherePlanV11TargetCount = 44;

/// Pitch of the upper and lower rings.
const double kSpherePlanV11RingPitchDeg = 30;

/// Pitch of the ceiling and floor rings.
///
/// 60°, not 62°: see the file header. At 62° the cap → upper exit projects to
/// 1.012 of the half-frame and the photograph just taken leaves the picture.
const double kSpherePlanV11PolarPitchDeg = 60;

/// Yaw offset between the middle ring and the upper/lower rings.
const double kSpherePlanV11StaggerDeg = 15;

/// Yaw offset of the ceiling caps from the middle ring.
const double kSpherePlanV11CeilingOffsetDeg = 0;

/// Yaw offset of the floor caps from the middle ring.
///
/// Zero: a floor cap sits at the middle yaw of its own arch (30°, 120°, 210°,
/// 300°), which is 15° from each of the two lower targets that flank it. The
/// 30° separation from a ceiling cap comes from the arches occupying different
/// middle-ring steps, not from a second offset.
const double kSpherePlanV11FloorOffsetDeg = 0;

/// The row type is shared with plan 9: the tables differ, the record does not.
typedef PlanV11Target = PlanTarget;

/// The canonical table, in capture order.
///
/// Target ids are the keys frames and matches are recorded against, so this
/// order is the contract: a generator that reordered a block would invalidate
/// every stored match row for a session captured with it.
const List<PlanV11Target> kSpherePlanV11Table = <PlanV11Target>[
  // 0°: the first photograph is horizon-level, then the ceiling arch.
  PlanV11Target(1, 'middle', 0, 0),
  PlanV11Target(2, 'upper', 345, 30),
  PlanV11Target(3, 'ceiling', 0, 60),
  PlanV11Target(4, 'upper', 15, 30),
  // 30°: floor arch, then the next upper.
  PlanV11Target(5, 'middle', 30, 0),
  PlanV11Target(6, 'lower', 15, -30),
  PlanV11Target(7, 'floor', 30, -60),
  PlanV11Target(8, 'lower', 45, -30),
  // 60°: up.
  PlanV11Target(9, 'middle', 60, 0),
  PlanV11Target(10, 'upper', 45, 30),
  PlanV11Target(11, 'lower', 75, -30),
  // 90°: ceiling arch.
  PlanV11Target(12, 'middle', 90, 0),
  PlanV11Target(13, 'upper', 75, 30),
  PlanV11Target(14, 'ceiling', 90, 60),
  PlanV11Target(15, 'upper', 105, 30),
  // 120°: floor arch.
  PlanV11Target(16, 'middle', 120, 0),
  PlanV11Target(17, 'lower', 105, -30),
  PlanV11Target(18, 'floor', 120, -60),
  PlanV11Target(19, 'lower', 135, -30),
  // 150°: up.
  PlanV11Target(20, 'middle', 150, 0),
  PlanV11Target(21, 'upper', 135, 30),
  PlanV11Target(22, 'lower', 165, -30),
  // 180°: ceiling arch.
  PlanV11Target(23, 'middle', 180, 0),
  PlanV11Target(24, 'upper', 165, 30),
  PlanV11Target(25, 'ceiling', 180, 60),
  PlanV11Target(26, 'upper', 195, 30),
  // 210°: floor arch.
  PlanV11Target(27, 'middle', 210, 0),
  PlanV11Target(28, 'lower', 195, -30),
  PlanV11Target(29, 'floor', 210, -60),
  PlanV11Target(30, 'lower', 225, -30),
  // 240°: up.
  PlanV11Target(31, 'middle', 240, 0),
  PlanV11Target(32, 'upper', 225, 30),
  PlanV11Target(33, 'lower', 255, -30),
  // 270°: ceiling arch.
  PlanV11Target(34, 'middle', 270, 0),
  PlanV11Target(35, 'upper', 255, 30),
  PlanV11Target(36, 'ceiling', 270, 60),
  PlanV11Target(37, 'upper', 285, 30),
  // 300°: floor arch and the closing middle targets.
  PlanV11Target(38, 'middle', 300, 0),
  PlanV11Target(39, 'lower', 285, -30),
  PlanV11Target(40, 'floor', 300, -60),
  PlanV11Target(41, 'lower', 315, -30),
  PlanV11Target(42, 'middle', 330, 0),
  PlanV11Target(43, 'upper', 315, 30),
  PlanV11Target(44, 'lower', 345, -30),
];

/// The four transitions whose previous target necessarily falls outside the
/// frame, derived from the edge count in the file header.
///
/// The controller consults this through
/// [AdaptiveSpherePlan.previousVisibilityExempt], so the exemption is read from
/// the plan rather than hard-coded in the readiness gate.
const Set<int> kSpherePlanV11PreviousVisibilityExempt = <int>{11, 22, 33, 44};

/// Every consecutive transition of [table], projected into the active target's
/// camera frame.
List<PlanTransition> planV11Transitions(
  SphereCameraProfile camera, {
  List<PlanV11Target> table = kSpherePlanV11Table,
}) => planTransitions(camera, table: table);

/// Summary of [planV11Transitions].
({double worstFraction, List<int> failures, double minimumOverlap})
planV11Audit(
  SphereCameraProfile camera, {
  List<PlanV11Target> table = kSpherePlanV11Table,
}) => planAudit(camera, table: table);

/// Builds the 44-target plan for [profile].
///
/// The count is **fixed**. A lens that cannot keep the previous target in
/// frame does not get more photographs: the conflict is recorded in
/// [AdaptiveSpherePlan.notes] with the exact transition and fraction, so it is
/// reported rather than hidden.
AdaptiveSpherePlan buildPlanV11({
  SphereCameraProfile? profile,
  PlanConstraints constraints = const PlanConstraints(),
}) {
  final camera = profile ?? SphereCameraProfile.assumed();
  final rings = planRingsFor(kSpherePlanV11Table);
  final metrics = evaluateRings(
    rings,
    camera,
    minimumOverlap: constraints.minimumOverlap,
  );
  final notes = <String>[];
  final exempt = <int>{};
  for (final transition in planV11Transitions(camera)) {
    if (!transition.isVisible) exempt.add(transition.currentId);
  }
  if (exempt.isNotEmpty) {
    notes.add(
      'At this lens ${exempt.length} of 43 transitions cannot keep the '
      'previous photograph in frame: targets ${exempt.join(", ")}. They are '
      'the upper→lower steps the 4+4 cap layout forces; the plan keeps 44 '
      'photographs and exempts exactly those steps from the shutter gate.',
    );
  }
  if (!metrics.satisfies(constraints)) {
    notes.add(
      'Coverage check at this lens: single '
      '${(metrics.singleCoverage * 100).toStringAsFixed(1)}%, double '
      '${(metrics.doubleCoverage * 100).toStringAsFixed(1)}%, minimum '
      'neighbour overlap '
      '${(metrics.minimumNeighbourOverlap * 100).toStringAsFixed(1)}%.',
    );
  }
  return AdaptiveSpherePlan(
    planVersion: kSpherePlanV11Version,
    camera: camera,
    rings: List<PlanRingSpec>.unmodifiable(rings),
    targets: planTargetsFor(kSpherePlanV11Table),
    captureOrder: List<int>.unmodifiable(<int>[
      for (final target in kSpherePlanV11Table) target.targetId,
    ]),
    metrics: metrics,
    constraints: constraints,
    notes: List<String>.unmodifiable(notes),
    previousVisibilityExempt: Set<int>.unmodifiable(exempt),
  );
}

/// The plan for the documented device camera, evaluated once.
final AdaptiveSpherePlan kSpherePlanV11 = buildPlanV11();

/// The plan for a calibrated camera, or the canonical plan when the platform
/// did not report intrinsics.
AdaptiveSpherePlan planV11For(SphereCameraProfile? profile) =>
    profile == null || !profile.isCalibrated
    ? kSpherePlanV11
    : buildPlanV11(profile: profile);
