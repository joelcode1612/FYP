import 'dart:math' as math;

import 'package:fyp/features/capture_360/domain/sphere/sphere_target.dart';
import 'package:fyp/features/capture_360/domain/virtual_tour/math/quaternions.dart';
import 'package:fyp/features/capture_360/domain/virtual_tour/math/scalars.dart';
import 'package:fyp/features/capture_360/domain/virtual_tour/math/vectors.dart';

// Adaptive five-ring capture planning.
//
// ## Why the layout is generated, not fixed
//
// A target is a direction to point at. Whether that direction actually covers
// the sphere depends on the lens: at a 51° horizontal field of view, 30° yaw
// spacing shares 41% of each frame, while at 38° it would share 21% — the
// difference between a blendable seam band and a visible step. The previous
// fixed 38/56 layouts assumed one lens for every device, so a narrower camera
// produced a panorama with thin seams and a wider one wasted photographs.
//
// This module derives the ring spacing from the **captured image** footprint
// (never the preview, which is cropped differently), evaluates candidate
// layouts against measured spherical coverage, and returns the lowest-count
// layout that satisfies the configured coverage, overlap and connectivity
// requirements.
//
// ## The five rings
//
// | Ring        | Pitch | Yaw step | Reference count |
// |-------------|-------|----------|-----------------|
// | Upper polar | +65°  | 90°      | 4               |
// | Upper       | +30°  | 30°      | 12              |
// | Middle      | 0°    | 30°      | 12              |
// | Lower       | −30°  | 30°      | 12              |
// | Lower polar | −65°  | 90°      | 4               |
//
// The three main rings share the same yaw positions, and the polar rings sit
// directly above and below middle targets (0°, 90°, 180°, 270°) rather than
// being staggered by 15°. Aligning them vertically is what gives the polar
// frames a wide overlap with the upper/lower frames beneath them; staggering
// would halve it for no gain in coverage.
//
// ## Overlap normalisation
//
// Overlap is the **shared spherical area as a fraction of the smaller
// footprint**, computed as the lens area of two spherical caps whose radii are
// the frames' diagonal half-angles. It is deliberately not derived from the
// yaw or pitch difference: two frames 30° apart horizontally overlap very
// differently depending on how tall the image is.

/// One ring of the adaptive plan.
class PlanRingSpec {
  const PlanRingSpec({
    required this.key,
    required this.title,
    required this.pitchDeg,
    required this.yaws,
  });

  /// Stable identifier persisted with the plan: `upper_polar`, `upper`,
  /// `middle`, `lower`, `lower_polar`, `zenith`, `nadir`.
  final String key;

  /// Human label for the guidance UI.
  final String title;

  /// Elevation of every target in this ring, in degrees.
  final double pitchDeg;

  /// Azimuth of each target, in degrees, in ascending order from 0°.
  final List<double> yaws;

  int get count => yaws.length;

  bool get isPolar => key == 'upper_polar' || key == 'lower_polar';
  bool get isCap => key == 'zenith' || key == 'nadir';

  Map<String, Object?> toJson() => <String, Object?>{
    'key': key,
    'title': title,
    'pitchDeg': pitchDeg,
    'yaws': yaws,
    'count': count,
  };
}

/// The camera's usable **captured-image** footprint.
///
/// [source] records how the numbers were obtained, because the plan's honesty
/// depends on it: `calibrated` means the device reported intrinsics, `assumed`
/// means the documented 65° vertical field of view was used. An assumed
/// profile reports reduced [confidence] and the guidance UI says so — no code
/// path presents an assumption as a measurement.
class SphereCameraProfile {
  const SphereCameraProfile({
    required this.imageWidth,
    required this.imageHeight,
    required this.focalPx,
    required this.principalXPx,
    required this.principalYPx,
    required this.source,
    required this.confidence,
  });

  final int imageWidth;
  final int imageHeight;
  final double focalPx;
  final double principalXPx;
  final double principalYPx;

  /// `calibrated` or `assumed`.
  final String source;

  /// 0…1. 1.0 only when the device reported real intrinsics.
  final double confidence;

  /// The documented assumption: 3072 × 4096 with a 65° vertical field of view,
  /// i.e. the device's 26 mm-equivalent main camera. 65° is the conservative
  /// end of the measured 67–69° band, so a coverage check errs toward reporting
  /// a hole rather than hiding one.
  factory SphereCameraProfile.assumed({
    int imageWidth = 3072,
    int imageHeight = 4096,
    double verticalFovDeg = kSphereAssumedVerticalFovDeg,
  }) {
    final focal = (imageHeight / 2) / math.tan(verticalFovDeg * math.pi / 360);
    return SphereCameraProfile(
      imageWidth: imageWidth,
      imageHeight: imageHeight,
      focalPx: focal,
      principalXPx: imageWidth / 2,
      principalYPx: imageHeight / 2,
      source: 'assumed',
      confidence: 0.45,
    );
  }

