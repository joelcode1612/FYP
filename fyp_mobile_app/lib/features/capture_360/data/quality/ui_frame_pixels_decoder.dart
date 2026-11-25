import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:fyp/features/capture_360/domain/quality/frame_quality_analyzer.dart';
import 'package:fyp/features/capture_360/domain/quality/quality_metrics.dart';

/// Device JPEG decoder for the quality analyzer, built on dart:ui.
///
/// One decode pass, bounded to [maxWidth] on the long axis: the analyzer
/// needs blur and exposure evidence, not the full-resolution render, so the
/// cost of a per-photograph check stays in the low tens of milliseconds.
/// Decoding happens asynchronously on the platform's image pipeline; the
/// capture loop is never blocked by it.
class UiJpegFrameDecoder implements FramePixelsDecoder {
  const UiJpegFrameDecoder({this.maxWidth = 512});

  final int maxWidth;

  @override
  Future<DecodedFramePixels?> decode(Uint8List jpegBytes) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(jpegBytes);
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.FrameInfo? frameInfo;
    try {
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      final fullWidth = descriptor.width;
      final fullHeight = descriptor.height;
      if (fullWidth <= 0 || fullHeight <= 0) return null;
      final targetWidth = math.min(fullWidth, maxWidth);
      final targetHeight = (fullHeight * targetWidth / fullWidth).round().clamp(
        1,
        fullWidth,
      );
      codec = await descriptor.instantiateCodec(
        targetWidth: targetWidth,
        targetHeight: targetHeight,
      );
      frameInfo = await codec.getNextFrame();
      final byteData = await frameInfo.image.toByteData(
        format: ui.ImageByteFormat.rawStraightRgba,
      );
      if (byteData == null) return null;
      final pixels = byteData.buffer.asUint8List();
      final plane = Uint8List(targetWidth * targetHeight);
      for (var i = 0; i < plane.length; i++) {
        final r = pixels[i * 4];
        final g = pixels[i * 4 + 1];
        final b = pixels[i * 4 + 2];
        plane[i] = (0.299 * r + 0.587 * g + 0.114 * b).round().clamp(0, 255);
      }
      return DecodedFramePixels(
        width: fullWidth,
        height: fullHeight,
        luma: GrayscalePlane(
          width: targetWidth,
          height: targetHeight,
          luma: plane,
        ),
      );
    } on Object {
      // A corrupt or unsupported payload decodes to "unreadable" — the
      // analyzer turns that into the integrity finding. Nothing thrown.
      return null;
    } finally {
      frameInfo?.image.dispose();
      codec?.dispose();
      descriptor?.dispose();
      buffer.dispose();
    }
  }
}
