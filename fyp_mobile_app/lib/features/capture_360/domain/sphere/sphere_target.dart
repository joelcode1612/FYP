import 'dart:math' as math;

import 'package:fyp/features/capture_360/domain/virtual_tour/math/quaternions.dart';
import 'package:fyp/features/capture_360/domain/virtual_tour/math/scalars.dart';
import 'package:fyp/features/capture_360/domain/virtual_tour/math/vectors.dart';

// The fixed 38-direction sphere of the 3DoF capture architecture.
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
// ## Layout (R = 1.0) — 38 directions
//
// ids 1–12:  Middle Ring, pitch 0°,   yaw 0°, 30°, … 330°
// id 13:     Zenith,      pitch +90°
// ids 14–25: Upper Ring,  pitch +40°, yaw −30°, −60°, … 0° (reverse sweep)
// ids 26–37: Lower Ring,  pitch −40°, yaw 0°, 30°, … 330°
// id 38:     Nadir,       pitch −90°
//
// ## Why 38 and not 26
//
// The rear camera measures ~53° horizontal and ~67° vertical in portrait (a
// 3072 × 4096 still). At 45° yaw spacing — the 26-target template — adjacent
// frames share only 8°, i.e. 15% overlap, and the ±30° rings leave a 60° gap to
// the poles. That is enough for coverage but thin for blending: the seam band
// is a few degrees wide, so a 1–2° orientation error shows as a visible step.
//
// Twelve per ring puts the yaw step at 30°, i.e. 44% horizontal overlap. Rings
// at ±40° put the vertical ring gap at 40° (≈38% overlap against the 65°
// assumed vertical field of view) while the pole gap is 50° (≈23% overlap).
// Every adjacent pair of rings still shares a real band of sky at the assumed
// lens — the zenith frame reaches down to ≈57.5° and the upper ring up to
// ≈72.5° — so the blend seams stay inside overlapping content; re-run
// tool/sphere_coverage_report.py whenever the lens assumption changes. The ring
// target IDs describe geometry; the guided capture order is separate and is
// middle → upper → lower → zenith → nadir, establishing ring overlaps before
// the pole caps.
//
// The upper ring sweeps backwards so it starts at the yaw where the middle ring
// ended, preserving continuity when the flow moves from the middle to upper
// ring.

/// How many directions a complete sphere has.
const int kSphereTargetCount = 38;
const int kSphereEnhancedTargetCount = 56;
const int kSphereEnhancedPlanVersion = 3;

int sphereTargetCountForPlan(int version) =>
    version == kSphereEnhancedPlanVersion ? kSphereEnhancedTargetCount : kSphereTargetCount;

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

/// Elevation of the upper and lower rings, in degrees.
///
/// The SiteWise capture specification fixes the rings at **±40°**: with the
/// assumed 65° vertical field of view every adjacent ring pair still overlaps
/// (the between-ring band is ≈25° of frame height and the pole band ≈15°), so
/// stitching keeps real shared content while the layout matches the spec's
/// three-ring-plus-poles geometry.
const double kSphereRingPitchDeg = 40;

/// The capture-plan version recorded with every session and frame.
///
/// **2** is the ±40° three-ring-plus-poles layout above. Version 1 sessions
/// (the earlier ±35° rings) remain readable: every frame persists its own
/// intended yaw/pitch, so recovery and stitching never depend on the current
/// constant matching the layout the older photographs were taken with.
const int kSphereCapturePlanVersion = 2;

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

/// One of the 38 directions, before any photograph exists.
class SphereTargetSpec {
  /// 1-based, 1…38.
  final int targetId;

  /// Azimuth within its ring, in degrees. `0` is straight ahead at Start.
  final double yawDeg;

  /// Elevation, in degrees: `+90` zenith, `0` horizon, `−90` nadir.
  final double pitchDeg;

  /// `Middle Ring`, `Upper Ring`, `Lower Ring`, `Zenith` or `Nadir`.
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

  /// `Zenith`, `Nadir`, or `Middle Ring (0°)`.
  String get ringLabel {
    if (isZenith || isNadir) return ringName;
    return '$ringName (${yawDeg.round()}°)';
  }