  /// A profile from intrinsics the device actually reported.
  factory SphereCameraProfile.calibrated({
    required int imageWidth,
    required int imageHeight,
    required double focalPx,
    double? principalXPx,
    double? principalYPx,
  }) => SphereCameraProfile(
    imageWidth: imageWidth,
    imageHeight: imageHeight,
    focalPx: focalPx,
    principalXPx: principalXPx ?? imageWidth / 2,
    principalYPx: principalYPx ?? imageHeight / 2,
    source: 'calibrated',
    confidence: 1.0,
  );

  bool get isCalibrated => source == 'calibrated';

  double get halfWidthRatio => (imageWidth / 2) / focalPx;
  double get halfHeightRatio => (imageHeight / 2) / focalPx;

  double get horizontalFovDeg =>
      2 * math.atan(halfWidthRatio) * radToDeg;
  double get verticalFovDeg => 2 * math.atan(halfHeightRatio) * radToDeg;
  double get diagonalFovDeg =>
      2 * math.atan(math.sqrt(
        halfWidthRatio * halfWidthRatio +
            halfHeightRatio * halfHeightRatio,
      )) *
      radToDeg;

  /// Exact solid angle of the image rectangle on the unit sphere.
  double get solidAngleSr {
    final a = halfWidthRatio;
    final b = halfHeightRatio;
    return 4 * math.asin((a * b) / math.sqrt(1 + a * a + b * b));
  }

  /// Fraction of the full sphere one photograph covers.
  double get sphereFraction => solidAngleSr / (4 * math.pi);

  Map<String, Object?> toJson() => <String, Object?>{
    'imageWidth': imageWidth,
    'imageHeight': imageHeight,
    'focalPx': focalPx,
    'principalXPx': principalXPx,
    'principalYPx': principalYPx,
    'source': source,
    'confidence': confidence,
    'horizontalFovDeg': horizontalFovDeg,
    'verticalFovDeg': verticalFovDeg,
    'diagonalFovDeg': diagonalFovDeg,
    'sphereFraction': sphereFraction,
  };
}

/// Requirements a layout must meet before it is accepted.
class PlanConstraints {
  const PlanConstraints({
    this.minimumOverlap = 0.30,
    this.preferredOverlapLow = 0.35,
    this.preferredOverlapHigh = 0.45,
    this.requiredSingleCoverage = 1.0,
    this.requiredDoubleCoverage = 0.95,
    this.candidateYawCounts = const <int>[8, 9, 10, 12, 15, 18],
    this.candidatePolarCounts = const <int>[4, 6, 8],
    this.maxTargets = 72,
  });

  /// The floor below which two neighbouring frames are not considered
  /// connected. 30% is the specification's minimum useful overlap.
  final double minimumOverlap;
  final double preferredOverlapLow;
  final double preferredOverlapHigh;

  /// Full spherical coverage is required, exactly — a layout that leaves one
  /// sampling cell uncovered is rejected, not rounded up.
  final double requiredSingleCoverage;

  /// Preferred double coverage. 95% leaves a seam band everywhere except the
  /// thinnest corners.
  final double requiredDoubleCoverage;

  final List<int> candidateYawCounts;
  final List<int> candidatePolarCounts;
  final int maxTargets;
}

/// Measured properties of one candidate layout.
class PlanMetrics {
  const PlanMetrics({
    required this.singleCoverage,
    required this.doubleCoverage,
    required this.minimumNeighbourOverlap,
    required this.medianNeighbourOverlap,
    required this.minimumConnections,
    required this.connectedComponents,
    required this.isolatedTargets,
    required this.totalFootprintFraction,
    required this.gridCells,
    required this.resolutionDeg,
  });

  final double singleCoverage;
  final double doubleCoverage;
  final double minimumNeighbourOverlap;
  final double medianNeighbourOverlap;
  final int minimumConnections;
  final int connectedComponents;
  final List<int> isolatedTargets;
  final double totalFootprintFraction;
  final int gridCells;
  final double resolutionDeg;

  bool get isConnected => connectedComponents <= 1;

  /// Whether this layout satisfies [constraints] for [profile].
  bool satisfies(PlanConstraints constraints) =>
      singleCoverage >= constraints.requiredSingleCoverage &&
      doubleCoverage >= constraints.requiredDoubleCoverage &&
      minimumNeighbourOverlap >= constraints.minimumOverlap &&
      isConnected &&
      isolatedTargets.isEmpty;

  Map<String, Object?> toJson() => <String, Object?>{
    'singleCoverage': singleCoverage,
    'doubleCoverage': doubleCoverage,
    'minimumNeighbourOverlap': minimumNeighbourOverlap,
    'medianNeighbourOverlap': medianNeighbourOverlap,
    'minimumConnections': minimumConnections,
    'connectedComponents': connectedComponents,
    'isolatedTargets': isolatedTargets,
    'totalFootprintFraction': totalFootprintFraction,
    'gridCells': gridCells,
    'resolutionDeg': resolutionDeg,
  };
}

/// The adaptive five-ring plan for one camera.
class AdaptiveSpherePlan {
  const AdaptiveSpherePlan({
    required this.planVersion,
    required this.camera,
    required this.rings,
    required this.targets,
    required this.captureOrder,
    required this.metrics,
    required this.constraints,
    required this.notes,
    this.previousVisibilityExempt = const <int>{},
  });

