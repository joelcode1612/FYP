import 'dart:math' as math;

import 'package:fyp/features/capture_360/domain/virtual_tour/math/quaternions.dart';
import 'package:fyp/features/capture_360/domain/virtual_tour/math/scalars.dart';
import 'package:fyp/features/capture_360/domain/virtual_tour/math/vectors.dart';

// Spherical coverage measured from the photographs that were actually taken.
//
// ## Why not "targets captured / targets planned"
//
// A completed target list says the photographer pointed the phone at the right
// directions. It does not say the photographs cover the sphere: the lens could
// be narrower than assumed, the phone could have been tilted, or the session
// could have been resumed with a different reference heading. Coverage is
// therefore measured by projecting each photograph's rectangle onto the sphere
// and counting how many photographs see each sample of an equal-area grid.
//
// ## Equal area, not lat/lon
//
// Samples are uniform in z = sin(latitude), so every sample owns the same solid
// angle. A plain latitude/longitude raster over-weights the poles by
// 1/cos(latitude) and reports a polar gap as far larger than it is.
//
// ## Honesty
//
// `isComplete` is `uncovered == 0`, never `>= 0.995`. A sphere with an
// unsampled direction is not complete however small the gap, and the report
// carries its own resolution and tolerance so a figure is only ever quoted to
// the precision it was measured at.

/// One captured photograph, as the coverage measurement needs it.
class CoverageSample {
  const CoverageSample({
    required this.targetId,
    required this.orientation,
    required this.imageWidth,
    required this.imageHeight,
    required this.focalPx,
    this.principalXPx,
    this.principalYPx,
  });

  final int targetId;

  /// Device→world orientation at the moment of capture.
  final Quat orientation;

  /// Saved-image dimensions the intrinsics describe.
  final int imageWidth;
  final int imageHeight;
  final double focalPx;
  final double? principalXPx;
  final double? principalYPx;

  double get cx => principalXPx ?? imageWidth / 2;
  double get cy => principalYPx ?? imageHeight / 2;

  /// ``(W/2)/f`` — tangent of the horizontal half field of view.
  double get halfWidthRatio => (imageWidth / 2) / focalPx;
  double get halfHeightRatio => (imageHeight / 2) / focalPx;

  /// Exact solid angle of the image rectangle, in steradians.
  double get solidAngleSr {
    final a = halfWidthRatio;
    final b = halfHeightRatio;
    return 4 * math.asin((a * b) / math.sqrt(1 + a * a + b * b));
  }
}

/// A contiguous uncovered or thinly covered region.
class CoverageGap {
  const CoverageGap({
    required this.areaFraction,
    required this.centreLatitudeDeg,
    required this.centreLongitudeDeg,
    required this.latitudeSpanDeg,
    required this.longitudeSpanDeg,
    required this.cells,
  });

  final double areaFraction;
  final double centreLatitudeDeg;
  final double centreLongitudeDeg;
  final double latitudeSpanDeg;
  final double longitudeSpanDeg;
  final int cells;

  /// The camera direction that would fill this gap.
  (double yawDeg, double pitchDeg) get suggestedDirection =>
      (centreLongitudeDeg, centreLatitudeDeg);

  Map<String, Object?> toJson() => <String, Object?>{
    'areaFraction': areaFraction,
    'centreLatitudeDeg': centreLatitudeDeg,
    'centreLongitudeDeg': centreLongitudeDeg,
    'latitudeSpanDeg': latitudeSpanDeg,
    'longitudeSpanDeg': longitudeSpanDeg,
    'cells': cells,
  };
}

/// Coverage, seam band and pole completeness for one session.
class SphereCoverageReport {
  const SphereCoverageReport({
    required this.single,
    required this.doubleCoverage,
    required this.triple,
    required this.uncovered,
    required this.largestGap,
    required this.gaps,
    required this.thinRegions,
    required this.upperHemisphere,
    required this.lowerHemisphere,
    required this.zenith,
    required this.nadir,
    required this.horizonBand,
    required this.gridCells,
    required this.resolutionDeg,
    required this.tolerance,
    required this.perTarget,
    required this.sampledFrames,
  });

