import 'dart:math' as math;

import 'package:fyp/features/capture_360/domain/sphere/adaptive_sphere_plan.dart';
import 'package:fyp/features/capture_360/domain/sphere/sphere_plan_v11.dart';
import 'package:fyp/features/capture_360/domain/sphere/sphere_plan_v12.dart';
import 'package:fyp/features/capture_360/domain/virtual_tour/math/quaternions.dart';
import 'package:fyp/features/capture_360/domain/virtual_tour/math/scalars.dart';
import 'package:fyp/features/capture_360/domain/virtual_tour/math/vectors.dart';

// Plans 5, 7 and 9 live in their own libraries (their canonical tables are
// long), but every caller reaches plan versions through this file.
// Re-exporting keeps a single import for the plan vocabulary instead of asking
// each screen to know which file a constant is declared in.
export 'package:fyp/features/capture_360/domain/sphere/sphere_plan_v11.dart';
export 'package:fyp/features/capture_360/domain/sphere/sphere_plan_v12.dart';

// The sphere of the 3DoF capture architecture.
//
// ## The one architectural difference from the ARCore flow
//
// These directions are **not** world positions. The sphere's centre is the
// phone, always: there is no SLAM, no plane detection and no anchor, so
// walking to a new spot moves the whole sphere with the phone rather than
// leaving targets behind. Only rotation is tracked, and the rendering applies
// the inverse device quaternion to these vectors — see
// `sphereTargetCameraDirection` in `sphere_projection.dart`.
//
// ## Frame
//
// Every `SphereTargetSpec.direction` is expressed in the **start device
// frame**: `+X` is screen-right, `+Y` is screen-up and `-Z` is the direction
// the rear camera looks. That is the frame the Android rotation vector maps to
// the world, so the same quaternion serves the maths and the native sensor
// with no handedness conversion in between.
//
// The *world* frame those quaternions live in is not this file's business —
// `Quat` is frame-agnostic and `q⁻¹·(q₀·v)` cancels any change of basis. The
// one place the world's up axis does matter is [levelStartFrame], which is why
// it takes the axis as a parameter instead of assuming one. Android reports
// `+Z` up (East–North–Up); this project's own pose helpers use `+Y`. Getting
// those two confused tilts every target by 90°, so the axis is never guessed.
//
// ## Layouts
//
// **Plan 4 (current)** — the adaptive five-ring layout generated in
// `adaptive_sphere_plan.dart`. For the documented 65° vertical field of view
// it is 44 targets: 4 upper polar (+65°), 12 upper (+30°), 12 middle (0°),
// 12 lower (−30°), 4 lower polar (−65°). The three main rings share the same
// yaw positions and the polar rings sit directly above and below middle
// targets, which is what gives the vertical connections their overlap. A
// camera with a different field of view gets a different count and different
// spacing — the layout is measured, not assumed.
//
// **Plan 3** — the retired 56-target experiment (18 per ring). Readable so
// historical sessions keep their geometry, never selected for a new capture.
//
// **Plan 2** — the retired 38-target layout (12 per ring at ±40° plus zenith
// and nadir). Readable for the same reason.
//
// **Plan 1** — the retired ±35° rings. Readable.
//
// Historical sessions persist each frame's intended yaw/pitch, so recovery and
// stitching never depend on the current constant matching the layout the older
// photographs were taken with.

/// The adaptive five-ring plan version (current).
///
/// Declared here rather than in the planner so both libraries can name it
/// without a const-initialisation cycle: the planner imports this file for
/// [SphereTargetSpec], and this file imports the planner for the layout.
const int kAdaptiveSpherePlanVersion = 4;

/// The canonical adaptive five-ring capture plan for every new session.
///
/// Plan 12 carries the reference configuration — 36 primary targets on
/// 0°/±30° rings plus 8 polar targets at ±65° — with target ids equal to the
/// connected-sector capture order. Plans 4 and 11 remain readable for
/// historical sessions; they are never selected for a new capture.
const int kSphereCanonicalPlanVersion = kSpherePlanV12Version;

/// Reference target count of the current capture plan.
///
/// The adaptive five-ring planner starts from the 44-target reference layout
/// (12/12/12 at 0°/±30° plus 4+4 polar targets at ±65°) and may add positions
/// when the measured lens cannot satisfy coverage. V11 is retained read-only
/// for sessions captured with its fixed staggered geometry.
const int kSphereTargetCount = 44;

