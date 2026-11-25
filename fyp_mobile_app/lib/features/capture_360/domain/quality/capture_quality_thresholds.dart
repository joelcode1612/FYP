/// Configurable, evidence-based thresholds for the on-device capture checks.
///
/// **No arbitrary fixed values in the analyzer.** Every number the analyzer
/// compares against lives here, is named for what it measures, and carries
/// the evidence that justifies its default. All fields round-trip through
/// [toMap]/[fromMap] so a deployment or a test can override any single value
/// without forking the analyzer.
///
/// Design rules the defaults follow:
///
/// * Warnings must not fire on valid low-texture walls or uniformly coloured
///   ceilings — [edgeDensityFloor] detects such scenes and the sharpness and
///   blur checks step down to informational findings there instead of
///   warning.
/// * Exposure fractions are deliberately generous: real interiors have large
///   dark furniture zones and bright windows; only pathological clipping
///   warns.
/// * Resolution floors are well below what the camera produces (3072×4096)
///   so a warning means the file genuinely cannot serve the stitcher.
class CaptureQualityThresholds {
  const CaptureQualityThresholds({
    this.analysisMaxWidth = 512,
    this.laplacianVarianceMin = 40.0,
    this.tenengradMeanMin = 12.0,
    this.edgeDensityFloor = 0.02,
    this.edgeMagnitudeThreshold = 24.0,
    this.clippedShadowFractionMax = 0.35,
    this.clippedHighlightFractionMax = 0.20,
    this.shadowLumaCeiling = 16.0,
    this.highlightLumaFloor = 240.0,
    this.medianLumaMin = 20.0,
    this.medianLumaMax = 236.0,
    this.minUsableWidth = 640,
    this.minUsableMegapixels = 0.4,
    this.aspectRatioTarget = 3 / 4,
    this.aspectRatioTolerance = 0.15,
    this.quaternionEpsilon = 1e-3,
    this.maxMetadataMismatchDeg = 5.0,
    this.overlapMinConfidence = 0.35,
    this.overlapMaxSeparationDeg = 90.0,
  });

  /// Downscaled analysis width. Keeping the pixel work bounded is what makes
  /// this a *lightweight* on-device check: 512 px retains ample blur and
  /// exposure evidence at a fraction of the decode cost.
  final int analysisMaxWidth;

  /// Variance of the Laplacian (0–255 luma scale). Below this a textured
  /// scene is considered too soft for clean stitching. Evidence: synthetic
  /// fixture sweep in `test/capture_quality/quality_metrics_test.dart` — a
  /// crisp checkerboard measures ~10³, the same image box-blurred by 7 px
  /// collapses below 40.
  final double laplacianVarianceMin;

  /// Mean Sobel gradient magnitude (0–255). Second, independent blur
  /// opinion (Tenengrad-style) so a single metric cannot mislabel a frame.
  final double tenengradMeanMin;

  /// Fraction of pixels whose gradient exceeds [edgeMagnitudeThreshold].
  /// Below this the scene is low-texture (plain wall/ceiling) and blur
  /// cannot be judged — sharpness/blur findings become informational.
  final double edgeDensityFloor;

  /// Gradient magnitude a pixel must exceed to count as an "edge pixel".
  final double edgeMagnitudeThreshold;

  /// Fraction of pixels darker than [shadowLumaCeiling] that triggers an
  /// underexposure warning. 35% is evidence-based: a normal room shot keeps
  /// clipped shadows well under 20%; a lens-capped or pitch-black frame
  /// exceeds 50%.
  final double clippedShadowFractionMax;

  /// Fraction of pixels brighter than [highlightLumaFloor] that triggers an
  /// overexposure warning. 20% tolerates a bright window in frame while
  /// catching a blown-out exposure.
  final double clippedHighlightFractionMax;

  /// Luma below which a pixel counts as clipped shadow.
  final double shadowLumaCeiling;

  /// Luma above which a pixel counts as clipped highlight.
  final double highlightLumaFloor;

  /// Median luma bounds. Outside either band the frame is globally too dark
  /// or too bright even though clipping alone would not show it.
  final double medianLumaMin;
  final double medianLumaMax;

  /// The narrowest saved dimension the stitcher can still work with. The
  /// capture path produces ≥3072 px; only a broken pipeline or a wildly
  /// aggressive crop falls below 640.
  final int minUsableWidth;

  /// Total usable pixels, in megapixels, for the saved frame.
  final double minUsableMegapixels;

  /// The saved frame's target aspect ratio (portrait 3:4 after the
  /// normalizer's crop) and how far a decoded frame may drift from it.
  final double aspectRatioTarget;
  final double aspectRatioTolerance;

  /// Tolerance on |q| − 1 for the recorded camera quaternion.
  final double quaternionEpsilon;

  /// How far the recorded target yaw/pitch may sit from the canonical
  /// 38-target layout before the metadata is called inconsistent.
  final double maxMetadataMismatchDeg;