  final double single;
  final double doubleCoverage;
  final double triple;
  final double uncovered;
  final CoverageGap? largestGap;
  final List<CoverageGap> gaps;
  final List<CoverageGap> thinRegions;
  final double upperHemisphere;
  final double lowerHemisphere;
  final double zenith;
  final double nadir;
  final double horizonBand;
  final int gridCells;
  final double resolutionDeg;
  final double tolerance;
  final Map<int, double> perTarget;
  final int sampledFrames;

  /// True only when every sampled direction is covered.
  bool get isComplete => uncovered == 0;

  /// Whether there is a real seam band everywhere.
  bool get hasSeamBand => doubleCoverage >= 0.95;

  /// `complete`, `nearly_complete`, `incomplete` or `empty`.
  String get state {
    if (sampledFrames == 0) return 'empty';
    if (uncovered > 0.005) return 'incomplete';
    if (uncovered > 0) return 'nearly_complete';
    if (doubleCoverage < 0.95) return 'complete_thin_seams';
    return 'complete';
  }

  /// A short sentence for the capture screen. Never claims more than measured.
  String get summary {
    if (sampledFrames == 0) return 'No photographs measured yet.';
    final covered = (single * 100).toStringAsFixed(1);
    final doubled = (doubleCoverage * 100).toStringAsFixed(1);
    if (isComplete) {
      return '$covered% of the sphere covered, $doubled% with two photographs.';
    }
    final missing = (uncovered * 100).toStringAsFixed(1);
    return '$covered% of the sphere covered — $missing% still missing.';
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'single': single,
    'double': doubleCoverage,
    'triple': triple,
    'uncovered': uncovered,
    'state': state,
    'largestGap': largestGap?.toJson(),
    'gaps': gaps.take(8).map((gap) => gap.toJson()).toList(),
    'thinRegions': thinRegions.take(8).map((gap) => gap.toJson()).toList(),
    'upperHemisphere': upperHemisphere,
    'lowerHemisphere': lowerHemisphere,
    'zenith': zenith,
    'nadir': nadir,
    'horizonBand': horizonBand,
    'gridCells': gridCells,
    'resolutionDeg': resolutionDeg,
    'tolerance': tolerance,
    'sampledFrames': sampledFrames,
    'perTarget': {
      for (final entry in perTarget.entries) '${entry.key}': entry.value,
    },
  };
}

/// Default sampling for the live readout: 2 304 cells, ≈2.4° resolution.
///
/// Fine enough that a 5° gap cannot hide, coarse enough to run after every
/// accepted photograph without stalling the camera preview.
const int kLiveCoverageCells = 2304;

/// Sampling for the completion check: 9 216 cells, ≈1.2° resolution.
const int kFinalCoverageCells = 9216;

/// Latitude band reported as "ceiling" / "floor".
const double kPoleBandDeg = 75;

/// Latitude band whose coverage decides horizontal loop continuity.
const double kHorizonBandDeg = 20;

/// Resolution of the connectivity raster used for the largest-gap analysis.
///
/// 2° keeps the analysis to ~16 000 cells. It is only ever run when the sphere
/// is genuinely incomplete, so the cost is paid once per session rather than
/// after every photograph.
const double kGapRasterStepDeg = 2.0;

final Map<int, List<Vec3>> _gridCache = <int, List<Vec3>>{};

/// Equal-area sampling of the sphere, uniform in z = sin(latitude).
List<Vec3> _coverageGrid(int cells) {
  final cached = _gridCache[cells];
  if (cached != null) return cached;
  final bands = math.max(4, (math.sqrt(2 * cells / math.pi)).round());
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
  final resolved = List<Vec3>.unmodifiable(directions);
  _gridCache[cells] = resolved;
  return resolved;
}

