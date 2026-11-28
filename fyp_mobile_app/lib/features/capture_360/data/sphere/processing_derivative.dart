import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;

import 'package:fyp/features/capture_360/data/sphere/jpeg_size.dart';

/// The scaled copy of a photograph that is uploaded for processing.
///
/// The original is never modified, moved or deleted: this file is written next
/// to it and the upload queue sends *this* one. Everything the stitcher needs
/// to interpret it travels with it — the pixel dimensions and the exact scale
/// factor relative to the saved original — so the server can rescale the
/// intrinsics instead of assuming the upload is full resolution.
@immutable
class ProcessingDerivative {
  const ProcessingDerivative({
    required this.path,
    required this.width,
    required this.height,
    required this.scale,
    required this.byteLength,
  });

  /// Absolute path of the derivative JPEG on this device.
  final String path;

  /// Pixel dimensions of the derivative, as written.
  final int width;
  final int height;

  /// Derivative pixels per saved-original pixel. `1.0` means "no reduction",
  /// which the encoder never produces — it returns `null` in that case so the
  /// caller uploads the original rather than a pointless copy.
  final double scale;

  final int byteLength;

  Map<String, Object?> toJson() => <String, Object?>{
    'path': path,
    'width': width,
    'height': height,
    'scale': scale,
    'bytes': byteLength,
  };