  /// Persisted with the session. 4 is the adaptive five-ring layout; 1–3 are
  /// the historical fixed plans and remain readable.
  final int planVersion;

  final SphereCameraProfile camera;
  final List<PlanRingSpec> rings;

  /// Every target, ordered by deterministic target id (ring order), **not** by
  /// capture order. Target ids are the keys frames and matches are recorded
  /// against, so they must never depend on when a photograph was taken.
  final List<SphereTargetSpec> targets;

  /// Target ids in the guided capture order.
  final List<int> captureOrder;

  final PlanMetrics metrics;
  final PlanConstraints constraints;

  /// Human-readable reasons the layout differs from the 44-target reference,
  /// or an empty list when it matches. Shown in the diagnostic view only.
  final List<String> notes;

  /// Target ids whose previous-target-visibility check is unsatisfiable by
  /// construction.
  ///
  /// A plan can demand more visible transitions than its ring sizes allow: the
  /// 4+4 cap layout on 12-target rings over-determines the edge count by four,
  /// so four steps necessarily leave the previous photograph outside the
  /// frame. Those ids are recorded here — computed from the measured audit,
  /// never assumed — so the shutter gate can exempt exactly them instead of
  /// waiting forever on a requirement no orientation can satisfy. Empty for
  /// every plan whose transitions are all visible.
  final Set<int> previousVisibilityExempt;

  int get targetCount => targets.length;

  bool get isReferenceLayout =>
      targetCount == 44 &&
      rings.every((ring) => ring.key != 'zenith' && ring.key != 'nadir');

  /// Total degrees of camera movement the guided order asks for. A proxy for
  /// how much work the sequence is; the selector minimises it among layouts
  /// that already satisfy connectivity.
  double get totalRotationDeg {
    var total = 0.0;
    SphereTargetSpec? previous;
    for (final id in captureOrder) {
      final target = targetById(id);
      if (target == null) continue;
      if (previous != null) {
        total += angleBetweenDeg(previous.direction, target.direction);
      }
      previous = target;
    }
    return total;
  }

  SphereTargetSpec? targetById(int id) {
    for (final target in targets) {
      if (target.targetId == id) return target;
    }
    return null;
  }

  PlanRingSpec? ringFor(int targetId) {
    final target = targetById(targetId);
    if (target == null) return null;
    final key = ringKeyOf(target.ringName);
    for (final ring in rings) {
      if (ring.key == key) return ring;
    }
    return null;
  }

  /// The ring key for a target's display name.
  ///
  /// `SphereTargetSpec.ringName` is prose — "Middle ring", because that is what
  /// the guidance shows — while [PlanRingSpec.key] is the stable identifier the
  /// geometry uses. Comparing the two directly silently returns `null` for
  /// every target, so every lookup goes through this mapping.
  static String ringKeyOf(String ringName) {
    switch (ringName.toLowerCase()) {
      case 'upper polar ring':
        return 'upper_polar';
      case 'upper ring':
        return 'upper';
      case 'lower ring':
        return 'lower';
      case 'lower polar ring':
        return 'lower_polar';
      case 'ceiling ring':
        return 'ceiling';
      case 'floor ring':
        return 'floor';
      case 'zenith':
        return 'zenith';
      case 'nadir':
        return 'nadir';
      default:
        return 'middle';
    }
  }

  /// The sector a target belongs to: the shared yaw position of the three main
  /// rings. Used by the guidance UI to say "sector 3 of 12".
  int sectorOf(int targetId) {
    final target = targetById(targetId);
    if (target == null) return 0;
    final middle = rings.firstWhere(
      (ring) => ring.key == 'middle',
      orElse: () => rings.first,
    );
    if (middle.yaws.isEmpty) return 0;
    final step = 360.0 / middle.yaws.length;
    final normalised = (target.yawDeg % 360 + 360) % 360;
    return (normalised / step).round() % middle.yaws.length;
  }

  /// The plan as the backend stores it.
  ///
  /// Deliberately separate from [toJson]: the local file keeps the camelCase
  /// shape [fromJson] reads, while the API contract is snake_case. Deriving one
  /// from the other with a case conversion would silently break the moment a
  /// field name stopped being a single word.
  ///
  /// `capture_order` is included because the guidance sequence is part of what
  /// a resumed session must reproduce, and the backend uses it to order the
  /// alignment frames the same way the photographer shot them.
  Map<String, Object?> toBackendPayload() {
    final order = <int, int>{
      for (var i = 0; i < captureOrder.length; i++) captureOrder[i]: i + 1,
    };
    return <String, Object?>{
      'plan_version': '$planVersion',
      'intrinsics': <String, Object?>{
        'image_width': camera.imageWidth,
        'image_height': camera.imageHeight,
        'focal_px': camera.focalPx,
        'principal_x_px': camera.principalXPx,
        'principal_y_px': camera.principalYPx,
        'vertical_fov_deg': camera.verticalFovDeg,
        'horizontal_fov_deg': camera.horizontalFovDeg,
        'source': camera.source,
        'confidence': camera.confidence,
      },
      'targets': <Map<String, Object?>>[
        for (final target in targets)
          <String, Object?>{
            'target_id': target.targetId,
            'yaw_deg': target.yawDeg,
            'pitch_deg': target.pitchDeg,
            'ring': target.ringName,
            'capture_order': order[target.targetId],
          },
      ],
    };
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'planVersion': planVersion,
    'camera': camera.toJson(),
    'rings': rings.map((ring) => ring.toJson()).toList(),
    'targets': targets
        .map(
          (target) => <String, Object?>{
            'targetId': target.targetId,
            'yawDeg': target.yawDeg,
            'pitchDeg': target.pitchDeg,
            'ring': target.ringName,
          },
        )
        .toList(),
    'captureOrder': captureOrder,
    'metrics': metrics.toJson(),
    'notes': notes,
  };