/// Measure coverage over [samples].
///
/// [samples] should be the photographs whose orientation is known; a frame
/// without a usable pose is not measured and is not counted, because assuming
/// a pose would fabricate coverage.
SphereCoverageReport measureSphereCoverage(
  List<CoverageSample> samples, {
  int cells = kLiveCoverageCells,
}) {
  final grid = _coverageGrid(cells);
  final counts = List<int>.filled(grid.length, 0);
  final perTarget = <int, double>{};

  for (final sample in samples) {
    final inverse = sample.orientation.conjugate;
    var visible = 0;
    for (var cell = 0; cell < grid.length; cell++) {
      final cameraFrame = inverse.rotate(grid[cell]);
      final depth = -cameraFrame.z;
      if (depth <= 1e-6) continue;
      if ((cameraFrame.x / depth).abs() > sample.halfWidthRatio) continue;
      if ((cameraFrame.y / depth).abs() > sample.halfHeightRatio) continue;
      counts[cell]++;
      visible++;
    }
    perTarget[sample.targetId] = visible / grid.length;
  }

  var covered = 0;
  var doubled = 0;
  var tripled = 0;
  for (final count in counts) {
    if (count >= 1) covered++;
    if (count >= 2) doubled++;
    if (count >= 3) tripled++;
  }
  final total = grid.length;

  var upper = 0, upperCovered = 0;
  var lower = 0, lowerCovered = 0;
  var pole = 0, poleCovered = 0;
  var floor = 0, floorCovered = 0;
  var horizon = 0, horizonCovered = 0;
  for (var cell = 0; cell < total; cell++) {
    final z = grid[cell].y;
    final latitude = math.asin(clampDouble(z, -1, 1)) * radToDeg;
    if (latitude > 0) {
      upper++;
      if (counts[cell] >= 1) upperCovered++;
    } else if (latitude < 0) {
      lower++;
      if (counts[cell] >= 1) lowerCovered++;
    }
    if (latitude >= kPoleBandDeg) {
      pole++;
      if (counts[cell] >= 1) poleCovered++;
    }
    if (latitude <= -kPoleBandDeg) {
      floor++;
      if (counts[cell] >= 1) floorCovered++;
    }
    if (latitude.abs() <= kHorizonBandDeg) {
      horizon++;
      if (counts[cell] >= 1) horizonCovered++;
    }
  }

  // The connectivity raster costs an order of magnitude more than the count
  // above, so it only runs when there is something to analyse. A complete
  // sphere reports no gaps rather than paying to prove it.
  final complete = covered == total;
  final raster = complete ? null : _gapRaster(samples);
  final gaps = raster == null
      ? const <CoverageGap>[]
      : _regions(raster.counts, raster.areas, raster.latitudes, 0);
  final thin = raster == null
      ? const <CoverageGap>[]
      : _regions(raster.counts, raster.areas, raster.latitudes, 1);

  return SphereCoverageReport(
    single: covered / total,
    doubleCoverage: doubled / total,
    triple: tripled / total,
    uncovered: (total - covered) / total,
    largestGap: gaps.isEmpty ? null : gaps.first,
    gaps: gaps,
    thinRegions: thin,
    upperHemisphere: upper == 0 ? 0 : upperCovered / upper,
    lowerHemisphere: lower == 0 ? 0 : lowerCovered / lower,
    zenith: pole == 0 ? 0 : poleCovered / pole,
    nadir: floor == 0 ? 0 : floorCovered / floor,
    horizonBand: horizon == 0 ? 0 : horizonCovered / horizon,
    gridCells: total,
    resolutionDeg: math.sqrt(4 * math.pi / total) * radToDeg,
    tolerance: 1 / total,
    perTarget: perTarget,
    sampledFrames: samples.length,
  );
}

class _GapRaster {
  const _GapRaster(this.counts, this.areas, this.latitudes);
  final List<int> counts;
  final List<double> areas;
  final List<double> latitudes;
}

