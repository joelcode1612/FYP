import 'package:shared_logic/shared_logic.dart';
import '../../core/utils/capture_log.dart';

/// Panorama generation orchestration: validates the 26-frame sequence,
/// delegates stitching to the injected [PanoramaStitcher], records the
/// output on the tour record and surfaces honest stage progress.

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
    if (frames.length < 26) {
      return StitchResult.failure(
        'Panorama cannot be generated. '
        'Only ${frames.length}/26 frames are captured.',
      );
    }
    final seen = <int>{};
    for (final f in frames) {
      if (!seen.add(f.frameIndex)) {
        return StitchResult.failure('Duplicate frame index ${f.frameIndex}.');
      }
    }
    onStage?.call('Generating panorama...');
    CaptureLog.log('Starting panorama generation');
    final result = await stitcher.stitchFrames([
      for (final f in frames) f.imagePath,
    ], onStage: onStage);
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
