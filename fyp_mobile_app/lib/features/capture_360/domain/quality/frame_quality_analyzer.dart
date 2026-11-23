// Named parameters are deliberately not `this._field`: a private named
// parameter cannot be used by callers outside this library, so the public
// constructor reads `overlapProbe:` rather than `_overlapProbe:`.
// ignore_for_file: prefer_initializing_formals

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fyp/features/capture_360/domain/quality/capture_quality_models.dart';
import 'package:fyp/features/capture_360/domain/quality/capture_quality_thresholds.dart';
import 'package:fyp/features/capture_360/domain/quality/quality_metrics.dart';
import 'package:fyp/features/capture_360/domain/sphere/sphere_target.dart';
import 'package:fyp/features/capture_360/domain/virtual_tour/math/quaternions.dart';

/// Decodes a JPEG into the downscaled analysis plane the quality metrics
/// consume. The domain analyzer never touches dart:ui or OpenCV itself: the
/// device supplies a `UiJpegFrameDecoder`, tests supply a synthetic one. A
/// decoder that cannot read the bytes returns `null` — that IS the integrity
/// failure signal, and nothing is ever thrown past the caller.
abstract class FramePixelsDecoder {
  /// `null` when [jpegBytes] is not a readable image.
  Future<DecodedFramePixels?> decode(Uint8List jpegBytes);
}

class DecodedFramePixels {
  const DecodedFramePixels({
    required this.width,
    required this.height,
    required this.luma,
  });

  /// The FULL-SIZE decoded dimensions (before any analysis downscale), so the
  /// resolution check judges what was actually captured.
  final int width;
  final int height;
  final GrayscalePlane luma;
}

/// Advisory neighbor-overlap probe. Implemented with OpenCV ORB matching on
/// the device; tests substitute a deterministic fake. `null` means "overlap
/// could not be measured" (no native library, too few features) and is
/// reported as an informational finding, never a warning.
abstract class NeighborOverlapProbe {
  Future<double?> overlapConfidence({
    required Uint8List frame,
    required Uint8List neighbor,
    required double separationDeg,
  });
}

/// Everything one saved photograph needs for its quality verification.
class FrameQualityInput {
  const FrameQualityInput({
    required this.targetId,
    required this.jpegBytes,
    required this.recordedWidth,
    required this.recordedHeight,
    required this.targetYawDegrees,
    required this.targetPitchDegrees,
    required this.cameraOrientation,
    required this.alignmentErrorDeg,
    required this.toleranceDeg,
    this.neighborJpegBytes,
    this.neighborSeparationDeg,
  });

  final int targetId;
  final Uint8List jpegBytes;

  /// The dimensions the capture record claims, cross-checked against the
  /// decode.
  final int recordedWidth;
  final int recordedHeight;

  final double targetYawDegrees;
  final double targetPitchDegrees;
  final Quat cameraOrientation;
  final double alignmentErrorDeg;
  final double toleranceDeg;

  /// The adjacent frame's bytes, when one exists close enough to share
  /// content. Overlap is advisory and only measured when this is non-null.
  final Uint8List? neighborJpegBytes;
  final double? neighborSeparationDeg;
}

/// The per-photograph quality verification engine (requirements: sharpness +
/// blur, exposure, JPEG integrity/dimensions/resolution, orientation and
/// alignment metadata, advisory neighbor overlap).
///
/// What it never does: delete a photograph, re-arm the shutter, or tell the
/// capture loop to retake anything. Its only output is a
/// [FrameQualityReport]; the user alone decides what to do with a warning.
class FrameQualityAnalyzer {
  FrameQualityAnalyzer({
    required this.decoder,
    NeighborOverlapProbe? overlapProbe,
    this.thresholds = CaptureQualityThresholds.standard,
  }) : _overlapProbe = overlapProbe;

  final FramePixelsDecoder decoder;
  final NeighborOverlapProbe? _overlapProbe;
  final CaptureQualityThresholds thresholds;