/// Coverage counts on a regular lat/lon raster, used only for connectivity.
_GapRaster _gapRaster(List<CoverageSample> samples) {
  final step = kGapRasterStepDeg;
  final rows = (180 / step).round();
  final columns = (360 / step).round();
  final counts = List<int>.filled(rows * columns, 0);
  final areas = List<double>.filled(rows * columns, 0);
  final latitudes = List<double>.filled(rows, 0);
  final directions = _gapDirections(rows, columns, step);

  for (var row = 0; row < rows; row++) {
    final latitudeDeg = -90 + (row + 0.5) * step;
    latitudes[row] = latitudeDeg;
    final latitude = latitudeDeg * degToRad;
    final cosLat = math.cos(latitude);
    final area = cosLat * (step * degToRad) * (step * degToRad);
    final base = row * columns;
    for (var column = 0; column < columns; column++) {
      areas[base + column] = area;
    }
  }

  for (final sample in samples) {
    final inverse = sample.orientation.conjugate;
    final qx = inverse.x;
    final qy = inverse.y;
    final qz = inverse.z;
    final qw = inverse.w;
    for (var index = 0; index < counts.length; index++) {
      // Inline q·v·q⁻¹: the previous loop allocated a Vec3 per cell per
      // sample — over 600k short-lived objects by the 38th frame, which
      // produced exactly the GC stalls seen in the ANR trace.
      final vx = directions[index].x;
      final vy = directions[index].y;
      final vz = directions[index].z;
      final cx = qy * vz - qz * vy;
      final cy = qz * vx - qx * vz;
      final cz = qx * vy - qy * vx;
      final ccx = qy * cz - qz * cy;
      final ccy = qz * cx - qx * cz;
      final ccz = qx * cy - qy * cx;
      final rx = vx + 2 * (qw * cx + ccx);
      final ry = vy + 2 * (qw * cy + ccy);
      final rz = vz + 2 * (qw * cz + ccz);
      final depth = -rz;
      if (depth <= 1e-6) continue;
      if ((rx / depth).abs() > sample.halfWidthRatio) continue;
      if ((ry / depth).abs() > sample.halfHeightRatio) continue;
      counts[index]++;
    }
  }
  return _GapRaster(counts, areas, latitudes);
}

/// Cached unit directions for the gap raster. The grid is fixed for a given
/// step, so building it once removes 16k trig calls and Vec3 allocations from
/// every coverage pass.
final Map<int, List<Vec3>> _gapDirectionCache = <int, List<Vec3>>{};

List<Vec3> _gapDirections(int rows, int columns, double step) {
  final key = (rows * 100000 + columns) * 1000 + step.round();
  final cached = _gapDirectionCache[key];
  if (cached != null) return cached;
  final directions = List<Vec3>.filled(rows * columns, Vec3.zero);
  for (var row = 0; row < rows; row++) {
    final latitude = (-90 + (row + 0.5) * step) * degToRad;
    final cosLat = math.cos(latitude);
    final sinLat = math.sin(latitude);
    final base = row * columns;
    for (var column = 0; column < columns; column++) {
      final longitude = (-180 + (column + 0.5) * step) * degToRad;
      directions[base + column] = Vec3(
        cosLat * math.cos(longitude),
        sinLat,
        cosLat * math.sin(longitude),
      );
    }
  }
  _gapDirectionCache[key] = directions;
  return directions;
}