  /// The bottom pill's sentence: `Target 1 / 38 — Middle Ring (0°)`.
  String get progressLabel =>
      'Target $targetId / $kSphereTargetCount — '
      '$ringLabel';

  /// The target as the guidance says it out loud.
  String get shortName {
    if (isZenith) return 'the zenith target';
    if (isNadir) return 'the nadir target';
    if (yawDeg.abs() < 1e-9 && pitchDeg.abs() < 1e-9) {
      return 'the front target';
    }
    return 'target $targetId';
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

/// Builds the fixed 38-target layout in capture order.
///
/// Pure and deterministic: the id→angle mapping is asserted once in the test
/// suite rather than re-derived per session. The order is the sequence the
/// progress pill counts through and the order the guide arrow follows, so the
/// two cannot disagree.
///
/// Target **1 is always the middle ring at yaw 0** — the direction the user was
/// facing when the sphere was calibrated. The controller refuses to capture
/// anything else until it is saved, which is what makes the first photograph a
/// known, horizon-level frame rather than whatever happened to be nearest.
List<SphereTargetSpec> buildSphereTargets({int planVersion = kSphereCapturePlanVersion}) {
  if (planVersion == kSphereEnhancedPlanVersion) {
    final targets = <SphereTargetSpec>[];
    double wrap(double yaw) => ((yaw + 180) % 360 + 360) % 360 - 180;
    void ring(List<double> yaws, double pitch, String name) {
      for (var i = 0; i < yaws.length; i++) {
        final yaw = wrap(yaws[i]);
        final id = targets.length + 1;
        targets.add(SphereTargetSpec(targetId: id, yawDeg: yaw, pitchDeg: pitch,
          ringName: name, indexInRing: i + 1, direction: sphereDirection(yaw, pitch)));
      }
    }
    ring(List<double>.generate(18, (i) => i * 20.0), 0, 'Middle Ring');
    targets.add(SphereTargetSpec(targetId: targets.length + 1, yawDeg: 0, pitchDeg: 90,
      ringName: 'Zenith', direction: sphereDirection(0, 90)));
    ring(List<double>.generate(18, (i) => -20.0 - i * 20.0), kSphereRingPitchDeg, 'Upper Ring');
    ring(List<double>.generate(18, (i) => i * 20.0), -kSphereRingPitchDeg, 'Lower Ring');
    targets.add(SphereTargetSpec(targetId: targets.length + 1, yawDeg: 0, pitchDeg: -90,
      ringName: 'Nadir', direction: sphereDirection(0, -90)));
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

  addRing(upperYaws, kSphereRingPitchDeg, 'Upper Ring');
  addRing(lowerYaws, -kSphereRingPitchDeg, 'Lower Ring');

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

/// Capture order for new standard-plan sessions. Target IDs remain the
/// geometry keys persisted to storage and consumed by the backend; this list
/// only controls the guided order shown to the photographer.
///
/// Establish the horizon first, then capture both connecting rings, and leave
/// the pole caps until ring-to-ring overlap has been recorded. Historical
/// 56-target sessions retain their original sequence.
List<int> sphereCaptureSequence({int planVersion = kSphereCapturePlanVersion}) {
  if (planVersion == kSphereEnhancedPlanVersion) {
    return List<int>.generate(sphereTargetCountForPlan(planVersion), (i) => i + 1);
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

int sitewisePlanVersionForCount(int count) {
  if (count == 38) return 2;
  if (count == kSitewiseEnhancedTargetCount) return 3;
  throw StateError('Unsupported sphere capture plan: $count');
}

List<SphereTargetSpec> buildSitewiseSessionTargets(int count) {
  sitewisePlanVersionForCount(count);
  if (count == 38) {
    final standard = buildSphereTargets(planVersion: 2);
    if (standard.length != 38) throw StateError('Standard sphere plan must have 38 targets.');
    return standard;
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
    if (t.targetId != i + 1 || yawError > 0.0001 ||
        (t.pitchDeg - pitch).abs() > 0.0001) {
      throw StateError('Mobile enhanced plan differs from backend v3 at target ${i + 1}.');
    }
  }
  return List<SphereTargetSpec>.unmodifiable(enhanced);
}