  /// Rebuild a plan from its persisted form. Returns `null` when the payload is
  /// not a complete plan, so a corrupt row degrades to "no stored plan" rather
  /// than to a half-initialised capture.
  static AdaptiveSpherePlan? fromJson(Map<String, Object?> json) {
    final version = (json['planVersion'] as num?)?.toInt();
    final rawTargets = json['targets'];
    if (version == null || rawTargets is! List || rawTargets.isEmpty) {
      return null;
    }
    final cameraJson = json['camera'];
    final camera = cameraJson is Map
        ? SphereCameraProfile(
            imageWidth: (cameraJson['imageWidth'] as num?)?.toInt() ?? 3072,
            imageHeight: (cameraJson['imageHeight'] as num?)?.toInt() ?? 4096,
            focalPx: (cameraJson['focalPx'] as num?)?.toDouble() ?? 3214.7,
            principalXPx: (cameraJson['principalXPx'] as num?)?.toDouble() ?? 1536,
            principalYPx: (cameraJson['principalYPx'] as num?)?.toDouble() ?? 2048,
            source: cameraJson['source']?.toString() ?? 'assumed',
            confidence:
                (cameraJson['confidence'] as num?)?.toDouble() ?? 0.45,
          )
        : SphereCameraProfile.assumed();
    final targets = <SphereTargetSpec>[];
    for (final entry in rawTargets) {
      if (entry is! Map) continue;
      final id = (entry['targetId'] as num?)?.toInt();
      final yaw = (entry['yawDeg'] as num?)?.toDouble();
      final pitch = (entry['pitchDeg'] as num?)?.toDouble();
      final ring = entry['ring']?.toString();
      if (id == null || yaw == null || pitch == null || ring == null) {
        continue;
      }
      targets.add(
        SphereTargetSpec(
          targetId: id,
          yawDeg: yaw,
          pitchDeg: pitch,
          ringName: ring,
          direction: sphereDirection(yaw, pitch),
        ),
      );
    }
    if (targets.isEmpty) return null;
    targets.sort((a, b) => a.targetId.compareTo(b.targetId));
    final order = (json['captureOrder'] as List?)
            ?.map((value) => (value as num).toInt())
            .toList() ??
        targets.map((target) => target.targetId).toList();
    final rawRings = json['rings'];
    final rings = <PlanRingSpec>[
      if (rawRings is List)
        for (final entry in rawRings)
          if (entry is Map)
            PlanRingSpec(
              key: entry['key']?.toString() ?? 'ring',
              title: entry['title']?.toString() ?? 'Ring',
              pitchDeg: (entry['pitchDeg'] as num?)?.toDouble() ?? 0,
              yaws: (entry['yaws'] as List?)
                      ?.map((value) => (value as num).toDouble())
                      .toList() ??
                  const <double>[],
            ),
    ];
    return AdaptiveSpherePlan(
      planVersion: version,
      camera: camera,
      rings: rings,
      targets: List<SphereTargetSpec>.unmodifiable(targets),
      captureOrder: order,
      metrics: _metricsFromJson(json['metrics']),
      constraints: const PlanConstraints(),
      notes: (json['notes'] as List?)
              ?.map((value) => value.toString())
              .toList() ??
          const <String>[],
    );
  }

  static PlanMetrics _metricsFromJson(Object? raw) {
    final json = raw is Map ? raw : const <String, Object?>{};
    return PlanMetrics(
      singleCoverage: (json['singleCoverage'] as num?)?.toDouble() ?? 0,
      doubleCoverage: (json['doubleCoverage'] as num?)?.toDouble() ?? 0,
      minimumNeighbourOverlap:
          (json['minimumNeighbourOverlap'] as num?)?.toDouble() ?? 0,
      medianNeighbourOverlap:
          (json['medianNeighbourOverlap'] as num?)?.toDouble() ?? 0,
      minimumConnections: (json['minimumConnections'] as num?)?.toInt() ?? 0,
      connectedComponents:
          (json['connectedComponents'] as num?)?.toInt() ?? 1,
      isolatedTargets:
          (json['isolatedTargets'] as List?)
              ?.map((value) => (value as num).toInt())
              .toList() ??
          const <int>[],
      totalFootprintFraction:
          (json['totalFootprintFraction'] as num?)?.toDouble() ?? 0,
      gridCells: (json['gridCells'] as num?)?.toInt() ?? 0,
      resolutionDeg: (json['resolutionDeg'] as num?)?.toDouble() ?? 0,
    );
  }
}

