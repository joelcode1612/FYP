import 'package:fyp/features/capture_360/domain/models/capture_record.dart';
import 'package:fyp/features/capture_360/domain/models/capture_station.dart';
import 'package:fyp/features/capture_360/domain/models/capture_target.dart';

abstract class CaptureRepository {
  Future<void> saveStation(CaptureStation station);

  Future<void> saveTargets(List<CaptureTarget> targets);

  /// Persists a complete calibrated station only after all AR placements exist.
  /// Implementations stage both metadata files and roll back on failure.
  Future<void> saveCalibration(
    CaptureStation station,
    List<CaptureTarget> targets,
  );

  Future<void> saveRecord(CaptureRecord record);

  Future<CaptureStation?> loadStation(String stationId);

  Future<List<CaptureTarget>> loadTargets(String stationId);

  Future<List<CaptureRecord>> loadRecords(String stationId);

  /// Absolute path of the JPEG for [stationId]/[targetId].
  Future<String> framePath(String stationId, int targetId);

  /// Every station that has been saved, newest first.
  ///
  /// The resume entry point needs this to offer "continue where you left off"
  /// without the caller knowing anything about the store's layout.
  Future<List<String>> stationIds();
}