  static ProcessingDerivative? fromJson(Object? json) {
    if (json is! Map) return null;
    final path = json['path'];
    final width = (json['width'] as num?)?.toInt();
    final height = (json['height'] as num?)?.toInt();
    final scale = (json['scale'] as num?)?.toDouble();
    if (path is! String || path.isEmpty) return null;
    if (width == null || height == null || scale == null) return null;
    if (width <= 0 || height <= 0 || scale <= 0 || scale > 1) return null;
    return ProcessingDerivative(
      path: path,
      width: width,
      height: height,
      scale: scale,
      byteLength: (json['bytes'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Produces the upload derivative of a captured photograph.
///
/// Size, quality and the decision to skip all come from the frame itself:
///
/// * the derivative is a **uniform** scale of the saved JPEG, so the vertical
///   and horizontal field of view are unchanged and the server's focal length
///   (derived from image height and the documented FOV) simply scales with the
///   image. A fixed target size such as 1536×2048 would change the aspect ratio
///   on any device that does not shoot exactly 3:4 and would silently distort
///   the projection, so it is deliberately not used;
/// * a photograph that is already at or below [maxLongSidePx] is left alone —
///   re-encoding it would lose quality and save no transfer time;
/// * the original bytes are read, never rewritten. A failure returns `null`
///   and the caller uploads the original.
class ProcessingDerivativeEncoder {
  const ProcessingDerivativeEncoder({
    this.maxLongSidePx = 2048,
    this.quality = 90,
  });

  /// Longest side of the derivative, in pixels. 2048 keeps the stitching
  /// output at its configured width while cutting the transferred bytes by
  /// roughly 87 % against a 3072×4096 original.
  final int maxLongSidePx;

  /// JPEG quality of the derivative. 90 is the documented setting: high enough
  /// that ORB descriptors and seam blending see the same texture as the
  /// original, low enough to shrink the file by an order of magnitude.
  final int quality;

  /// Where the derivative for [sourcePath] lives. Deterministic, so a resumed
  /// session finds the copy an earlier launch already made.
  static String pathFor(String sourcePath) {
    final dot = sourcePath.lastIndexOf('.');
    final slash = sourcePath.lastIndexOf(Platform.pathSeparator);
    if (dot <= slash) return '$sourcePath.proc.jpg';
    return '${sourcePath.substring(0, dot)}.proc.jpg';
  }

  /// Encodes the derivative on a background isolate.
  ///
  /// JPEG decode/resize/encode is the heaviest remaining non-camera operation
  /// in the capture path. Running it here keeps CameraX preview and input
  /// dispatch responsive even when a 12 MP frame takes seconds on a warm phone.
  /// Only the immutable result map crosses the isolate boundary; no OpenCV
  /// pointer is ever shared.
  Future<ProcessingDerivative?> encode(String sourcePath) async {
    final maxSide = maxLongSidePx;
    final jpegQuality = quality;
    final json = await Isolate.run(() async {
      final derivative = await ProcessingDerivativeEncoder(
        maxLongSidePx: maxSide,
        quality: jpegQuality,
      ).encodeSync(sourcePath);
      return derivative?.toJson();
    });
    return json == null ? null : ProcessingDerivative.fromJson(json);
  }

  /// Synchronous implementation; call from [encode] or from a worker isolate.
  Future<ProcessingDerivative?> encodeSync(String sourcePath) async {
    final source = File(sourcePath);
    if (!await source.exists()) return null;
    final int sourceLength;
    final Uint8List bytes;
    try {
      bytes = await source.readAsBytes();
      sourceLength = bytes.length;
    } on Object catch (error) {
      debugPrint('PROC_DERIVATIVE: could not read $sourcePath: $error');
      return null;
    }

    final size = readJpegSize(bytes);
    if (size == null || size.width <= 0 || size.height <= 0) {
      debugPrint('PROC_DERIVATIVE: unreadable dimensions for $sourcePath');
      return null;
    }
    final longSide = size.width > size.height ? size.width : size.height;
    if (longSide <= maxLongSidePx) return null;

    final target = pathFor(sourcePath);
    final existing = await _reuse(target, source, size.width, size.height);
    if (existing != null) return existing;

    final scale = maxLongSidePx / longSide;
    final targetWidth = (size.width * scale).round().clamp(1, size.width);
    final targetHeight = (size.height * scale).round().clamp(1, size.height);
    // Report the scale the rounding actually produced, so the server's
    // intrinsics are exact rather than approximately right.
    final achieved = targetWidth / size.width;

    cv.Mat? decoded;
    cv.Mat? resized;
    try {
      decoded = cv.imdecode(bytes, cv.IMREAD_COLOR);
      if (decoded.isEmpty) {
        debugPrint('PROC_DERIVATIVE: could not decode $sourcePath');
        return null;
      }
      resized = cv.resize(
        decoded,
        (targetWidth, targetHeight),
        interpolation: cv.INTER_AREA,
      );
      final (ok, encoded) = cv.imencode(
        '.jpg',
        resized,
        params: cv.VecI32.fromList(<int>[cv.IMWRITE_JPEG_QUALITY, quality]),
      );
      if (!ok || encoded.isEmpty) {
        debugPrint('PROC_DERIVATIVE: could not encode the copy of $sourcePath');
        return null;
      }
      final file = File(target);
      await file.parent.create(recursive: true);
      // Write-then-rename: a half-written derivative must never be uploaded.
      final partial = File('$target.partial');
      await partial.writeAsBytes(encoded, flush: true);
      await partial.rename(target);
      debugPrint(
        'PROC_DERIVATIVE: ${size.width}x${size.height} '
        '(${(sourceLength / 1048576).toStringAsFixed(2)} MB) -> '
        '${targetWidth}x$targetHeight '
        '(${(encoded.length / 1048576).toStringAsFixed(2)} MB, '
        'scale ${achieved.toStringAsFixed(3)})',
      );
      return ProcessingDerivative(
        path: target,
        width: targetWidth,
        height: targetHeight,
        scale: achieved,
        byteLength: encoded.length,
      );
    } on Object catch (error) {
      debugPrint('PROC_DERIVATIVE: failed for $sourcePath: $error');
      return null;
    } finally {
      resized?.dispose();
      decoded?.dispose();
    }
  }

  /// A derivative written by an earlier launch for the same original.
  ///
  /// Reused only when it is at least as new as the original: a recaptured
  /// photograph overwrites the original, and the stale copy must not be
  /// uploaded in its place. A file whose dimensions cannot be read is treated
  /// as absent and re-encoded.
  Future<ProcessingDerivative?> _reuse(
    String target,
    File source,
    int sourceWidth,
    int sourceHeight,
  ) async {
    final file = File(target);
    if (!await file.exists()) return null;
    try {
      final stat = await file.stat();
      if (stat.size <= 0) return null;
      if (stat.modified.isBefore(await source.lastModified())) return null;
      final bytes = await file.readAsBytes();
      final size = readJpegSize(bytes);
      if (size == null || size.width <= 0 || size.height <= 0) return null;
      return ProcessingDerivative(
        path: target,
        width: size.width,
        height: size.height,
        scale: size.width / sourceWidth,
        byteLength: stat.size,
      );
    } on Object {
      return null;
    }
  }
}