/// The retired 38-target layout (plan 2), still readable.
const int kSphereLegacyTargetCount = 38;

/// The retired 56-target experiment (plan 3), still readable.
const int kSphereEnhancedTargetCount = 56;
const int kSphereEnhancedPlanVersion = 3;

/// The retired 38-target plan version.
const int kSphereLegacyPlanVersion = 2;

int sphereTargetCountForPlan(int version) {
  if (version == kSpherePlanV12Version) {
    return kSpherePlanV12TargetCount;
  }
  if (version == kSpherePlanV11Version) {
    return kSpherePlanV11TargetCount;
  }
  if (version == kAdaptiveSpherePlanVersion) {
    return kAdaptiveSpherePlan.targetCount;
  }
  if (version == kSphereEnhancedPlanVersion) {
    return kSphereEnhancedTargetCount;
  }
  if (version == 1) {
    return kSphereLegacyTargetCount;
  }
  if (version == kSphereLegacyPlanVersion) {
    return kSphereLegacyTargetCount;
  }
  throw StateError('Unsupported sphere capture plan version: $version');
}

bool planIsBackendStitched(int version) =>
    version == kSpherePlanV12Version ||
    version == kSpherePlanV11Version ||
    version == kAdaptiveSpherePlanVersion;

AdaptiveSpherePlan planForVersion(
  int version, {
  SphereCameraProfile? cameraProfile,
}) {
  if (version == kSpherePlanV12Version) {
    return cameraProfile == null
        ? kSpherePlanV12
        : buildPlanV12(profile: cameraProfile);
  }
  if (version == kSpherePlanV11Version) {
    return cameraProfile == null
        ? kSpherePlanV11
        : buildPlanV11(profile: cameraProfile);
  }
  if (version == kAdaptiveSpherePlanVersion) {
    // Re-plan from the measured lens when one is available. Before the first
    // photograph this is safe: target ids are regenerated together with the
    // geometry, and the session persists the resulting plan. Once frames exist
    // the controller keeps the saved geometry instead of calling this.
    return cameraProfile == null
        ? kAdaptiveSpherePlan
        : generateAdaptivePlan(camera: cameraProfile);
  }
  throw StateError(
    'Capture plan $version is backup or unsupported for plan evaluation.',
  );
}

/// The vertical field of view **assumed** for the rear camera, in degrees.
///
/// The `camera` plugin does not expose intrinsics on Android, so this is a
/// documented assumption rather than a measurement — no code path may present
/// it as measured. It is declared once and consumed by both the live overlay
/// ([SphereProjection]) and the stitcher (`EquirectangularStitcher` derives its
/// focal length from it), so the aiming graphics and the panorama cannot
/// disagree about the lens. The horizontal FOV is never hard-coded anywhere:
/// it is always derived from the image dimensions and this vertical value.
///
/// Calibration evidence: the saved still is 3072 × 4096 with a 4.94 mm lens,
/// which is the device's 26 mm-equivalent main camera — about 50–53° horizontal
/// and 67–69° vertical in portrait. 65° is the conservative end of that band:
/// it makes the stitcher's frames slightly narrower than they are, so a
/// coverage check errs toward reporting a hole rather than hiding one.
///
/// **Device validation without touching geometry:** override at build time
/// with `--dart-define=sphereVerticalFovDeg=61` (whole degrees — enough for
/// lens validation) once a device's lens has been measured. The target
/// layout, IDs and capture sequence are unaffected. If a real intrinsics
/// path is added later, replace this constant with the reported value and
/// both consumers follow.
const int _kSphereFovOverride = int.fromEnvironment(
  'sphereVerticalFovDeg',
  defaultValue: 0,
);
const double kSphereAssumedVerticalFovDeg = _kSphereFovOverride > 0
    ? _kSphereFovOverride * 1.0
    : 65;

/// The nominal capture radius. The sphere is a direction set, so the radius is
/// documentation and future 3D previews rather than a placement input.
const double kSphereRadiusM = 1.0;

/// Elevation of the upper and lower rings of the **retired** 38-target plan.
///
/// The adaptive plan derives its ring pitches from the camera footprint
/// instead; this constant survives so historical plan-1/2 sessions can still
/// be read and so the guide can illustrate the retired geometry.
const double kSphereRingPitchDeg = 40;

