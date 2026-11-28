import 'package:fyp/features/capture_360/domain/sphere/adaptive_sphere_plan.dart';
import 'package:fyp/features/capture_360/domain/sphere/sphere_plan_geometry.dart';

// Plan 12 — the canonical adaptive five-ring capture plan.
//
// ## What this plan is
//
// One production capture plan for every new SiteWise session. It replaces the
// capture-mode selection that used to offer V4, V11 and the retired fixed
// layouts: a new session is always created under plan 12, and historical
// sessions keep the plan version saved with them.
//
// ## The five rings (the reference configuration)
//
// | Ring        | Pitch | Yaw spacing | Targets |
// |-------------|-------|-------------|---------|
// | Upper polar | +65°  | 90°         | 4       |
// | Upper       | +30°  | 30°         | 12      |
// | Middle      | 0°    | 30°         | 12      |
// | Lower       | −30°  | 30°         | 12      |
// | Lower polar | −65°  | 90°         | 4       |
//
// The three main rings share the same yaw positions (0°, 30°, …, 330°) and the
// polar rings sit directly above and below ring targets at 0°, 90°, 180° and
// 270°. 36 primary targets cover the surrounding scene; the 8 polar targets
// extend coverage towards the ceiling and the floor.
//
// ## Identity and sequence
//
// Target ids ARE the capture order: id 1 is the first photograph, id 44 the
// last. The sequence is the connected-sector order — two neighbouring middle
// frames first, then their upper and lower counterparts and the first polar
// pair, then sector by sector (middle → upper → polar → lower → polar) — so
// horizontal and vertical image connections exist before the photographer has
// turned a quarter of the way round, and no guided step swings the camera
// further than the sector requires.
//
// ## What completing the plan does and does not prove
//
// Capturing all 44 photographs satisfies the plan's geometry, but it does not
// by itself prove full spherical coverage: overlap is verified against real
// image content by the backend matcher, and the coverage report comes from the
// worker, never from a photograph count. The polar rings leave the zenith and
// nadir to the polar frames' upper edges; when a room's measured lens cannot
// bridge that band, coverage verification reports the hole and a manual
// zenith/nadir supplement is offered rather than a false "complete".
//
// ## The transitions without a visible predecessor
//
// At the documented 51.08° × 65° frame, entering a polar target from the ring
// frame beneath it (35° of pitch) and crossing directly from an upper frame to
// a lower frame inside a capped sector (60° of pitch) leave the previous
// target's centre outside the photograph. These steps are computed by
// [planV12Transitions] and published through
// [AdaptiveSpherePlan.previousVisibilityExempt]; the capture guidance reports
// them instead of pretending every step keeps the predecessor in frame. They
// are transitions, not coverage gaps: each polar frame still shares a wide
// content band with the ring frame at its own yaw, and each upper→lower step
// is bridged by the frames already on the sphere.

/// Plan version of the canonical adaptive five-ring capture plan.
const int kSpherePlanV12Version = 12;

/// Target count. Fixed: 36 primary + 8 polar.
const int kSpherePlanV12TargetCount = 44;

/// Pitch of the upper and lower rings.
const double kSpherePlanV12RingPitchDeg = 30;

/// Pitch of the upper and lower polar rings.
const double kSpherePlanV12PolarPitchDeg = 65;

/// Yaw positions of the three main rings.
const List<double> kSpherePlanV12RingYaws = <double>[
  0, 30, 60, 90, 120, 150, 180, 210, 240, 270, 300, 330,
];

/// Yaw positions of the upper and lower polar rings.
const List<double> kSpherePlanV12PolarYaws = <double>[0, 90, 180, 270];

/// The row type is shared with the other plan tables.
typedef PlanV12Target = PlanTarget;

