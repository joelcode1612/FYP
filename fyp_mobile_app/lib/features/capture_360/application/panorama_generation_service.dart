import 'dart:io';

import 'package:shared_logic/shared_logic.dart';

import 'package:fyp/core/utils/capture_log.dart';
import 'package:fyp/features/capture_360/domain/services/target_sphere.dart';

/// Panorama generation orchestration: validates the saved frame sequence,
/// delegates stitching to the injected [PanoramaStitcher], records the
/// output on the tour record and surfaces honest stage progress.
///
/// Stateless by design: a retry re-runs validation and stitching against
/// whatever is on disk now, and nothing here deletes a photograph.
class PanoramaGenerationService {
  final PanoramaStitcher stitcher;
  final TourRepository tours;

  const PanoramaGenerationService(this.stitcher, this.tours);

  Future<StitchResult> generate({
    required String tourId,
    required List<CapturedFrame> frames,
    void Function(String stage)? onStage,
  }) async {
    onStage?.call('Validating frames...');
    final total = buildCaptureSphere().length;

    // Capture order is the stitch order: target ids 1…total, the sphere
    // sequence the shutter advanced through. The manifest is 0-based.
    final ordered = List<CapturedFrame>.of(frames)
      ..sort(
        (CapturedFrame a, CapturedFrame b) =>
            a.frameIndex.compareTo(b.frameIndex),
      );
    final seenIndexes = <int>{};
    for (final CapturedFrame frame in ordered) {
      if (frame.frameIndex < 0 || frame.frameIndex >= total) {
        return StitchResult.failure(
          'Capture frame ${frame.frameIndex} is outside the '
          '0–${total - 1} sequence.',
        );
      }
      if (!seenIndexes.add(frame.frameIndex)) {
        return StitchResult.failure(
          'Duplicate capture frame for target ${frame.frameIndex + 1}.',
        );
      }
      if (!await File(frame.imagePath).exists()) {
        return StitchResult.failure(
          'The saved photograph for target ${frame.frameIndex + 1} is '
          'missing on disk (${frame.imagePath}). Retake this target and try '
          'again.',
        );
      }
    }
    if (ordered.length < total) {
      final missing = <int>[
        for (var index = 0; index < total; index++)
          if (!seenIndexes.contains(index)) index + 1,
      ];
      final named = missing.take(6).join(', ');
      final more = missing.length > 6 ? ' (+${missing.length - 6} more)' : '';
      return StitchResult.failure(
        'Panorama cannot be generated. Only ${ordered.length}/$total '
        'photographs are saved. Missing targets: $named$more.',
      );
    }
    final paths = <String>[for (final frame in ordered) frame.imagePath];
    if (paths.toSet().length != paths.length) {
      return const StitchResult.failure(
        'Two capture frames point at one image file, so the frame set is not '
        'usable.',
      );
    }

    onStage?.call('Generating panorama...');
    CaptureLog.log('Starting panorama generation');
    final result = await stitcher.stitchFrames(paths, onStage: onStage);
    if (!result.success || result.panoramaPath == null) {
      CaptureLog.log('Panorama generation failed: ${result.message}');
      return result;
    }
    final tour = await tours.tourById(tourId);
    if (tour != null) {
      await tours.updateTour(
        tour.copyWith(
          panoramaPath: result.panoramaPath,
          status: VirtualTourStatus.ready,
        ),
      );
    }
    CaptureLog.log('Panorama generated');
    return result;
  }
}