/// The camera orientation whose optical axis is `sphereDirection(yaw, pitch)`.
///
/// Verified against the projection: `rotate(Vec3(0,0,-1))` returns
/// `sphereDirection(yaw, pitch)` exactly, which is the convention the live
/// overlay, the persisted manifest and the backend stitcher all share.
Quat sphereOrientation(double yawDeg, double pitchDeg) =>
    (Quat.axisAngle(-yawDeg, Vec3.unitY) * Quat.axisAngle(pitchDeg, Vec3.unitX))
        .normalized;

/// Angle between two unit directions, in degrees.
double angleBetweenDeg(Vec3 a, Vec3 b) {
  final dot = clampDouble(a.normalized.dot(b.normalized), -1, 1);
  return math.acos(dot) * radToDeg;
}

/// Shared spherical area of two frames, as a fraction of the smaller footprint.
///
/// The footprint is approximated as a spherical cap of the frame's diagonal
/// half-angle and the overlap is the lens area of the two caps. This is a
/// planning estimate; the capture-time coverage measurement projects the actual
/// image rectangle.
double footprintOverlap(
  SphereCameraProfile first,
  SphereCameraProfile second,
  double gapDeg,
) {
  final alpha = first.diagonalFovDeg * math.pi / 360;
  final beta = second.diagonalFovDeg * math.pi / 360;
  final gamma = gapDeg * math.pi / 180;
  if (gamma >= alpha + beta || alpha <= 0 || beta <= 0) return 0;
  final smaller = math.min(alpha, beta);
  final larger = math.max(alpha, beta);
  if (gamma <= larger - smaller) return 1;
  final cosA = clampDouble(
    (gamma * gamma + smaller * smaller - larger * larger) /
        (2 * gamma * smaller),
    -1,
    1,
  );
  final cosB = clampDouble(
    (gamma * gamma + larger * larger - smaller * smaller) /
        (2 * gamma * larger),
    -1,
    1,
  );
  final lens = smaller * smaller * math.acos(cosA) +
      larger * larger * math.acos(cosB) -
      0.5 *
          math.sqrt(math.max(
            0,
            (-gamma + smaller + larger) *
                (gamma + smaller - larger) *
                (gamma - smaller + larger) *
                (gamma + smaller + larger),
          ));
  final areaSmaller = math.pi * smaller * smaller;
  return clampDouble(lens / areaSmaller, 0, 1);
}

// ---------------------------------------------------------------------------
// Layout evaluation
// ---------------------------------------------------------------------------

/// Number of equal-area cells the planner measures coverage on.
///
/// 704 cells put the linear resolution near 7.7°, which is ample for planning:
/// a layout is only rejected when a *real* gap exists, and the capture-time
/// measurement in `sphere_coverage.dart` uses a much finer grid.
const int kPlanGridCells = 704;

List<Vec3>? _planGridCache;

/// Equal-area sampling of the sphere, uniform in z = sin(latitude).
List<Vec3> _planGrid() {
  final cached = _planGridCache;
  if (cached != null) return cached;
  final bands = math.max(4, (math.sqrt(2 * kPlanGridCells / math.pi)).round());
  final directions = <Vec3>[];
  for (var band = 0; band < bands; band++) {
    final z = -1.0 + (2.0 * band + 1.0) / bands;
    final ring = math.max(
      1,
      (2.0 * bands * math.sqrt(math.max(0.0, 1.0 - z * z))).round(),
    );
    for (var index = 0; index < ring; index++) {
      final phi = (index + 0.5) * (2 * math.pi / ring);
      final radial = math.sqrt(math.max(0.0, 1.0 - z * z));
      directions.add(Vec3(radial * math.cos(phi), z, radial * math.sin(phi)));
    }
  }
  _planGridCache = List<Vec3>.unmodifiable(directions);
  return _planGridCache!;
}