/// The capture-plan version recorded with every new session and frame.
///
/// Every new capture and recapture is recorded as the canonical adaptive
/// five-ring plan (plan 12). Historical plans remain readable for sessions
/// captured with them.
const int kSphereCapturePlanVersion = kSphereCanonicalPlanVersion;

/// The alignment cone that turns a target green and starts the hold ring.
///
/// **2.0°.** At the previous 5° the shutter fired while the marker was still
/// visibly off the reticle: on a 576 × 768 viewfinder at the assumed 65° vFOV
/// the focal is ≈603 px, so 5° is ≈53 px — a sixth of the frame width. 2.0° is
/// ≈21 px, which reads as centred, and it is the value the capture
/// specification asks for.
///
/// Achievability: the rotation vector is fused, so its noise is a fraction of a
/// degree, and the shutter additionally requires the phone to be angularly
/// still for 250 ms ([MotionFreezeGate]) plus a 600 ms hold inside the cone. A
/// sensor too noisy to satisfy 2° cannot complete the hold, which is the correct
/// failure — no photograph rather than a mis-aimed one.
const double kSphereAlignmentToleranceDeg = 2.0;

/// How far past the tolerance the error must go before a filling hold is
/// discarded. A hand tremor at the boundary must not reset the ring, but a
/// deliberate turn must.
///
/// 1.3× the cone, matching the previous 5°/7° ratio so the hysteresis behaves
/// as it always has.
const double kSphereAlignmentExitDeg = 2.6;

/// One capture direction, before any photograph exists.
class SphereTargetSpec {
  /// 1-based. Assigned by ring, so it is a stable geometry key rather than a
  /// capture-order position.
  final int targetId;

  /// Azimuth within its ring, in degrees. `0` is straight ahead at Start.
  final double yawDeg;

  /// Elevation, in degrees: `+90` zenith, `0` horizon, `−90` nadir.
  final double pitchDeg;

  /// `Upper polar ring`, `Upper ring`, `Middle ring`, `Lower ring`,
  /// `Lower polar ring`, `Zenith` or `Nadir`.
  final String ringName;

  /// 1-based position within [ringName]; the poles leave it `null`.
  final int? indexInRing;

  /// Unit direction in the start device frame (`-Z` forward).
  final Vec3 direction;

  const SphereTargetSpec({
    required this.targetId,
    required this.yawDeg,
    required this.pitchDeg,
    required this.ringName,
    required this.direction,
    this.indexInRing,
  });

  bool get isZenith => pitchDeg >= 89.999;

  bool get isNadir => pitchDeg <= -89.999;

  /// `Zenith`, `Nadir`, or `Middle ring (0°)`.
  String get ringLabel {
    if (isZenith || isNadir) return ringName;
    return '$ringName (${yawDeg.round()}°)';
  }

  /// The ring in words, for the guidance sentence: `middle`, `upper polar`.
  String get ringWord {
    final lower = ringName.toLowerCase();
    if (lower.contains('polar')) {
      return lower.startsWith('upper') ? 'upper polar' : 'lower polar';
    }
    if (lower.startsWith('middle')) return 'middle';
    if (lower.startsWith('upper')) return 'upper';
    if (lower.startsWith('lower')) return 'lower';
    return 'next';
  }

  /// `Step 3 / 44 — Upper ring (0°)`.
  ///
  /// The step is the position in the guided sequence, which is what the
  /// photographer is counting; [targetId] is a stable geometry key and would be
  /// misleading here because ids are assigned by ring, not by capture order.
  String progressLabel({int? step, int total = kSphereTargetCount}) {
    if (step == null) return ringLabel;
    return 'Step $step / $total — $ringLabel';
  }

  /// The target as the guidance says it out loud.
  String get shortName {
    if (isZenith) return 'the ceiling target';
    if (isNadir) return 'the floor target';
    if (yawDeg.abs() < 1e-9 && pitchDeg.abs() < 1e-9) {
      return 'the front target';
    }
    return 'the $ringWord target';
  }
}

/// The unit direction of `(yaw, pitch)` in the start device frame.
///
/// `x = sin(yaw)·cos(pitch)`, `y = sin(pitch)`, `z = −cos(yaw)·cos(pitch)`.
/// A positive yaw is to the user's **right**, which is why the `z` term is
/// negated: the camera looks along `−Z`, not `+Z`.
Vec3 sphereDirection(double yawDeg, double pitchDeg) {
  final yaw = yawDeg * degToRad;
  final pitch = pitchDeg * degToRad;
  final horizontal = math.cos(pitch);
  return Vec3(
    math.sin(yaw) * horizontal,
    math.sin(pitch),
    -math.cos(yaw) * horizontal,
  );
}

