import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shared_logic/shared_logic.dart';

import '../../../../data/datasources/local/capture_frame_store.dart';
import '../../domain/models/capture_record.dart';
import '../../domain/models/capture_station.dart';
import '../../domain/models/capture_target.dart';
import 'capture_repository_impl.dart';

/// ARCore capture persistence bound to a SiteWise tour.
///
/// The reference module ships [FileCaptureRepository], which writes to its own
/// app-wide directory. SiteWise already owns a per-tour directory
/// (`<appDocs>/sitewise/tours/<tourId>`) through [CaptureFrameStore], and the
/// panorama stitcher, the tour preview and the owner's listing all read from
/// that one place. Two stores would mean the AR frames and the stitched tour
/// could disagree about what exists, so this adapter keeps the reference
/// module's exact on-disk layout *inside* the tour directory:
///
/// ```
/// <appDocs>/sitewise/tours/<tourId>/
///   frames.json                     SiteWise manifest (written by frameStore)
///   ar_capture/<stationId>/
///     station.json                  the calibrated ARCore reference pose
///     targets.json                  the 26 world-anchored directions
///     records.json                  one entry per saved JPEG
///     frames/t01.jpg … t26.jpg
/// ```
///
/// `frames.json` is updated from `records.json` on every save, so the existing
/// stitcher keeps working without knowing ARCore exists. Nothing here invents a
/// frame: a record is written only after the JPEG is on disk, and the manifest
/// lists only records that were written.
class SiteWiseCaptureRepository implements CaptureRepository {
  SiteWiseCaptureRepository({
    required this.tourId,
    required this.frameStore,
    this.onProgress,
  });

  /// The tour these frames belong to. Also used as the default station id, so
  /// one tour has exactly one calibrated station and resume is deterministic.
  final String tourId;

  final CaptureFrameStore frameStore;

  /// Called with the number of confirmed frames after each save, so the tour
  /// record can carry real progress.
  final void Function(int capturedCount)? onProgress;

  String? _root;
  List<CaptureTarget> _targets = const <CaptureTarget>[];

  Future<String> _rootDir() async {
    final cached = _root;
    if (cached != null) return cached;
    final tourRoot = await frameStore.tourRoot(tourId);
    final root = p.join(tourRoot, 'ar_capture');
    await Directory(root).create(recursive: true);
    _root = root;
    return root;
  }

  Future<String> _stationDir(String stationId) async =>
      p.join(await _rootDir(), stationId);