/// Coverage and connectivity of one candidate ring set.
PlanMetrics evaluateRings(
  List<PlanRingSpec> rings,
  SphereCameraProfile camera, {
  double minimumOverlap = 0.30,
}) {
  final grid = _planGrid();
  final poses = <(int, double, double, Quat)>[];
  var id = 0;
  for (final ring in rings) {
    for (final yaw in ring.yaws) {
      id++;
      poses.add((id, yaw, ring.pitchDeg, sphereOrientation(yaw, ring.pitchDeg)));
    }
  }
  final counts = List<int>.filled(grid.length, 0);
  for (final pose in poses) {
    final inverse = pose.$4.conjugate;
    for (var cell = 0; cell < grid.length; cell++) {
      final cameraFrame = inverse.rotate(grid[cell]);
      final depth = -cameraFrame.z;
      if (depth <= 1e-6) continue;
      if ((cameraFrame.x / depth).abs() > camera.halfWidthRatio) continue;
      if ((cameraFrame.y / depth).abs() > camera.halfHeightRatio) continue;
      counts[cell]++;
    }
  }
  final cells = grid.length;
  var covered = 0;
  var doubled = 0;
  for (final count in counts) {
    if (count >= 1) covered++;
    if (count >= 2) doubled++;
  }

  final connections = List<int>.filled(poses.length, 0);
  final adjacency = List<List<int>>.generate(poses.length, (_) => <int>[]);
  final overlaps = <double>[];
  for (var i = 0; i < poses.length; i++) {
    for (var j = i + 1; j < poses.length; j++) {
      final gap = angleBetweenDeg(
        sphereDirection(poses[i].$2, poses[i].$3),
        sphereDirection(poses[j].$2, poses[j].$3),
      );
      final overlap = footprintOverlap(camera, camera, gap);
      if (overlap < minimumOverlap) continue;
      overlaps.add(overlap);
      connections[i]++;
      connections[j]++;
      adjacency[i].add(j);
      adjacency[j].add(i);
    }
  }

  // Connected components over the overlap graph.
  final seen = List<bool>.filled(poses.length, false);
  var components = 0;
  for (var start = 0; start < poses.length; start++) {
    if (seen[start]) continue;
    components++;
    final stack = <int>[start];
    seen[start] = true;
    while (stack.isNotEmpty) {
      final node = stack.removeLast();
      for (final neighbour in adjacency[node]) {
        if (!seen[neighbour]) {
          seen[neighbour] = true;
          stack.add(neighbour);
        }
      }
    }
  }

  overlaps.sort();
  final isolated = <int>[
    for (var i = 0; i < poses.length; i++)
      if (connections[i] == 0) poses[i].$1,
  ];
  final resolution = math.sqrt(4 * math.pi / cells) * radToDeg;

  return PlanMetrics(
    singleCoverage: covered / cells,
    doubleCoverage: doubled / cells,
    minimumNeighbourOverlap: overlaps.isEmpty ? 0 : overlaps.first,
    medianNeighbourOverlap:
        overlaps.isEmpty ? 0 : overlaps[overlaps.length ~/ 2],
    minimumConnections: connections.isEmpty
        ? 0
        : connections.reduce(math.min),
    connectedComponents: components,
    isolatedTargets: isolated,
    totalFootprintFraction: poses.length * camera.sphereFraction,
    gridCells: cells,
    resolutionDeg: resolution,
  );
}

List<PlanRingSpec> _buildRings({
  required int yawCount,
  required int polarCount,
  required List<double> pitches,
  bool includePoles = false,
}) {
  final step = 360.0 / yawCount;
  final yaws = <double>[for (var i = 0; i < yawCount; i++) i * step];
  final polarStep = 360.0 / polarCount;
  final polarYaws = <double>[
    for (var i = 0; i < polarCount; i++) i * polarStep,
  ];
  final upperPitch = pitches[0];
  final upperRingPitch = pitches[1];
  final middlePitch = pitches[2];
  final lowerRingPitch = pitches[3];
  final lowerPitch = pitches[4];
  return <PlanRingSpec>[
    PlanRingSpec(
      key: 'upper_polar',
      title: 'Upper polar',
      pitchDeg: upperPitch,
      yaws: List<double>.unmodifiable(polarYaws),
    ),
    PlanRingSpec(
      key: 'upper',
      title: 'Upper',
      pitchDeg: upperRingPitch,
      yaws: List<double>.unmodifiable(yaws),
    ),
    PlanRingSpec(
      key: 'middle',
      title: 'Middle',
      pitchDeg: middlePitch,
      yaws: List<double>.unmodifiable(yaws),
    ),
    PlanRingSpec(
      key: 'lower',
      title: 'Lower',
      pitchDeg: lowerRingPitch,
      yaws: List<double>.unmodifiable(yaws),
    ),
    PlanRingSpec(
      key: 'lower_polar',
      title: 'Lower polar',
      pitchDeg: lowerPitch,
      yaws: List<double>.unmodifiable(polarYaws),
    ),
    if (includePoles)
      const PlanRingSpec(
        key: 'zenith',
        title: 'Ceiling',
        pitchDeg: 90,
        yaws: <double>[0],
      ),
    if (includePoles)
      const PlanRingSpec(
        key: 'nadir',
        title: 'Floor',
        pitchDeg: -90,
        yaws: <double>[0],
      ),
  ];
}