/// Builds the target layout for [planVersion], in deterministic target-id order.
///
/// Plan 4 is the adaptive five-ring layout. Its ids are assigned by ring
/// (upper polar, upper, middle, lower, lower polar, caps) and are therefore
/// independent of the guided capture order — a target id means the same
/// direction whether it was the third or the fortieth photograph.
///
/// Plans 1–3 are the retired fixed layouts, kept so historical sessions still
/// resolve their geometry. They are never selected for a new capture.
///
/// Pure and deterministic for a given plan version and camera.
List<SphereTargetSpec> buildSphereTargets({
  int planVersion = kSphereCapturePlanVersion,
}) {
  if (![
    1,
    kSphereLegacyPlanVersion,
    kSphereEnhancedPlanVersion,
    kAdaptiveSpherePlanVersion,
    kSpherePlanV11Version,
    kSpherePlanV12Version,
  ].contains(planVersion)) {
    throw StateError('Unsupported sphere capture plan version: $planVersion');
  }
  if (planVersion == kSpherePlanV12Version) {
    return kSpherePlanV12.targets;
  }
  if (planVersion == kSpherePlanV11Version) {
    return kSpherePlanV11.targets;
  }
  if (planVersion == kAdaptiveSpherePlanVersion) {
    return kAdaptiveSpherePlan.targets;
  }
  if (planVersion == kSphereEnhancedPlanVersion) {
    final targets = <SphereTargetSpec>[];
    double wrap(double yaw) => ((yaw + 180) % 360 + 360) % 360 - 180;
    void ring(List<double> yaws, double pitch, String name) {
      for (var i = 0; i < yaws.length; i++) {
        final yaw = wrap(yaws[i]);
        final id = targets.length + 1;
        targets.add(
          SphereTargetSpec(
            targetId: id,
            yawDeg: yaw,
            pitchDeg: pitch,
            ringName: name,
            indexInRing: i + 1,
            direction: sphereDirection(yaw, pitch),
          ),
        );
      }
    }

    ring(List<double>.generate(18, (i) => i * 20.0), 0, 'Middle Ring');
    targets.add(
      SphereTargetSpec(
        targetId: targets.length + 1,
        yawDeg: 0,
        pitchDeg: 90,
        ringName: 'Zenith',
        direction: sphereDirection(0, 90),
      ),
    );
    ring(
      List<double>.generate(18, (i) => -20.0 - i * 20.0),
      kSphereRingPitchDeg,
      'Upper Ring',
    );
    ring(
      List<double>.generate(18, (i) => i * 20.0),
      -kSphereRingPitchDeg,
      'Lower Ring',
    );
    targets.add(
      SphereTargetSpec(
        targetId: targets.length + 1,
        yawDeg: 0,
        pitchDeg: -90,
        ringName: 'Nadir',
        direction: sphereDirection(0, -90),
      ),
    );
    return List<SphereTargetSpec>.unmodifiable(targets);
  }
  const List<double> middleYaws = <double>[
    0,
    30,
    60,
    90,
    120,
    150,
    180,
    -150,
    -120,
    -90,
    -60,
    -30,
  ];
  // Reverse sweep: starts at the yaw the middle ring ended on (−30°) and walks
  // back to 0°, so the ring transition is 35° rather than a longer jump.
  const List<double> upperYaws = <double>[
    -30,
    -60,
    -90,
    -120,
    -150,
    180,
    150,
    120,
    90,
    60,
    30,
    0,
  ];
  const List<double> lowerYaws = <double>[
    0,
    30,
    60,
    90,
    120,
    150,
    180,
    -150,
    -120,
    -90,
    -60,
    -30,
  ];

  final targets = <SphereTargetSpec>[];
  var id = 0;

  void addRing(List<double> yaws, double pitch, String ringName) {
    for (var index = 0; index < yaws.length; index++) {
      id++;
      targets.add(
        SphereTargetSpec(
          targetId: id,
          yawDeg: yaws[index],
          pitchDeg: pitch,
          ringName: ringName,
          indexInRing: index + 1,
          direction: sphereDirection(yaws[index], pitch),
        ),
      );
    }
  }

  addRing(middleYaws, 0, 'Middle Ring');

  // The zenith sits between the hemispheres: 90° up from the horizon, then 55°
  // back down to the upper ring. After the lower ring it would be 135° away
  // from the next target — a jump no guided path should ask for.
  id++;
  targets.add(
    SphereTargetSpec(
      targetId: id,
      yawDeg: 0,
      pitchDeg: 90,
      ringName: 'Zenith',
      direction: sphereDirection(0, 90),
    ),
  );

  final legacyPitch = planVersion == 1 ? 35.0 : kSphereRingPitchDeg;
  addRing(upperYaws, legacyPitch, 'Upper Ring');
  addRing(lowerYaws, -legacyPitch, 'Lower Ring');

  // Yaw is undefined at the poles and stays 0, so the recorded value is stable
  // rather than NaN.
  id++;
  targets.add(
    SphereTargetSpec(
      targetId: id,
      yawDeg: 0,
      pitchDeg: -90,
      ringName: 'Nadir',
      direction: sphereDirection(0, -90),
    ),
  );
  return List<SphereTargetSpec>.unmodifiable(targets);
}