/// The canonical table, in capture order: target id equals capture position.
///
/// This order is the contract between the mobile guidance, the persisted plan
/// payload, frame registration and the backend matcher. The connected-sector
/// reference order is exactly 1…44.
const List<PlanV12Target> kSpherePlanV12Table = <PlanV12Target>[
  // Seed sector: two neighbouring middle frames, their upper and lower
  // counterparts, and the first polar pair — horizontal and vertical
  // alignment exist before the photographer turns away from the start.
  PlanV12Target(1, 'middle', 0, 0),
  PlanV12Target(2, 'middle', 30, 0),
  PlanV12Target(3, 'upper', 0, 30),
  PlanV12Target(4, 'upper', 30, 30),
  PlanV12Target(5, 'upper_polar', 0, 65),
  PlanV12Target(6, 'lower', 0, -30),
  PlanV12Target(7, 'lower', 30, -30),
  PlanV12Target(8, 'lower_polar', 0, -65),
  // Sector 60°.
  PlanV12Target(9, 'middle', 60, 0),
  PlanV12Target(10, 'upper', 60, 30),
  PlanV12Target(11, 'lower', 60, -30),
  // Sector 90°: carries the second polar pair.
  PlanV12Target(12, 'middle', 90, 0),
  PlanV12Target(13, 'upper', 90, 30),
  PlanV12Target(14, 'upper_polar', 90, 65),
  PlanV12Target(15, 'lower', 90, -30),
  PlanV12Target(16, 'lower_polar', 90, -65),
  // Sector 120°.
  PlanV12Target(17, 'middle', 120, 0),
  PlanV12Target(18, 'upper', 120, 30),
  PlanV12Target(19, 'lower', 120, -30),
  // Sector 150°.
  PlanV12Target(20, 'middle', 150, 0),
  PlanV12Target(21, 'upper', 150, 30),
  PlanV12Target(22, 'lower', 150, -30),
  // Sector 180°: third polar pair.
  PlanV12Target(23, 'middle', 180, 0),
  PlanV12Target(24, 'upper', 180, 30),
  PlanV12Target(25, 'upper_polar', 180, 65),
  PlanV12Target(26, 'lower', 180, -30),
  PlanV12Target(27, 'lower_polar', 180, -65),
  // Sector 210°.
  PlanV12Target(28, 'middle', 210, 0),
  PlanV12Target(29, 'upper', 210, 30),
  PlanV12Target(30, 'lower', 210, -30),
  // Sector 240°.
  PlanV12Target(31, 'middle', 240, 0),
  PlanV12Target(32, 'upper', 240, 30),
  PlanV12Target(33, 'lower', 240, -30),
  // Sector 270°: last polar pair.
  PlanV12Target(34, 'middle', 270, 0),
  PlanV12Target(35, 'upper', 270, 30),
  PlanV12Target(36, 'upper_polar', 270, 65),
  PlanV12Target(37, 'lower', 270, -30),
  PlanV12Target(38, 'lower_polar', 270, -65),
  // Sector 300°.
  PlanV12Target(39, 'middle', 300, 0),
  PlanV12Target(40, 'upper', 300, 30),
  PlanV12Target(41, 'lower', 300, -30),
  // Sector 330°: the loop closes back onto target 1.
  PlanV12Target(42, 'middle', 330, 0),
  PlanV12Target(43, 'upper', 330, 30),
  PlanV12Target(44, 'lower', 330, -30),
];

/// Every consecutive transition of the canonical table, projected into the
/// active target's camera frame.
List<PlanTransition> planV12Transitions(
  SphereCameraProfile camera, {
  List<PlanV12Target> table = kSpherePlanV12Table,
}) => planTransitions(camera, table: table);

/// Summary of [planV12Transitions].
({double worstFraction, List<int> failures, double minimumOverlap})
planV12Audit(
  SphereCameraProfile camera, {
  List<PlanV12Target> table = kSpherePlanV12Table,
}) => planAudit(camera, table: table);

/// Builds the canonical plan for [profile].
///
/// The count is fixed at 44. The transition audit runs against the actual
/// profile so the plan's notes and visibility exemptions describe the lens the
/// device really has, and coverage metrics come from the sampled projection in
/// the shared geometry layer rather than from yaw/pitch differences.
AdaptiveSpherePlan buildPlanV12({
  SphereCameraProfile? profile,
  PlanConstraints constraints = const PlanConstraints(),
}) {
  final camera = profile ?? SphereCameraProfile.assumed();
  final rings = planRingsFor(kSpherePlanV12Table);
  final metrics = evaluateRings(rings, camera);
  final notes = <String>[];
  final exempt = <int>{};
  for (final transition in planV12Transitions(camera)) {
    if (!transition.isVisible) exempt.add(transition.currentId);
  }
  if (exempt.isNotEmpty) {
    notes.add(
      'At this lens ${exempt.length} of ${kSpherePlanV12Table.length - 1} '
      'transitions cannot keep the previous photograph centred in frame: '
      'targets ${exempt.join(", ")}. Each affected frame still shares a wide '
      'content band with the frames already on the sphere; coverage is '
      'verified by the backend matcher, not by this sequence.',
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
    planVersion: kSpherePlanV12Version,
    camera: camera,
    rings: List<PlanRingSpec>.unmodifiable(rings),
    targets: planTargetsFor(kSpherePlanV12Table),
    captureOrder: List<int>.unmodifiable(<int>[
      for (final target in kSpherePlanV12Table) target.targetId,
    ]),
    metrics: metrics,
    constraints: constraints,
    notes: List<String>.unmodifiable(notes),
    previousVisibilityExempt: Set<int>.unmodifiable(exempt),
  );
}

/// The canonical plan for the documented device camera, evaluated once.
final AdaptiveSpherePlan kSpherePlanV12 = buildPlanV12();

/// The plan for a calibrated camera, or the canonical plan when the platform
/// did not report intrinsics.
AdaptiveSpherePlan planV12For(SphereCameraProfile? profile) =>
    profile == null || !profile.isCalibrated
    ? kSpherePlanV12
    : buildPlanV12(profile: profile);
