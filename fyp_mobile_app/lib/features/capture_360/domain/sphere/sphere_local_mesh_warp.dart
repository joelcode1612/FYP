// SITEWISE_QUALITY_MESH_V1
// Small, conservative local correction AFTER pose registration and the
// existing bounded affine adjustment. This is NOT unrestricted optical flow:
// a mesh with sparse, contradictory or concentrated matches is disabled.
// Source photographs are never modified and every shift is bounded.
import 'dart:math' as math;

class SphereWarpObservation {
  const SphereWarpObservation({
    required this.x,
    required this.y,
    required this.du,
    required this.dv,
  });

  /// Pixel location normalised to [-1, 1].
  final double x, y;

  /// Remaining alignment error in *registration decode* pixels.
  final double du, dv;
}

class SphereLocalMeshWarp {
  const SphereLocalMeshWarp._(this._du, this._dv);

  static const int columns = 5;
  static const int rows = 5;
  static const SphereLocalMeshWarp identity = SphereLocalMeshWarp._(
    <double>[],
    <double>[],
  );

  /// Displacements as fractions of the registration image dimensions.
  final List<double> _du, _dv;

  bool get isActive => _du.length == columns * rows;

  /// Only trust a local correction when many RANSAC-screened correspondences
  /// support it, cover enough image area, and improve the measured residual.
  static SphereLocalMeshWarp fit({
    required List<SphereWarpObservation> observations,
    required int registrationWidth,
    required int registrationHeight,
  }) {
    if (registrationWidth < 1 ||
        registrationHeight < 1 ||
        observations.length < 36) {
      return identity;
    }
    final points = <SphereWarpObservation>[
      for (final point in observations)
        if (point.x.isFinite &&
            point.y.isFinite &&
            point.du.isFinite &&
            point.dv.isFinite &&
            point.x.abs() <= 1.05 &&
            point.y.abs() <= 1.05 &&
            point.du.abs() <= 12 &&
            point.dv.abs() <= 12)
          point,
    ];
    if (points.length < 36) return identity;

    var minX = 1.0, maxX = -1.0, minY = 1.0, maxY = -1.0;
    for (final point in points) {
      minX = math.min(minX, point.x);
      maxX = math.max(maxX, point.x);
      minY = math.min(minY, point.y);
      maxY = math.max(maxY, point.y);
    }
    // Refuse a mesh fitted to one tiny foreground object or narrow corner.
    if (maxX - minX < 0.26 || maxY - minY < 0.32) return identity;

    final duGrid = List<double>.filled(columns * rows, 0);
    final dvGrid = List<double>.filled(columns * rows, 0);
    var supported = 0;
    for (var gy = 0; gy < rows; gy++) {
      final ny = -1.0 + 2.0 * gy / (rows - 1);
      for (var gx = 0; gx < columns; gx++) {
        final nx = -1.0 + 2.0 * gx / (columns - 1);
        var weight = 0.0;
        var sumU = 0.0;
        var sumV = 0.0;
        var nearby = 0;
        for (final point in points) {
          final dx = point.x - nx;
          final dy = point.y - ny;
          final d2 = dx * dx + dy * dy;
          if (d2 > 0.65 * 0.65) continue;
          nearby++;
          final w = math.exp(-d2 / (2.0 * 0.32 * 0.32));
          weight += w;
          sumU += w * point.du;
          sumV += w * point.dv;
        }
        if (nearby < 8 || weight < 1.0) continue;
        final cell = gy * columns + gx;
        // Clamp in registration pixels BEFORE normalizing. At 2048 output,
        // quarter-to-half decoding makes this at most ~8 output pixels.
        final duPx = (sumU / weight).clamp(-4.0, 4.0).toDouble();
        final dvPx = (sumV / weight).clamp(-4.0, 4.0).toDouble();
        duGrid[cell] = duPx / registrationWidth;
        dvGrid[cell] = dvPx / registrationHeight;
        supported++;
      }
    }
    if (supported < 5) return identity;
    final candidate = SphereLocalMeshWarp._(duGrid, dvGrid);

    // Avoid rubber-sheet distortions: neighbouring mesh nodes cannot differ
    // by more than ~4 registration pixels. Reject, don't blur or force them.
    for (var y = 0; y < rows; y++) {
      for (var x = 0; x < columns; x++) {
        final index = y * columns + x;
        if (x + 1 < columns) {
          final other = index + 1;
          if ((duGrid[index] - duGrid[other]).abs() * registrationWidth > 4.0 ||
              (dvGrid[index] - dvGrid[other]).abs() * registrationHeight >
                  4.0) {
            return identity;
          }
        }
        if (y + 1 < rows) {
          final other = index + columns;
          if ((duGrid[index] - duGrid[other]).abs() * registrationWidth > 4.0 ||
              (dvGrid[index] - dvGrid[other]).abs() * registrationHeight >
                  4.0) {
            return identity;
          }
        }
      }
    }

    var before = 0.0;
    var after = 0.0;
    var usable = 0;
    for (final point in points) {
      final u = (point.x + 1) * registrationWidth * 0.5;
      final v = (point.y + 1) * registrationHeight * 0.5;
      final shift = candidate.shiftAt(
        u: u,
        v: v,
        width: registrationWidth,
        height: registrationHeight,
        maxPx: 8.0,
      );
      if (shift.du.abs() < 0.01 && shift.dv.abs() < 0.01) continue;
      before += math.sqrt(point.du * point.du + point.dv * point.dv);
      after += math.sqrt(
        math.pow(point.du - shift.du, 2) + math.pow(point.dv - shift.dv, 2),
      );
      usable++;
    }
    if (usable < 24 || before < usable * 0.6 || after >= before * 0.82) {
      return identity;
    }
    return candidate;
  }

  ({double du, double dv}) shiftAt({
    required double u,
    required double v,
    required int width,
    required int height,
    double maxPx = 12.0,
  }) {
    if (!isActive ||
        width < 1 ||
        height < 1 ||
        !u.isFinite ||
        !v.isFinite ||
        u < 0 ||
        v < 0 ||
        u >= width ||
        v >= height) {
      return (du: 0.0, dv: 0.0);
    }
    final mx = (u / width * (columns - 1))
        .clamp(0.0, (columns - 1).toDouble())
        .toDouble();
    final my = (v / height * (rows - 1))
        .clamp(0.0, (rows - 1).toDouble())
        .toDouble();
    final x0 = math.min(columns - 2, mx.floor());
    final y0 = math.min(rows - 2, my.floor());
    final tx = mx - x0;
    final ty = my - y0;
    final i = y0 * columns + x0;
    double bilinear(List<double> a) =>
        a[i] * (1 - tx) * (1 - ty) +
        a[i + 1] * tx * (1 - ty) +
        a[i + columns] * (1 - tx) * ty +
        a[i + columns + 1] * tx * ty;
    // Smoothly fade at the outside image boundary rather than shearing pixels
    // at the edge into black space. No global Gaussian blur is applied.
    final edge = math
        .min(
          math.min(u / (width * 0.04), (width - u) / (width * 0.04)),
          math.min(v / (height * 0.04), (height - v) / (height * 0.04)),
        )
        .clamp(0.0, 1.0)
        .toDouble();
    final taper = edge * edge * (3.0 - 2.0 * edge);
    return (
      du:
          bilinear(_du).clamp(-maxPx / width, maxPx / width).toDouble() *
          width *
          taper,
      dv:
          bilinear(_dv).clamp(-maxPx / height, maxPx / height).toDouble() *
          height *
          taper,
    );
  }
}