/// Capture order for new sessions. Target ids remain the geometry keys
/// persisted to storage and consumed by the backend; this list only controls
/// the guided order shown to the photographer.
///
/// Plan 4 uses the connected-sector order from the adaptive planner: two
/// neighbouring middle frames first, then their upper and lower counterparts
/// and a polar frame, then sector by sector — so horizontal and vertical
/// alignment are established before the photographer has walked a quarter of
/// the way round. The pole caps are placed where they connect to frames
/// already on the sphere.
///
/// Historical sessions retain their original sequence.
List<int> sphereCaptureSequence({int planVersion = kSphereCapturePlanVersion}) {
  if (![
    1,
    kSphereLegacyPlanVersion,
    kSphereEnhancedPlanVersion,
    kAdaptiveSpherePlanVersion,
    kSpherePlanV11Version,
    kSpherePlanV12Version,
  ].contains(planVersion)) {
    throw StateError('Unsupported sphere capture plan version: $planVersion');
  }
  if (planVersion == kSpherePlanV12Version) {
    // Plan 12's ids ARE the capture order: the connected-sector sequence is
    // 1…44 by construction.
    return kSpherePlanV12.captureOrder;
  }
  if (planVersion == kSpherePlanV11Version) {
    // Ids are the capture order: each middle target is followed by a ceiling or
    // floor arch, so almost every step is 15° of yaw with 30° of pitch and the
    // previous photograph is still inside the frame (39/43 verified). The four
    // upper→lower steps that cannot be visible are published by the plan and
    // exempted from the shutter gate.
    return kSpherePlanV11.captureOrder;
  }
  if (planVersion == kAdaptiveSpherePlanVersion) {
    return kAdaptiveSpherePlan.captureOrder;
  }
  if (planVersion == kSphereEnhancedPlanVersion) {
    return List<int>.generate(
      sphereTargetCountForPlan(planVersion),
      (i) => i + 1,
    );
  }
  return <int>[
    ...List<int>.generate(12, (i) => i + 1),
    ...List<int>.generate(12, (i) => i + 14),
    ...List<int>.generate(12, (i) => i + 26),
    13,
    38,
  ];
}

