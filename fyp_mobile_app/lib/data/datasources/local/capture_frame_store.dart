import 'package:shared_logic/shared_logic.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';


/// Local file storage for captured panorama frames and outputs.
/// Layout: `<appDocs>/sitewise/tours/<tourId>/frames/frame_<index>.png`.

class CaptureFrameStore {
  Future<Directory> _tourDir(String tourId) async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/sitewise/tours/$tourId/frames');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<String> tourRoot(String tourId) async {
    final docs = await getApplicationDocumentsDirectory();
    return '${docs.path}/sitewise/tours/$tourId';
  }

  Future<String> saveFrame({
    required String tourId,
    required int frameIndex,
    required Uint8List bytes,
  }) async {
    final dir = await _tourDir(tourId);
    final path =
        '${dir.path}/frame_${frameIndex.toString().padLeft(2, '0')}.png';
    await File(path).writeAsBytes(bytes, flush: true);
    return path;
  }

  Future<bool> frameExists(String imagePath) async {
    try {
      final file = File(imagePath);
      return await file.exists() && await file.length() > 0;
    } catch (_) {
      return false;
    }
  }

  Future<void> deleteFrame(String imagePath) async {
    try {
      final file = File(imagePath);
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Best effort: a missing frame file is already the desired end state.
    }
  }

  Future<void> deleteTour(String tourId) async {
    try {
      final root = Directory(await tourRoot(tourId));
      if (await root.exists()) await root.delete(recursive: true);
    } catch (_) {
      // Best effort cleanup.
    }
  }

  Future<void> saveManifest(
    String tourId,
    Map<int, CapturedFrame> frames,
  ) async {
    try {
      final root = await tourRoot(tourId);
      await Directory(root).create(recursive: true);
      final data = [
        for (final entry in frames.entries)
          {
            'index': entry.key,
            'frameIndex': entry.value.frameIndex,
            'targetName': entry.value.targetName,
            'targetYaw': entry.value.targetYaw,
            'targetPitch': entry.value.targetPitch,
            'imagePath': entry.value.imagePath,
            'capturedAt': entry.value.capturedAt.toIso8601String(),
            'retakeCount': entry.value.retakeCount,
          },
      ];
      await File('$root/frames.json').writeAsString(jsonEncode(data));
    } catch (_) {
      // Manifest is a convenience cache; frames on disk stay authoritative.
    }
  }

  Future<Map<int, CapturedFrame>> loadManifest(String tourId) async {
    final result = <int, CapturedFrame>{};
    try {
      final file = File('${await tourRoot(tourId)}/frames.json');
      if (!await file.exists()) return result;
      final data = jsonDecode(await file.readAsString()) as List;
      for (final item in data) {
        final m = item as Map<String, dynamic>;
        final frame = CapturedFrame(
          frameIndex: (m['frameIndex'] as num).toInt(),
          targetName: m['targetName'] as String,
          targetYaw: (m['targetYaw'] as num).toDouble(),
          targetPitch: (m['targetPitch'] as num).toDouble(),
          imagePath: m['imagePath'] as String,
          capturedAt: DateTime.parse(m['capturedAt'] as String),
          retakeCount: (m['retakeCount'] as num?)?.toInt() ?? 0,
        );
        if (await frameExists(frame.imagePath)) {
          result[(m['index'] as num).toInt()] = frame;
        }
      }
    } catch (_) {
      // Corrupt manifest reads as empty; files remain for manual recovery.
    }
    return result;
  }

  Future<List<String>> missingFiles(List<String> paths) async {
    final missing = <String>[];
    for (final p in paths) {
      if (!await frameExists(p)) missing.add(p);
    }
    return missing;
  }
}
