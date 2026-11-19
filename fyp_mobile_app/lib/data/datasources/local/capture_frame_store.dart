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

  /// The tour's panorama-upload state, or `null` when nothing was ever
  /// attempted. Absence is reported as absence: no upload is implied.
  Future<PanoramaUploadRecord?> loadPanoramaUpload(String tourId) async {
    try {
      final file = File('${await tourRoot(tourId)}/panorama_upload.json');
      if (!await file.exists()) return null;
      return PanoramaUploadRecord.fromJson(
        jsonDecode(await file.readAsString()) as Map<String, dynamic>,
      );
    } catch (_) {
      // A corrupt record reads as "never attempted", which re-offers the
      // upload instead of claiming a panorama Sitewise never received.
      return null;
    }
  }

  Future<void> savePanoramaUpload(PanoramaUploadRecord record) async {
    try {
      final root = await tourRoot(record.tourId);
      await Directory(root).create(recursive: true);
      await File('$root/panorama_upload.json').writeAsString(
        jsonEncode(record.toJson()),
        flush: true,
      );
    } catch (_) {
      // The panorama and its frames are on disk already; losing only the
      // acknowledgement makes the next screen offer the upload again.
    }
  }
}

/// One panorama's upload state, kept in the tour directory.
///
/// The device always owns the stitched file; Sitewise only gets a copy. A
/// record whose [uploadedAt] is null means "sent, not accepted", which is what
/// lets the review screen finish the job after a failure or a killed app
/// without touching a single frame. The byte count identifies the panorama, so
/// re-sending the identical file is recognisable as a duplicate rather than a
/// second storage object and a second tour update.
class PanoramaUploadRecord {
  final String tourId;
  final String propertyId;
  final String panoramaPath;
  final int bytes;
  final DateTime? uploadedAt;

  const PanoramaUploadRecord({
    required this.tourId,
    required this.propertyId,
    required this.panoramaPath,
    required this.bytes,
    this.uploadedAt,
  });

  /// True when this record describes the panorama currently on disk.
  bool covers(String path, int size) =>
      panoramaPath == path && bytes == size;

  bool get accepted => uploadedAt != null;

  PanoramaUploadRecord copyWith({DateTime? uploadedAt}) =>
      PanoramaUploadRecord(
        tourId: tourId,
        propertyId: propertyId,
        panoramaPath: panoramaPath,
        bytes: bytes,
        uploadedAt: uploadedAt ?? this.uploadedAt,
      );

  Map<String, dynamic> toJson() => {
    'tourId': tourId,
    'propertyId': propertyId,
    'panoramaPath': panoramaPath,
    'bytes': bytes,
    'uploadedAt': uploadedAt?.toIso8601String(),
  };

  factory PanoramaUploadRecord.fromJson(Map<String, dynamic> json) =>
      PanoramaUploadRecord(
        tourId: json['tourId'] as String? ?? '',
        propertyId: json['propertyId'] as String? ?? '',
        panoramaPath: json['panoramaPath'] as String? ?? '',
        bytes: (json['bytes'] as num?)?.toInt() ?? 0,
        uploadedAt: json['uploadedAt'] is String
            ? DateTime.tryParse(json['uploadedAt'] as String)
            : null,
      );
}