  Future<FrameQualityReport> analyze(FrameQualityInput input) async {
    final findings = <QualityFinding>[];
    // ── 1. JPEG integrity (requirement: distinguish INVALID from warnings).
    final decoded = await _decode(input, findings);
    if (decoded == null) {
      return _verdict(input.targetId, findings);
    }

    // ── 2. Dimensions and usable resolution.
    _checkDimensions(input, decoded, findings);
    _checkResolution(input, decoded, findings);

    // ── 3. Sharpness and blur, guarded against low-texture scenes.
    _checkSharpnessAndBlur(decoded.luma, findings);

    // ── 4. Exposure: under, over and global brightness.
    _checkExposure(decoded.luma, findings);

    // ── 5. Orientation and alignment metadata consistency.
    _checkOrientationMetadata(input, findings);

    // ── 6. Advisory neighbor overlap, when a neighbor is available.
    await _checkNeighborOverlap(input, findings);

    return _verdict(input.targetId, findings);
  }

  Future<DecodedFramePixels?> _decode(
    FrameQualityInput input,
    List<QualityFinding> findings,
  ) async {
    // Cheap structural pre-check before paying for a decode attempt: the
    // JPEG SOI marker must be present. A truncated camera buffer frequently
    // has the marker but no data, so this is a fast filter, not the verdict.
    final bytes = input.jpegBytes;
    final hasSoi = bytes.length >= 3 && bytes[0] == 0xFF && bytes[1] == 0xD8;
    if (!hasSoi) {
      findings.add(
        const QualityFinding(
          check: QualityCheckId.jpegIntegrity,
          severity: QualitySeverity.critical,
          code: 'integrity_unreadable',
          message:
              'This file is not a readable photograph. Retake this target '
              'so the panorama has usable content.',
        ),
      );
      return null;
    }
    try {
      final result = await decoder.decode(bytes);
      if (result == null) {
        findings.add(
          const QualityFinding(
            check: QualityCheckId.jpegIntegrity,
            severity: QualitySeverity.critical,
            code: 'integrity_unreadable',
            message:
                'This photograph could not be decoded. It is kept on the '
                'device, but a retake is needed for the panorama.',
          ),
        );
        return null;
      }
      return result;
    } on Object {
      findings.add(
        const QualityFinding(
          check: QualityCheckId.jpegIntegrity,
          severity: QualitySeverity.critical,
          code: 'integrity_decoder_error',
          message:
              'Checking this photograph failed on the device. It is saved; '
              'a retake is recommended.',
        ),
      );
      return null;
    }
  }

  void _checkDimensions(
    FrameQualityInput input,
    DecodedFramePixels decoded,
    List<QualityFinding> findings,
  ) {
    final width = decoded.width;
    final height = decoded.height;
    if (width <= 0 || height <= 0) {
      findings.add(
        const QualityFinding(
          check: QualityCheckId.dimensions,
          severity: QualitySeverity.critical,
          code: 'dimensions_zero',
          message: 'The decoded photograph has no usable dimensions.',
        ),
      );
      return;
    }
    final ratio = width / math.max(height, 1);
    final target = thresholds.aspectRatioTarget;
    if ((ratio - target).abs() > thresholds.aspectRatioTolerance * target) {
      findings.add(
        QualityFinding(
          check: QualityCheckId.dimensions,
          severity: QualitySeverity.warning,
          code: 'dimensions_unexpected_aspect',
          message:
              'The photograph has an unusual shape (width/height '
              '${ratio.toStringAsFixed(2)}, expected about '
              '${target.toStringAsFixed(2)}). It is saved and still usable.',
          evidence: <String, double>{'measured_ratio': ratio, 'target_ratio': target},
        ),
      );
    }
    if (input.recordedWidth > 0 &&
        (input.recordedWidth != width || input.recordedHeight != height)) {
      findings.add(
        QualityFinding(
          check: QualityCheckId.dimensions,
          severity: QualitySeverity.info,
          code: 'dimensions_record_mismatch',
          message:
              'The saved record and the decoded file disagree about the '
              'image size.',
          evidence: <String, double>{
            'recorded_width': input.recordedWidth.toDouble(),
            'decoded_width': width.toDouble(),
          },
        ),
      );
    }
  }

  void _checkResolution(
    FrameQualityInput input,
    DecodedFramePixels decoded,
    List<QualityFinding> findings,
  ) {
    final width = decoded.width;
    final height = decoded.height;
    final megapixels = width * height / 1e6;
    final tooNarrow = math.min(width, height) < thresholds.minUsableWidth;
    if (tooNarrow || megapixels < thresholds.minUsableMegapixels) {
      findings.add(
        QualityFinding(
          check: QualityCheckId.resolution,
          severity: QualitySeverity.warning,
          code: 'resolution_insufficient',
          message:
              'This photograph has less resolution than the panorama needs '
              '($width×$height). Retaking it would improve the tour.',
          evidence: <String, double>{
            'width': width.toDouble(),
            'height': height.toDouble(),
            'megapixels': megapixels,
          },
        ),
      );
    }
  }

