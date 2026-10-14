import 'dart:typed_data';

import 'pano_bytes_stub.dart' if (dart.library.io) 'pano_bytes_io.dart' as impl;

/// Reads panorama file bytes where the platform supports it.
/// Returns null on platforms without file access (e.g. web), where the
/// caller must fall back to the placeholder viewer.

Future<Uint8List?> readPanoramaBytes(String path) => impl.readBytes(path);

/// Reads any local image file (e.g. captured frame thumbnails) with the
/// same platform fallback.
Future<Uint8List?> readImageBytes(String path) => impl.readBytes(path);
