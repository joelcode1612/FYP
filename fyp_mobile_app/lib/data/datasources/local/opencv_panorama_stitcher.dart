import 'package:shared_logic/shared_logic.dart';
import 'dart:io';

import 'package:opencv_dart/opencv_dart.dart' as cv;


/// On-device panorama generation with OpenCV's [Stitcher] (PANORAMA mode).
/// Reports honest high-level stages; every failure preserves the source
/// frames and names the failing stage.

class OpenCvPanoramaStitcher implements PanoramaStitcher {
  @override
  Future<StitchResult> stitchFrames(
    List<String> imagePaths, {
    void Function(String stage)? onStage,
  }) async {
    if (imagePaths.isEmpty) {
      return const StitchResult.failure('No images to stitch.');
    }
    final mats = <cv.Mat>[];
    try {
      onStage?.call('Preparing images...');
      for (var i = 0; i < imagePaths.length; i++) {
        onStage?.call('Processing image ${i + 1}/${imagePaths.length}...');
        final path = imagePaths[i];
        if (!await File(path).exists()) {
          return StitchResult.failure('Frame file is missing: $path.');
        }
        final mat = cv.imread(path, flags: cv.IMREAD_COLOR);
        if (mat.isEmpty) {
          return StitchResult.failure('Frame could not be decoded: $path.');
        }
        mats.add(mat);
      }

      onStage?.call('Generating panorama...');
      final stitcher = cv.Stitcher.create(mode: cv.StitcherMode.PANORAMA);
      final vec = cv.VecMat.fromList(mats);
      try {
        final (status, pano) = await stitcher.stitchAsync(vec);
        if (status != cv.StitcherStatus.OK || pano.isEmpty) {
          return StitchResult.failure(
            'Stitching failed (${status.name}). Keep the frames and retry, '
            'or retake frames with more overlap.',
          );
        }
        onStage?.call('Finalizing panorama...');
        final dir = File(imagePaths.first).parent.parent.path;
        final outPath = '$dir/panorama.jpg';
        final ok = await cv.imwriteAsync(outPath, pano);
        pano.dispose();
        if (!ok || !await File(outPath).exists()) {
          return const StitchResult.failure(
            'Panorama rendered but could not be saved.',
          );
        }
        final size = await File(outPath).length();
        if (size == 0) {
          return const StitchResult.failure(
            'Panorama file is empty after stitching.',
          );
        }
        return StitchResult(
          success: true,
          panoramaPath: outPath,
          message: 'Panorama generated successfully.',
        );
      } finally {
        vec.dispose();
      }
    } catch (e) {
      return StitchResult.failure('Stitching error: $e');
    } finally {
      for (final m in mats) {
        m.dispose();
      }
    }
  }
}
