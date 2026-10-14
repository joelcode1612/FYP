import 'package:shared_logic/shared_logic.dart';

class OpenCvPanoramaStitcher implements PanoramaStitcher {
  @override
  Future<StitchResult> stitchFrames(
    List<String> imagePaths, {
    void Function(String stage)? onStage,
  }) async {
    if (imagePaths.isEmpty) {
      return const StitchResult.failure('No images to stitch.');
    }
    onStage?.call('Checking stitching support...');
    return const StitchResult.failure(
      'Panorama stitching requires native OpenCV, which is not available in '
      'the browser. Open this page on Android to generate a panorama.',
    );
  }
}