/// Connected components of the cells whose count equals [target].
List<CoverageGap> _regions(
  List<int> counts,
  List<double> areas,
  List<double> latitudes,
  int target, {
  int limit = 8,
}) {
  const step = kGapRasterStepDeg;
  final rows = latitudes.length;
  final columns = (360 / step).round();
  final totalArea = areas.fold<double>(0, (sum, value) => sum + value);
  if (totalArea <= 0) return const <CoverageGap>[];

  final visited = List<bool>.filled(counts.length, false);
  final regions = <CoverageGap>[];
  for (var row = 0; row < rows; row++) {
    for (var column = 0; column < columns; column++) {
      final start = row * columns + column;
      if (counts[start] != target || visited[start]) continue;
      final stack = <int>[start];
      visited[start] = true;
      final cells = <int>[];
      var area = 0.0;
      while (stack.isNotEmpty) {
        final index = stack.removeLast();
        cells.add(index);
        area += areas[index];
        final r = index ~/ columns;
        final c = index % columns;
        for (var dr = -1; dr <= 1; dr++) {
          for (var dc = -1; dc <= 1; dc++) {
            if (dr == 0 && dc == 0) continue;
            final nr = r + dr;
            final nc = (c + dc + columns) % columns; // longitude wraps
            if (nr < 0 || nr >= rows) continue;
            final neighbour = nr * columns + nc;
            if (counts[neighbour] != target || visited[neighbour]) continue;
            visited[neighbour] = true;
            stack.add(neighbour);
          }
        }
      }
      if (cells.isEmpty) continue;
      var minLat = double.infinity, maxLat = -double.infinity;
      var minLon = double.infinity, maxLon = -double.infinity;
      for (final index in cells) {
        final lat = latitudes[index ~/ columns];
        final lon = (index % columns + 0.5) * step - 180;
        minLat = math.min(minLat, lat);
        maxLat = math.max(maxLat, lat);
        minLon = math.min(minLon, lon);
        maxLon = math.max(maxLon, lon);
      }
      // A region that straddles ±180° has a longitude span near 360; the
      // centre is then taken from the unwrapped midpoint so it stays sane.
      var centreLon = (minLon + maxLon) / 2;
      var spanLon = maxLon - minLon;
      if (spanLon > 180) {
        centreLon = ((minLon + 360 + maxLon) / 2) % 360;
        if (centreLon > 180) centreLon -= 360;
        spanLon = 360 - spanLon;
      }
      regions.add(
        CoverageGap(
          areaFraction: area / totalArea,
          centreLatitudeDeg: (minLat + maxLat) / 2,
          centreLongitudeDeg: centreLon,
          latitudeSpanDeg: maxLat - minLat + step,
          longitudeSpanDeg: spanLon + step,
          cells: cells.length,
        ),
      );
    }
  }
  regions.sort((a, b) => b.areaFraction.compareTo(a.areaFraction));
  return regions.take(limit).toList();
}

/// A target worth adding because the measured coverage has a genuine hole.
class GapTargetSuggestion {
  const GapTargetSuggestion({
    required this.yawDeg,
    required this.pitchDeg,
    required this.reason,
    required this.areaFraction,
  });

  final double yawDeg;
  final double pitchDeg;
  final String reason;
  final double areaFraction;
}

/// Additional capture directions for the uncovered regions of [report].
///
/// A hole smaller than [minimumAreaFraction] is not worth another photograph:
/// adding targets for it would trade a real capture for a cosmetic figure. The
/// caller shows these as optional extra targets, never as a retake.
List<GapTargetSuggestion> suggestGapTargets(
  SphereCoverageReport report, {
  double minimumAreaFraction = 0.0015,
  int limit = 4,
}) {
  final suggestions = <GapTargetSuggestion>[];
  for (final gap in report.gaps) {
    if (gap.areaFraction < minimumAreaFraction) continue;
    final (yaw, pitch) = gap.suggestedDirection;
    suggestions.add(
      GapTargetSuggestion(
        yawDeg: yaw,
        pitchDeg: pitch,
        reason:
            '${(gap.areaFraction * 100).toStringAsFixed(1)}% of the sphere near '
            '${pitch.round()}° elevation is uncovered.',
        areaFraction: gap.areaFraction,
      ),
    );
    if (suggestions.length >= limit) break;
  }
  return suggestions;
}

/// Whether a direct ceiling or floor photograph is needed.
///
/// Only when the polar ring genuinely fails to reach the pole — never as a
/// routine extra shot.
bool needsPoleCap(SphereCoverageReport report, {bool ceiling = true}) =>
    (ceiling ? report.zenith : report.nadir) < 0.999;