  Future<String> _framesDir(String stationId) async {
    final dir = Directory(p.join(await _stationDir(stationId), 'frames'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir.path;
  }

  @override
  Future<String> framePath(String stationId, int targetId) async {
    final dir = await _framesDir(stationId);
    return p.join(dir, 't${targetId.toString().padLeft(2, '0')}.jpg');
  }

  @override
  Future<void> saveStation(CaptureStation station) async {
    final file = File(
      p.join(await _stationDir(station.stationId), 'station.json'),
    );
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(station.toJson()), flush: true);
  }

  @override
  Future<void> saveTargets(List<CaptureTarget> targets) async {
    if (targets.isEmpty) return;
    _targets = List<CaptureTarget>.unmodifiable(targets);
    final file = File(
      p.join(await _stationDir(targets.first.stationId), 'targets.json'),
    );
    await file.parent.create(recursive: true);
    await file.writeAsString(
      jsonEncode(targets.map((CaptureTarget t) => t.toJson()).toList()),
      flush: true,
    );
  }

  @override
  Future<void> saveCalibration(
    CaptureStation station,
    List<CaptureTarget> targets,
  ) async {
    await persistCaptureCalibrationFiles(
      stationDirectory: await _stationDir(station.stationId),
      station: station,
      targets: targets,
    );
    _targets = List<CaptureTarget>.unmodifiable(targets);
  }

  @override
  Future<void> saveRecord(CaptureRecord record) async {
    final dir = await _stationDir(record.stationId);
    final file = File(p.join(dir, 'records.json'));
    await file.parent.create(recursive: true);

    final existing = List<CaptureRecord>.of(
      await loadRecords(record.stationId),
    );
    existing.removeWhere((CaptureRecord r) => r.targetId == record.targetId);
    existing.add(record);
    existing.sort(
      (CaptureRecord a, CaptureRecord b) => a.targetId.compareTo(b.targetId),
    );
    await file.writeAsString(
      jsonEncode(existing.map((CaptureRecord r) => r.toJson()).toList()),
      flush: true,
    );

    // Mirror into the tour manifest the stitcher reads. Frame order is the
    // capture sequence, not the save order: a retake overwrites its slot.
    await _writeManifest(record.stationId, existing);
    onProgress?.call(existing.length);
  }

  Future<void> _writeManifest(
    String stationId,
    List<CaptureRecord> records,
  ) async {
    final targets = _targets.isEmpty ? await loadTargets(stationId) : _targets;
    final byId = <int, CaptureTarget>{
      for (final CaptureTarget t in targets) t.targetId: t,
    };
    final frames = <int, CapturedFrame>{};
    for (final CaptureRecord r in records) {
      final target = byId[r.targetId];
      frames[r.targetId - 1] = CapturedFrame(
        // CaptureTarget is 1-based (1–26); the manifest is 0-based, matching
        // the capture sequence the stitcher orders by.
        frameIndex: r.targetId - 1,
        targetName: target == null
            ? 'T${r.targetId.toString().padLeft(2, '0')}'
            : 'T${target.targetId.toString().padLeft(2, '0')} '
                  '(${target.yawDegrees.round()}° / '
                  '${target.pitchDegrees.round()}°)',
        targetYaw: target?.yawDegrees ?? r.targetYawDegrees,
        targetPitch: target?.pitchDegrees ?? r.targetPitchDegrees,
        imagePath: r.imagePath,
        capturedAt: r.capturedAt,
      );
    }
    await frameStore.saveManifest(tourId, frames);
  }

  @override
  Future<CaptureStation?> loadStation(String stationId) async {
    final file = File(p.join(await _stationDir(stationId), 'station.json'));
    if (!await file.exists()) return null;
    final json = jsonDecode(await file.readAsString());
    return CaptureStation.fromJson(json as Map<String, dynamic>);
  }

  @override
  Future<List<CaptureTarget>> loadTargets(String stationId) async {
    final file = File(p.join(await _stationDir(stationId), 'targets.json'));
    if (!await file.exists()) return const <CaptureTarget>[];
    final json = jsonDecode(await file.readAsString()) as List<dynamic>;
    final targets = json
        .map((dynamic e) => CaptureTarget.fromJson(e as Map<String, dynamic>))
        .toList();
    if (targets.isNotEmpty) {
      _targets = List<CaptureTarget>.unmodifiable(targets);
    }
    return targets;
  }

  @override
  Future<List<CaptureRecord>> loadRecords(String stationId) async {
    final file = File(p.join(await _stationDir(stationId), 'records.json'));
    if (!await file.exists()) return const <CaptureRecord>[];
    final json = jsonDecode(await file.readAsString()) as List<dynamic>;
    return json
        .map((dynamic e) => CaptureRecord.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Stations that hold a real calibration record, newest first.
  ///
  /// A half-written directory from a killed process is not a station: the
  /// `station.json` check is what makes `resumableStationId` trustworthy.
  @override
  Future<List<String>> stationIds() async {
    final dir = Directory(await _rootDir());
    if (!await dir.exists()) return const <String>[];
    final result = <String>[];
    for (final entity in dir.listSync()) {
      if (entity is! Directory) continue;
      final id = p.basename(entity.path);
      if (await File(p.join(entity.path, '.calibration.pending')).exists()) {
        continue;
      }
      if (await File(p.join(entity.path, 'station.json')).exists()) {
        result.add(id);
      }
    }
    result.sort();
    return result;
  }
}