/// Build the connected-sector capture order for a ring set.
///
/// The order establishes horizontal and vertical alignment early: two
/// neighbouring middle frames first, then their upper and lower counterparts,
/// then a polar frame. Each later sector completes middle → upper → lower
/// before the next sector begins, reusing the middle frame the previous sector
/// already captured, and the polar caps are placed where they connect to the
/// upper/lower frames already on the sphere.
///
/// The reference 44-target layout produces exactly the specified sequence
/// (0°/0°, 30°/0°, 0°/+30°, 30°/+30°, 0°/+65°, 0°/−30°, 30°/−30°, 0°/−65°, …).
List<int> connectedCaptureOrder(List<PlanRingSpec> rings) {
  PlanRingSpec? ring(String key) {
    for (final entry in rings) {
      if (entry.key == key) return entry;
    }
    return null;
  }

  final upperPolar = ring('upper_polar');
  final upper = ring('upper');
  final middle = ring('middle');
  final lower = ring('lower');
  final lowerPolar = ring('lower_polar');
  final zenith = ring('zenith');
  final nadir = ring('nadir');

  // Target ids follow ring order: upper polar, upper, middle, lower, lower
  // polar, then the caps. The base offset of each ring is derived from that.
  var cursor = 0;
  final bases = <String, int>{};
  for (final entry in rings) {
    bases[entry.key] = cursor;
    cursor += entry.count;
  }
  int idOf(String key, int index) => bases[key]! + index + 1;

  final order = <int>[];
  final mainCount = middle?.count ?? 0;
  if (mainCount == 0) {
    // Degenerate layout: fall back to geometry order so the session is still
    // capturable rather than empty.
    return <int>[for (var i = 1; i <= cursor; i++) i];
  }

  final polarCount = upperPolar?.count ?? 0;
  final polarStep = polarCount > 0 ? math.max(1, mainCount ~/ polarCount) : 0;
  final usedUpperPolar = <int>{};
  final usedLowerPolar = <int>{};

  void addUpperPolar(int sector) {
    if (polarStep == 0 || upperPolar == null) return;
    if (sector % polarStep != 0) return;
    final index = sector ~/ polarStep;
    if (index >= polarCount) return;
    if (usedUpperPolar.add(index)) {
      order.add(idOf('upper_polar', index));
    }
  }

  void addLowerPolar(int sector) {
    if (polarStep == 0 || lowerPolar == null) return;
    if (sector % polarStep != 0) return;
    final index = sector ~/ polarStep;
    if (index >= polarCount) return;
    if (usedLowerPolar.add(index)) {
      order.add(idOf('lower_polar', index));
    }
  }

  // Sector 0 and 1: the two neighbouring middle frames, their upper and lower
  // counterparts, and the first polar pair. This is the seed the rest of the
  // graph grows from — horizontal and vertical alignment exist before the
  // photographer has turned a quarter of the way round.
  final seedSectors = math.min(2, mainCount);
  for (var sector = 0; sector < seedSectors; sector++) {
    order.add(idOf('middle', sector));
  }
  for (var sector = 0; sector < seedSectors; sector++) {
    if (upper != null) order.add(idOf('upper', sector));
  }
  if (upperPolar != null && polarCount > 0) {
    order.add(idOf('upper_polar', 0));
    usedUpperPolar.add(0);
  }
  for (var sector = 0; sector < seedSectors; sector++) {
    if (lower != null) order.add(idOf('lower', sector));
  }
  if (lowerPolar != null && polarCount > 0) {
    order.add(idOf('lower_polar', 0));
    usedLowerPolar.add(0);
  }

  // Each later sector completes middle → upper → (upper polar) → lower →
  // (lower polar). The polar frame is captured immediately after the ring it
  // overlaps, while the camera is already tilted in that direction, and before
  // the next sector moves it away.
  for (var sector = seedSectors; sector < mainCount; sector++) {
    order.add(idOf('middle', sector));
    if (upper != null) order.add(idOf('upper', sector));
    addUpperPolar(sector);
    if (lower != null) order.add(idOf('lower', sector));
    addLowerPolar(sector);
  }

  // Any polar position the sector sweep did not reach (a polar ring denser than
  // the sector stride) is captured while it still overlaps the upper/lower
  // frames already taken.
  if (upperPolar != null) {
    for (var index = 0; index < polarCount; index++) {
      if (usedUpperPolar.add(index)) order.add(idOf('upper_polar', index));
    }
  }
  if (lowerPolar != null) {
    for (var index = 0; index < polarCount; index++) {
      if (usedLowerPolar.add(index)) order.add(idOf('lower_polar', index));
    }
  }

  // Caps last: a zenith/nadir frame only exists when the rings below could not
  // reach the pole, so it is captured once everything it can connect to is on
  // the sphere.
  if (zenith != null) order.add(idOf('zenith', 0));
  if (nadir != null) order.add(idOf('nadir', 0));

  return List<int>.unmodifiable(order);
}

List<SphereTargetSpec> _targetsFor(List<PlanRingSpec> rings) {
  final targets = <SphereTargetSpec>[];
  for (final ring in rings) {
    for (var index = 0; index < ring.yaws.length; index++) {
      final yaw = ring.yaws[index];
      targets.add(
        SphereTargetSpec(
          targetId: targets.length + 1,
          yawDeg: yaw,
          pitchDeg: ring.pitchDeg,
          ringName: ring.key == 'upper_polar'
              ? 'Upper polar ring'
              : ring.key == 'upper'
              ? 'Upper ring'
              : ring.key == 'middle'
              ? 'Middle ring'
              : ring.key == 'lower'
              ? 'Lower ring'
              : ring.key == 'lower_polar'
              ? 'Lower polar ring'
              : ring.key == 'zenith'
              ? 'Zenith'
              : 'Nadir',
          indexInRing: ring.isCap ? null : index + 1,
          direction: sphereDirection(yaw, ring.pitchDeg),
        ),
      );
    }
  }
  return List<SphereTargetSpec>.unmodifiable(targets);
}

