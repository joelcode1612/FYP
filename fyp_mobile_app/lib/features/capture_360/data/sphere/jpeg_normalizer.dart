import 'dart:typed_data';

// The pure size/EXIF parsing lives in its own file so it is testable without
// any native library; it is re-exported for every existing importer.
import 'package:fyp/features/capture_360/data/sphere/jpeg_size.dart';
import 'package:fyp/features/capture_360/domain/sphere/normalized_jpeg.dart';
export 'package:fyp/features/capture_360/data/sphere/jpeg_size.dart'
    show exifOrientation, readJpegSize;
// `NormalizedJpeg` and `isFourThree` are pure value/geometry helpers. They live
// in `domain/normalized_jpeg.dart` so the capture controller and its session
// persistence can name the type without importing a native library; every
// existing importer keeps working through this re-export.
export 'package:fyp/features/capture_360/domain/sphere/normalized_jpeg.dart'
    show NormalizedJpeg, isFourThree;

/// Reports the photograph's real dimensions and keeps the bytes intact.
///
/// This is the OpenCV-free replacement for the previous 4:3 crop. The crop ran
/// `opencv_dart` decode/re-encode inside the capture loop — even moved to a
/// background isolate it loaded a second copy of the native library per
/// isolate, and the unresolved-native-symbol build failures it historically
/// caused made the dependency a standing risk. The reference capture
/// implementation treats the device's still as authoritative and records its
/// real geometry instead of rewriting it.
///
/// Most Android devices already return a 4:3 JPEG at `ResolutionPreset.max`
/// (the Xiaomi test device reports portrait 3072 × 4096, the same 4:3 frame
/// rotated 90°), in which case the bytes pass through untouched. A device that
/// returns another aspect keeps its original photograph — never stretched,
/// never cropped here — and the record carries the measured dimensions, the
/// source dimensions and the [NormalizedJpeg.warning] sentence. The backend
/// matcher and stitcher consume the recorded geometry and the plan's
/// intrinsics, so an uncropped frame is handled honestly rather than forced
/// into a ratio it does not have.
class JpegNormalizer {
  const JpegNormalizer({
    this.targetAspect = 4 / 3,
    this.aspectTolerance = 0.02,
  });

  final double targetAspect;

  /// How far the measured aspect may be from 4:3 before a warning is attached.
  final double aspectTolerance;

  Future<NormalizedJpeg> normalize(Uint8List bytes) async {
    final size = readJpegSize(bytes);
    if (size == null) {
      return NormalizedJpeg(
        bytes: bytes,
        width: 0,
        height: 0,
        warning:
            'The JPEG dimensions could not be read, so the frame geometry was '
            'recorded as unknown.',
      );
    }
    if (isFourThree(size.width, size.height, tolerance: aspectTolerance)) {
      return NormalizedJpeg(
        bytes: bytes,
        width: size.width,
        height: size.height,
      );
    }
    // Keep the photograph exactly as the sensor produced it. The backend
    // verifies overlap and coverage from the real pixels and the recorded
    // intrinsics, so an honest non-4:3 frame beats a lossy re-encode — and
    // nothing in the capture loop ever decodes a full-resolution still.
    return NormalizedJpeg(
      bytes: bytes,
      width: size.width,
      height: size.height,
      warning:
          'This device returned a ${size.width}×${size.height} still instead '
          'of a 4:3 frame. The original photograph was kept and its real '
          'geometry was recorded; coverage is verified from the actual pixels.',
    );
  }
}