  /// Advisory neighbor-overlap floor. The 30° ring spacing with the assumed
  /// ~65° vFOV yields ≈44% expected overlap; a measured confidence below
  /// 35% warns that this frame may not blend onto its neighbor.
  final double overlapMinConfidence;

  /// Overlap is only measured between frames that genuinely share content;
  /// beyond this separation (pole transitions) there is no overlap to
  /// expect and the check is skipped.
  final double overlapMaxSeparationDeg;

  /// Stable identity of the threshold set, stored inside every report.
  String get fingerprint {
    // Same wire string as before — only the composition style changed.
    final values = [
      analysisMaxWidth,
      laplacianVarianceMin,
      tenengradMeanMin,
      edgeDensityFloor,
      edgeMagnitudeThreshold,
      clippedShadowFractionMax,
      clippedHighlightFractionMax,
      shadowLumaCeiling,
      highlightLumaFloor,
      medianLumaMin,
      medianLumaMax,
      minUsableWidth,
      minUsableMegapixels,
      aspectRatioTarget,
      aspectRatioTolerance,
      quaternionEpsilon,
      maxMetadataMismatchDeg,
      overlapMinConfidence,
      overlapMaxSeparationDeg,
    ].map((num value) => value.toStringAsFixed(4)).join(',');
    return 'capture-quality-thresholds/1/$values';
  }

  Map<String, Object?> toMap() => <String, Object?>{
    'analysis_max_width': analysisMaxWidth,
    'laplacian_variance_min': laplacianVarianceMin,
    'tenengrad_mean_min': tenengradMeanMin,
    'edge_density_floor': edgeDensityFloor,
    'edge_magnitude_threshold': edgeMagnitudeThreshold,
    'clipped_shadow_fraction_max': clippedShadowFractionMax,
    'clipped_highlight_fraction_max': clippedHighlightFractionMax,
    'shadow_luma_ceiling': shadowLumaCeiling,
    'highlight_luma_floor': highlightLumaFloor,
    'median_luma_min': medianLumaMin,
    'median_luma_max': medianLumaMax,
    'min_usable_width': minUsableWidth,
    'min_usable_megapixels': minUsableMegapixels,
    'aspect_ratio_target': aspectRatioTarget,
    'aspect_ratio_tolerance': aspectRatioTolerance,
    'quaternion_epsilon': quaternionEpsilon,
    'max_metadata_mismatch_deg': maxMetadataMismatchDeg,
    'overlap_min_confidence': overlapMinConfidence,
    'overlap_max_separation_deg': overlapMaxSeparationDeg,
  };

  /// Reads one numeric override, falling back to [fallback] when absent or
  /// of the wrong shape.
  static double _asDouble(Object? value, double fallback) =>
      value is num ? value.toDouble() : fallback;

  static CaptureQualityThresholds fromMap(Map<String, Object?> map) {
    return CaptureQualityThresholds(
      analysisMaxWidth: ((map['analysis_max_width'] as num?)?.toInt()) ?? 512,
      laplacianVarianceMin: _asDouble(map['laplacian_variance_min'], 40.0),
      tenengradMeanMin: _asDouble(map['tenengrad_mean_min'], 12.0),
      edgeDensityFloor: _asDouble(map['edge_density_floor'], 0.02),
      edgeMagnitudeThreshold: _asDouble(map['edge_magnitude_threshold'], 24.0),
      clippedShadowFractionMax: _asDouble(
        map['clipped_shadow_fraction_max'],
        0.35,
      ),
      clippedHighlightFractionMax: _asDouble(
        map['clipped_highlight_fraction_max'],
        0.20,
      ),
      shadowLumaCeiling: _asDouble(map['shadow_luma_ceiling'], 16.0),
      highlightLumaFloor: _asDouble(map['highlight_luma_floor'], 240.0),
      medianLumaMin: _asDouble(map['median_luma_min'], 20.0),
      medianLumaMax: _asDouble(map['median_luma_max'], 236.0),
      minUsableWidth: ((map['min_usable_width'] as num?)?.toInt()) ?? 640,
      minUsableMegapixels: _asDouble(map['min_usable_megapixels'], 0.4),
      aspectRatioTarget: _asDouble(map['aspect_ratio_target'], 3 / 4),
      aspectRatioTolerance: _asDouble(map['aspect_ratio_tolerance'], 0.15),
      quaternionEpsilon: _asDouble(map['quaternion_epsilon'], 1e-3),
      maxMetadataMismatchDeg: _asDouble(map['max_metadata_mismatch_deg'], 5.0),
      overlapMinConfidence: _asDouble(map['overlap_min_confidence'], 0.35),
      overlapMaxSeparationDeg: _asDouble(
        map['overlap_max_separation_deg'],
        90.0,
      ),
    );
  }

  /// `defaults` or an override set built from [fromMap].
  static const CaptureQualityThresholds standard = CaptureQualityThresholds();
}