/// Generate the adaptive five-ring plan for [camera].
///
/// Evaluates the reference layout first — the common case, and the one the
/// specification fixes — then searches outward (more yaw positions, more polar
/// targets, adjusted pitch spacing, finally explicit pole caps) until a layout
/// satisfies [constraints]. Candidates that pass are ranked by target count, so
/// the result is the **lowest-count** layout that actually covers the sphere
/// rather than an arbitrary 36/40/44/56.
AdaptiveSpherePlan generateAdaptivePlan({
  SphereCameraProfile? camera,
  PlanConstraints constraints = const PlanConstraints(),
}) {
  final profile = camera ?? SphereCameraProfile.assumed();
  final notes = <String>[];

  AdaptiveSpherePlan build(
    List<PlanRingSpec> rings,
    PlanMetrics metrics,
    List<String> extraNotes,
  ) {
    final targets = _targetsFor(rings);
    return AdaptiveSpherePlan(
      planVersion: kAdaptiveSpherePlanVersion,
      camera: profile,
      rings: List<PlanRingSpec>.unmodifiable(rings),
      targets: targets,
      captureOrder: connectedCaptureOrder(rings),
      metrics: metrics,
      constraints: constraints,
      notes: List<String>.unmodifiable(extraNotes),
    );
  }

  // 1. The reference layout, exactly as specified.
  final referenceRings = _buildRings(
    yawCount: 12,
    polarCount: 4,
    pitches: const <double>[65, 30, 0, -30, -65],
  );
  final referenceMetrics = evaluateRings(
    referenceRings,
    profile,
    minimumOverlap: constraints.minimumOverlap,
  );
  if (referenceMetrics.satisfies(constraints)) {
    return build(referenceRings, referenceMetrics, const <String>[]);
  }

  // 2. Search: fewer targets first (the ranking is by count), then denser.
  final passing = <AdaptiveSpherePlan>[];
  final pitchLayouts = <List<double>>[
    const <double>[65, 30, 0, -30, -65],
    const <double>[70, 35, 0, -35, -70],
    const <double>[60, 28, 0, -28, -60],
  ];
  for (final pitches in pitchLayouts) {
    for (final yawCount in constraints.candidateYawCounts) {
      for (final polarCount in constraints.candidatePolarCounts) {
        final total = yawCount * 3 + polarCount * 2;
        if (total > constraints.maxTargets) continue;
        final rings = _buildRings(
          yawCount: yawCount,
          polarCount: polarCount,
          pitches: pitches,
        );
        final metrics = evaluateRings(
          rings,
          profile,
          minimumOverlap: constraints.minimumOverlap,
        );
        if (!metrics.satisfies(constraints)) continue;
        passing.add(build(rings, metrics, <String>[
          if (yawCount != 12)
            '$yawCount positions per main ring (${(360 / yawCount).toStringAsFixed(0)}° spacing) '
                'instead of 12, because this lens needs it.',
          if (polarCount != 4)
            '$polarCount polar positions instead of 4.',
          if (pitches[1] != 30)
            'Ring pitch ${pitches[1].toStringAsFixed(0)}° instead of 30°.',
        ]));
      }
    }
    if (passing.isNotEmpty) break;
  }

  if (passing.isNotEmpty) {
    // Rank by count first — the specification asks for the lowest practical
    // count — but a layout that only just clears the 30% overlap floor is a
    // worse panorama than one whose thinnest seam is already inside the
    // preferred 35–45% band, so that distinction outranks the count.
    int tier(AdaptiveSpherePlan plan) =>
        plan.metrics.minimumNeighbourOverlap >= constraints.preferredOverlapLow
        ? 0
        : 1;
    passing.sort((a, b) {
      final byTier = tier(a).compareTo(tier(b));
      if (byTier != 0) return byTier;
      final byCount = a.targetCount.compareTo(b.targetCount);
      if (byCount != 0) return byCount;
      return a.totalRotationDeg.compareTo(b.totalRotationDeg);
    });
    return passing.first;
  }

  // 3. Nothing satisfied the constraints: the lens is too narrow for ring
  // spacing alone, so add explicit pole caps and use the densest ring set.
  final yawCount = constraints.candidateYawCounts.reduce(math.max);
  final polarCount = constraints.candidatePolarCounts.reduce(math.max);
  final cappedRings = _buildRings(
    yawCount: yawCount,
    polarCount: polarCount,
    pitches: const <double>[65, 30, 0, -30, -65],
    includePoles: true,
  );
  final cappedMetrics = evaluateRings(
    cappedRings,
    profile,
    minimumOverlap: constraints.minimumOverlap,
  );
  notes.add(
    'The ring layout alone could not reach full coverage for this lens, so '
    'explicit ceiling and floor targets were added.',
  );
  return build(cappedRings, cappedMetrics, notes);
}

/// The default plan for the documented device camera.
///
/// Computed once and reused: the layout depends only on the intrinsics, which
/// are constant for a build.
final AdaptiveSpherePlan kAdaptiveSpherePlan = generateAdaptivePlan();
