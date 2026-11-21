/// Boundary for panorama generation. Implementations (e.g. on-device
/// OpenCV) report honest high-level stages — never faked percentages.
abstract class PanoramaStitcher {
  Future<StitchResult> stitchFrames(
    List<String> imagePaths, {
    void Function(String stage)? onStage,
  });
}

class StitchResult {
  final bool success;
  final String? panoramaPath;
  final String message;

  const StitchResult({
    required this.success,
    this.panoramaPath,
    required this.message,
  });

  const StitchResult.failure(this.message)
    : success = false,
      panoramaPath = null;
}
