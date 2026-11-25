import 'dart:math' as math;
import 'dart:typed_data';

/// One downscaled grayscale analysis plane: the only pixel representation the
/// quality metrics touch. Pure Dart — no Flutter, no OpenCV — so every metric
/// below is asserted by the plain test suite against synthetic planes.
class GrayscalePlane {
  const GrayscalePlane({
    required this.width,
    required this.height,
    required this.luma,
  }) : assert(luma.length == width * height),
       assert(width > 0 && height > 0);

  final int width;
  final int height;
  final Uint8List luma;

  double at(int x, int y) => luma[y * width + x].toDouble();
}

/// Variance of the discrete Laplacian — the standard single-number focus
/// measure. Kernel `[0,1,0; 1,-4,1; 0,1,0]` over the interior pixels; the
/// variance of that response separates crisp texture (large spread) from a
/// defocused/motion-blurred rendition of the same scene (small spread).
///
/// Border pixels are excluded rather than padded: padding invents edges that
/// do not exist and the interior is statistically ample at analysis width.
double varianceOfLaplacian(GrayscalePlane plane) {
  if (plane.width < 3 || plane.height < 3) return 0;
  var sum = 0.0;
  var sumSquares = 0.0;
  var count = 0;
  for (var y = 1; y < plane.height - 1; y++) {
    final row = y * plane.width;
    for (var x = 1; x < plane.width - 1; x++) {
      final response =
          plane.luma[row + x - 1] +
          plane.luma[row + x + 1] +
          plane.luma[row - plane.width + x] +
          plane.luma[row + plane.width + x] -
          4 * plane.luma[row + x];
      sum += response;
      sumSquares += response * response;
      count++;
    }
  }
  if (count == 0) return 0;
  final mean = sum / count;
  return sumSquares / count - mean * mean;
}

/// Mean gradient magnitude via central differences (a Tenengrad-style focus
/// measure, scaled to the 0–255 luma range). Independent of the Laplacian:
/// it answers "how much local detail is present" where the Laplacian answers
/// "how wide is the response spread", so blur detection needs both.
double meanGradientMagnitude(GrayscalePlane plane) {
  if (plane.width < 3 || plane.height < 3) return 0;
  var total = 0.0;
  var count = 0;
  for (var y = 1; y < plane.height - 1; y++) {
    final row = y * plane.width;
    for (var x = 1; x < plane.width - 1; x++) {
      final gx = plane.luma[row + x + 1] - plane.luma[row + x - 1];
      final gy =
          plane.luma[row + plane.width + x] - plane.luma[row - plane.width + x];
      total += math.sqrt((gx * gx + gy * gy).toDouble()) / 2;
      count++;
    }
  }
  if (count == 0) return 0;
  return total / count;
}

/// Fraction of pixels whose gradient magnitude exceeds [threshold]. This is
/// the texture guard: a uniformly coloured wall or ceiling scores near zero
/// even when perfectly focused, which is exactly why blur verdicts are
/// suppressed on such scenes instead of falsely warning.
double edgeDensity(GrayscalePlane plane, {double threshold = 24.0}) {
  if (plane.width < 3 || plane.height < 3) return 0;
  var edges = 0;
  var count = 0;
  for (var y = 1; y < plane.height - 1; y++) {
    final row = y * plane.width;
    for (var x = 1; x < plane.width - 1; x++) {
      final gx = plane.luma[row + x + 1] - plane.luma[row + x - 1];
      final gy =
          plane.luma[row + plane.width + x] - plane.luma[row - plane.width + x];
      if (math.sqrt((gx * gx + gy * gy).toDouble()) / 2 > threshold) edges++;
      count++;
    }
  }
  if (count == 0) return 0;
  return edges / count;
}

/// Histogram statistics for exposure validation, computed from the same
/// analysis plane the blur metrics use.
class LumaStats {
  const LumaStats({
    required this.mean,
    required this.median,
    required this.clippedShadowFraction,
    required this.clippedHighlightFraction,
  });

  final double mean;
  final double median;
  final double clippedShadowFraction;
  final double clippedHighlightFraction;
}

/// Mean, median and clipped fractions over the full plane (borders included:
/// exposure is a whole-image property).
LumaStats lumaStats(
  GrayscalePlane plane, {
  required double shadowCeiling,
  required double highlightFloor,
}) {
  final histogram = List<int>.filled(256, 0);
  var sum = 0.0;
  var shadows = 0;
  var highlights = 0;
  for (final value in plane.luma) {
    histogram[value]++;
    sum += value;
    if (value <= shadowCeiling) shadows++;
    if (value >= highlightFloor) highlights++;
  }
  final total = plane.luma.length;
  if (total == 0) {
    return const LumaStats(
      mean: 0,
      median: 0,
      clippedShadowFraction: 0,
      clippedHighlightFraction: 0,
    );
  }
  final medianTarget = total / 2;
  var median = 0;
  var cumulative = 0;
  for (var value = 0; value < 256; value++) {
    cumulative += histogram[value];
    if (cumulative >= medianTarget) {
      median = value;
      break;
    }
  }
  return LumaStats(
    mean: sum / total,
    median: median.toDouble(),
    clippedShadowFraction: shadows / total,
    clippedHighlightFraction: highlights / total,
  );
}