  void _checkSharpnessAndBlur(
    GrayscalePlane luma,
    List<QualityFinding> findings,
  ) {
    final laplacian = varianceOfLaplacian(luma);
    final tenengrad = meanGradientMagnitude(luma);
    final density = edgeDensity(
      luma,
      threshold: thresholds.edgeMagnitudeThreshold,
    );
    final evidence = <String, double>{
      'laplacian_variance': laplacian,
      'gradient_mean': tenengrad,
      'edge_density': density,
    };
    if (density < thresholds.edgeDensityFloor) {
      // Low-texture scene (plain wall / ceiling): blur cannot be judged from
      // a surface with no detail. Recorded as evidence, never as a warning —
      // this is the guard that keeps valid uniform scenes from false alarms.
      findings.add(
        QualityFinding(
          check: QualityCheckId.sharpness,
          severity: QualitySeverity.info,
          code: 'texture_low',
          message:
              'This direction has little surface detail, so sharpness could '
              'not be measured.',
          evidence: evidence,
        ),
      );
      return;
    }
    final soft = laplacian < thresholds.laplacianVarianceMin;
    final flat = tenengrad < thresholds.tenengradMeanMin;
    if (soft || flat) {
      findings.add(
        QualityFinding(
          check: QualityCheckId.blur,
          severity: QualitySeverity.warning,
          code: 'blur_low_sharpness',
          message:
              'This photograph looks soft or blurred. It is saved — you can '
              'retake it if the detail matters.',
          evidence: evidence,
        ),
      );
    }
  }

  void _checkExposure(GrayscalePlane luma, List<QualityFinding> findings) {
    final stats = lumaStats(
      luma,
      shadowCeiling: thresholds.shadowLumaCeiling,
      highlightFloor: thresholds.highlightLumaFloor,
    );
    final evidence = <String, double>{
      'median_luma': stats.median,
      'mean_luma': stats.mean,
      'clipped_shadow_fraction': stats.clippedShadowFraction,
      'clipped_highlight_fraction': stats.clippedHighlightFraction,
    };
    if (stats.clippedShadowFraction > thresholds.clippedShadowFractionMax) {
      findings.add(
        QualityFinding(
          check: QualityCheckId.exposure,
          severity: QualitySeverity.warning,
          code: 'exposure_underexposed',
          message:
              'This photograph is underexposed — a large part of it is very '
              'dark. It is saved; retake if the detail matters.',
          evidence: evidence,
        ),
      );
    }
    if (stats.clippedHighlightFraction > thresholds.clippedHighlightFractionMax) {
      findings.add(
        QualityFinding(
          check: QualityCheckId.exposure,
          severity: QualitySeverity.warning,
          code: 'exposure_overexposed',
          message:
              'This photograph is overexposed — bright areas are washed '
              'out. It is saved; retake if the detail matters.',
          evidence: evidence,
        ),
      );
    }
    if (stats.median < thresholds.medianLumaMin) {
      findings.add(
        QualityFinding(
          check: QualityCheckId.exposure,
          severity: QualitySeverity.warning,
          code: 'exposure_too_dark',
          message: 'This photograph is too dark overall. It is saved.',
          evidence: evidence,
        ),
      );
    } else if (stats.median > thresholds.medianLumaMax) {
      findings.add(
        QualityFinding(
          check: QualityCheckId.exposure,
          severity: QualitySeverity.warning,
          code: 'exposure_too_bright',
          message: 'This photograph is too bright overall. It is saved.',
          evidence: evidence,
        ),
      );
    }
  }