/// The sphere's reference frame for a start pose, with the phone's pitch and
/// roll removed but its heading kept.
///
/// ## Why this exists
///
/// The layout says the middle ring is the **horizon** (pitch 0°) and the other
/// rings are 35° above and below it. That is only true if the frame the ring is
/// measured in has the world's up axis as its own up axis. Seeding the sphere
/// from the first raw sensor sample does not: the phone is normally held tilted
/// while the user reaches for **Start**, so the whole sphere inherits that tilt
/// — every marker then sits at the same constant angle off the real room, while
/// still tracking the phone perfectly. That is the "each target is not stuck on
/// the correct way" symptom.
///
/// ## The frame trap this function used to fall into
///
/// Levelling used to be written as `h = (forward.x, 0, forward.z)` — a hard
/// coded `+Y`-up assumption — and then `Quat.fromYawPitch(-heading, 0)`, a
/// rotation about `+Y`. Android's `TYPE_ROTATION_VECTOR` reports in an
/// **East–North–Up** frame, where up is `+Z` and `+Y` is magnetic north. So the
/// "horizontal projection" was really a projection onto the East–Up plane, and
/// the "yaw" was a rotation about the north axis — a *roll*. Measured on a
/// phone held 30° down and facing north, target 1 landed on `(0, 0, −1)`,
/// i.e. pointing at the floor, 60° away from the reticle instead of the correct
/// 30° above it. Every ring inherited that 90° error, which is exactly what
/// "targets scattered and tilted relative to the room" describes.
///
/// ## What it does now
///
/// It builds the levelled device→world rotation directly from an orthonormal
/// basis, using the up axis it is *told* about:
///
/// * `heading` = the camera axis with its [worldUp] component removed;
/// * `right   = heading × up`, so `right × up == −heading` and the basis is a
///   proper rotation (determinant `+1`, never a mirror);
/// * the frame is `[right | up | −heading]`, i.e. device `+X` → right, `+Y` →
///   up, `−Z` (the optical axis) → heading.
///
/// The heading is preserved, so target 1 is still the direction the user was
/// facing when they pressed Start — but at true horizontal level.
///
/// ## Rejection
///
/// Aiming at the ceiling or the floor leaves no stable heading — the horizontal
/// projection collapses and any yaw taken from it would be noise. Below
/// [minHorizontal] this returns **null**, and the caller keeps waiting for a
/// usable pose rather than freezing a reference the whole station would inherit.
///
/// Pure, so the convention is testable without a sensor.
Quat? levelStartFrame(
  Quat deviceToWorld, {
  Vec3 worldUp = Vec3.unitY,
  double minHorizontal = 0.25,
}) {
  final up = worldUp.normalized;
  if (up.length < 0.5) return null;
  final forward = deviceToWorld.rotate(const Vec3(0, 0, -1));
  // Component of the optical axis perpendicular to gravity: the heading.
  final horizontal = forward - up * forward.dot(up);
  if (horizontal.length < minHorizontal) return null;
  final heading = horizontal.normalized;
  // `right × up == −heading`, which is the image of device `+Z`; that is what
  // makes the three columns a rotation rather than a reflection.
  final right = heading.cross(up);
  final back = -heading;
  return Quat.fromMatrix3(<double>[
    right.x, up.x, back.x, //
    right.y, up.y, back.y, //
    right.z, up.z, back.z, //
  ]);
}

/// Whether [deviceToWorld] points far enough from vertical to define a heading.
///
/// The optical axis projected onto the plane perpendicular to [worldUp] must be
/// at least [minHorizontal] long, i.e. the camera must be more than ~14.5° away
/// from straight up or straight down. Below that the heading is undefined and
/// the calibration is rejected instead of being guessed.
bool hasStableHeading(
  Quat deviceToWorld, {
  Vec3 worldUp = Vec3.unitY,
  double minHorizontal = 0.25,
}) {
  final up = worldUp.normalized;
  if (up.length < 0.5) return false;
  final forward = deviceToWorld.rotate(const Vec3(0, 0, -1));
  return (forward - up * forward.dot(up)).length >= minHorizontal;
}

/// How far the camera axis is above the horizon, in degrees.
///
/// Positive is tilted **up**. Used for the "tilt up to reach the horizon" hint
/// at Start and for the vertical half of the turn guidance; it is not part of
/// any capture decision, which stays a true 3-D angle.
double cameraElevationDeg(Quat deviceToWorld, {Vec3 worldUp = Vec3.unitY}) {
  final up = worldUp.normalized;
  if (up.length < 0.5) return 0;
  final forward = deviceToWorld.rotate(const Vec3(0, 0, -1));
  return math.asin(clampDouble(forward.dot(up), -1, 1)) * radToDeg;
}

// SITEWISE_CAPTURE_PLAN_WIRING_V2: backend-verified v3 geometry, existing standard generator retained.
const int kSitewiseEnhancedTargetCount = 56;

/// The version a **new** session with [count] targets is created under.
///
/// The canonical adaptive five-ring plan (12) is returned for the 44-target
/// reference capture. Historical sessions use the explicit version saved with
/// the session rather than inferring it from count.
int sitewisePlanVersionForCount(int count) {
  if (count == 44) return kSphereCanonicalPlanVersion;
  if (count == kSitewiseEnhancedTargetCount) return kSphereEnhancedPlanVersion;
  throw StateError(
    'The saved capture plan version is required for this target count.',
  );
}