  void _checkOrientationMetadata(
    FrameQualityInput input,
    List<QualityFinding> findings,
  ) {
    final q = input.cameraOrientation;
    final norm = math.sqrt(
      q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w,
    );
    final finite =
        q.x.isFinite && q.y.isFinite && q.z.isFinite && q.w.isFinite;
    final evidence = <String, double>{
      'quaternion_norm': norm,
      'alignment_error_deg': input.alignmentErrorDeg,
    };
    if (!finite || (norm - 1).abs() > thresholds.quaternionEpsilon) {
      findings.add(
        QualityFinding(
          check: QualityCheckId.orientationMetadata,
          severity: QualitySeverity.critical,
          code: 'orientation_invalid_quaternion',
          message:
              'The recorded camera orientation for this target is invalid, '
              'so the panorama cannot place this frame correctly. A retake '
              'is required.',
          evidence: evidence,
        ),
      );
      return;
    }
    if (input.alignmentErrorDeg < 0 ||
        input.alignmentErrorDeg > 180 ||
        (input.toleranceDeg > 0 &&
            input.alignmentErrorDeg > input.toleranceDeg)) {
      findings.add(
        QualityFinding(
          check: QualityCheckId.orientationMetadata,
          severity: QualitySeverity.warning,
          code: 'alignment_outside_recorded_tolerance',
          message:
              'This frame was saved outside the usual alignment cone '
              '(${input.alignmentErrorDeg.toStringAsFixed(1)}°). It is kept; '
              'the panorama checks will confirm whether it blends.',
          evidence: evidence,
        ),
      );
    }
    // Cross-check the recorded target direction against the canonical
    // 38-target layout for this id — a stale or hand-edited record cannot
    // silently point at the wrong direction.
    SphereTargetSpec? spec;
    for (final candidate in buildSphereTargets()) {
      if (candidate.targetId == input.targetId) {
        spec = candidate;
        break;
      }
    }
    if (spec != null) {
      final yawDelta = (input.targetYawDegrees - spec.yawDeg).abs();
      final pitchDelta = (input.targetPitchDegrees - spec.pitchDeg).abs();
      if (yawDelta > thresholds.maxMetadataMismatchDeg ||
          pitchDelta > thresholds.maxMetadataMismatchDeg) {
        findings.add(
          QualityFinding(
            check: QualityCheckId.orientationMetadata,
            severity: QualitySeverity.warning,
            code: 'metadata_target_mismatch',
            message:
                'The recorded direction for target ${input.targetId} does '
                'not match the capture plan. The frame is kept.',
            evidence: <String, double>{
              'yaw_delta_deg': yawDelta,
              'pitch_delta_deg': pitchDelta,
            },
          ),
        );
      }
    }
  }

  Future<void> _checkNeighborOverlap(
    FrameQualityInput input,
    List<QualityFinding> findings,
  ) async {
    final probe = _overlapProbe;
    final neighbor = input.neighborJpegBytes;
    final separation = input.neighborSeparationDeg;
    if (probe == null || neighbor == null || separation == null) return;
    if (separation > thresholds.overlapMaxSeparationDeg) {
      // Pole transitions genuinely share (almost) nothing with their
      // predecessor; demanding overlap there would warn on every capture.
      return;
    }
    double? confidence;
    try {
      confidence = await probe.overlapConfidence(
        frame: input.jpegBytes,
        neighbor: neighbor,
        separationDeg: separation,
      );
    } on Object {
      confidence = null;
    }
    if (confidence == null) {
      findings.add(
        const QualityFinding(
          check: QualityCheckId.neighborOverlap,
          severity: QualitySeverity.info,
          code: 'overlap_unmeasured',
          message: 'Overlap with the neighbouring photograph could not be '
              'measured on this device.',
        ),
      );
      return;
    }
    if (confidence < thresholds.overlapMinConfidence) {
      findings.add(
        QualityFinding(
          check: QualityCheckId.neighborOverlap,
          severity: QualitySeverity.warning,
          code: 'overlap_low',
          message:
              'This frame shares less content with its neighbour than '
              'expected. It is saved; the panorama blending will confirm '
              'whether it works.',
          evidence: <String, double>{
            'confidence': confidence,
            'separation_deg': separation,
          },
        ),
      );
    }
  }

  FrameQualityReport _verdict(int targetId, List<QualityFinding> findings) {
    final hasCritical = findings.any(
      (finding) => finding.severity == QualitySeverity.critical,
    );
    final hasWarning = findings.any(
      (finding) => finding.severity == QualitySeverity.warning,
    );
    return FrameQualityReport(
      targetId: targetId,
      verdict: hasCritical
          ? QualityVerdict.invalid
          : hasWarning
          ? QualityVerdict.warning
          : QualityVerdict.accepted,
      findings: List<QualityFinding>.unmodifiable(findings),
      analyzedAtMs: DateTime.now().toUtc().millisecondsSinceEpoch,
      analyzerVersion: FrameQualityReport.kAnalyzerVersion,
      thresholdsVersion: thresholds.fingerprint,
    );
  }
}