bool planVersionMatchesCount(int version, int count) {
  if (version == kSpherePlanV12Version ||
      version == kSpherePlanV11Version ||
      version == kAdaptiveSpherePlanVersion) {
    return count == kSpherePlanV12TargetCount;
  }
  if (version == kSphereLegacyPlanVersion) {
    return count == kSphereLegacyTargetCount;
  }
  if (version == 1) {
    return count == kSphereLegacyTargetCount;
  }
  if (version == kSphereEnhancedPlanVersion) {
    return count == kSitewiseEnhancedTargetCount;
  }
  return false;
}

List<SphereTargetSpec> buildSitewiseSessionTargets(
  int count, {
  int? planVersion,
}) {
  if (planVersion == null &&
      (count == kSpherePlanV12TargetCount ||
          count == kSphereLegacyTargetCount)) {
    throw StateError(
      'This saved session must record its plan version because multiple plans share its target count.',
    );
  }
  final version = planVersion ?? sitewisePlanVersionForCount(count);
  if (!planVersionMatchesCount(version, count)) {
    throw StateError('Plan $version does not have $count targets.');
  }
  if (version == kSpherePlanV12Version) {
    return kSpherePlanV12.targets;
  }
  if (version == kSpherePlanV11Version) {
    return kSpherePlanV11.targets;
  }
  if (version == kAdaptiveSpherePlanVersion) {
    return kAdaptiveSpherePlan.targets;
  }
  if (version == 1 || version == kSphereLegacyPlanVersion) {
    return buildSphereTargets(planVersion: version);
  }
  if (version != kSphereEnhancedPlanVersion) {
    throw StateError('Unsupported saved sphere capture plan version: $version');
  }
  const directions = <(double, double)>[
    (0.000000, 0.000000),
    (20.000000, 0.000000),
    (40.000000, 0.000000),
    (60.000000, 0.000000),
    (80.000000, 0.000000),
    (100.000000, 0.000000),
    (120.000000, 0.000000),
    (140.000000, 0.000000),
    (160.000000, 0.000000),
    (-180.000000, 0.000000),
    (-160.000000, 0.000000),
    (-140.000000, 0.000000),
    (-120.000000, 0.000000),
    (-100.000000, 0.000000),
    (-80.000000, 0.000000),
    (-60.000000, 0.000000),
    (-40.000000, 0.000000),
    (-20.000000, 0.000000),
    (0.000000, 90.000000),
    (-20.000000, 40.000000),
    (-40.000000, 40.000000),
    (-60.000000, 40.000000),
    (-80.000000, 40.000000),
    (-100.000000, 40.000000),
    (-120.000000, 40.000000),
    (-140.000000, 40.000000),
    (-160.000000, 40.000000),
    (-180.000000, 40.000000),
    (160.000000, 40.000000),
    (140.000000, 40.000000),
    (120.000000, 40.000000),
    (100.000000, 40.000000),
    (80.000000, 40.000000),
    (60.000000, 40.000000),
    (40.000000, 40.000000),
    (20.000000, 40.000000),
    (0.000000, 40.000000),
    (0.000000, -40.000000),
    (20.000000, -40.000000),
    (40.000000, -40.000000),
    (60.000000, -40.000000),
    (80.000000, -40.000000),
    (100.000000, -40.000000),
    (120.000000, -40.000000),
    (140.000000, -40.000000),
    (160.000000, -40.000000),
    (-180.000000, -40.000000),
    (-160.000000, -40.000000),
    (-140.000000, -40.000000),
    (-120.000000, -40.000000),
    (-100.000000, -40.000000),
    (-80.000000, -40.000000),
    (-60.000000, -40.000000),
    (-40.000000, -40.000000),
    (-20.000000, -40.000000),
    (0.000000, -90.000000),
  ];
  final enhanced = buildSphereTargets(planVersion: 3);
  if (enhanced.length != directions.length) {
    throw StateError('Mobile enhanced plan count does not match backend v3.');
  }
  for (var i = 0; i < directions.length; i++) {
    final (yaw, pitch) = directions[i];
    final t = enhanced[i];
    final yawError = ((t.yawDeg - yaw + 180) % 360 - 180).abs();
    if (t.targetId != i + 1 ||
        yawError > 0.0001 ||
        (t.pitchDeg - pitch).abs() > 0.0001) {
      throw StateError(
        'Mobile enhanced plan differs from backend v3 at target ${i + 1}.',
      );
    }
  }
  return List<SphereTargetSpec>.unmodifiable(enhanced);
}
