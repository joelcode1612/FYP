import 'package:shared_logic/shared_logic.dart';
import 'package:flutter/foundation.dart';

import '../../../application/services/panorama_capture_service.dart';
import '../../../application/services/service_locator.dart';
import '../../../core/utils/capture_log.dart';

/// Preview/edit state for a captured tour. Loads the persisted frame
/// manifest, regenerates the panorama after retakes, submits for
/// verification and deletes. Retakes resume the live capture session so no
/// confirmed frame is ever lost.

class TourPreviewViewModel extends ChangeNotifier {
  final String tourId;

  VirtualTour? tour;
  List<CapturedFrame> frames = [];
  bool loading = false;
  bool generating = false;
  String? stage;
  String? error;

  TourPreviewViewModel({required this.tourId});

  Future<void> load() async {
    loading = true;
    error = null;
    notifyListeners();
    try {
      tour = await ServiceLocator.tourService.tourById(tourId);
      final manifest = await ServiceLocator.frameStore.loadManifest(tourId);
      final entries = manifest.entries.toList()
        ..sort((a, b) => a.key.compareTo(b.key));
      frames = [for (final e in entries) e.value];
    } catch (e) {
      error = e.toString();
    }
    loading = false;
    notifyListeners();
  }

  Future<bool> regenerate() async {
    if (generating) return false;
    if (frames.length < 26) {
      error =
          'Panorama cannot be generated. Only ${frames.length}/26 frames are stored.';
      notifyListeners();
      return false;
    }
    generating = true;
    stage = 'Validating frames...';
    error = null;
    notifyListeners();
    try {
      final missing = await ServiceLocator.frameStore.missingFiles([
        for (final f in frames) f.imagePath,
      ]);
      if (missing.isNotEmpty) {
        error =
            'Panorama cannot be generated. ${missing.length} frame file(s) are unreadable.';
        return false;
      }
      final StitchResult result = await ServiceLocator.panoramas.generate(
        tourId: tourId,
        frames: frames,
        onStage: (s) {
          stage = s;
          notifyListeners();
        },
      );
      if (result.success) {
        await load();
        return true;
      }
      error = result.message;
      return false;
    } catch (e) {
      error = 'Generation error: $e';
      return false;
    } finally {
      generating = false;
      notifyListeners();
    }
  }

  Future<bool> submit() async {
    try {
      await ServiceLocator.tourService.submitTour(tourId);
      await load();
      return true;
    } catch (e) {
      error = e.toString();
      notifyListeners();
      return false;
    }
  }

  Future<bool> remove() async {
    try {
      await ServiceLocator.tourService.deleteTour(tourId);
      return true;
    } catch (e) {
      error = e.toString();
      notifyListeners();
      return false;
    }
  }

  /// Prepare a retake of frame [index]: remove its file, reopen the live
  /// session at that index and persist the manifest. The caller navigates
  /// to the capture screen, which resumes automatically.
  Future<void> retakeFrame(int index, String propertyId) async {
    final existing = ServiceLocator.captureSessions.forProperty(propertyId);
    final PanoramaCaptureService service;
    if (existing != null) {
      service = existing.service;
    } else {
      service = ServiceLocator.newPanoramaCaptureService();
      service.tourId = tourId;
      service.propertyId = propertyId;
      final manifest = await ServiceLocator.frameStore.loadManifest(tourId);
      if (manifest.isNotEmpty) service.restoreFrames(manifest);
      ServiceLocator.captureSessions.startNew(
        propertyId: propertyId,
        tourId: tourId,
        service: service,
      );
    }
    final path = service.frames[index]?.imagePath;
    if (path != null) {
      await ServiceLocator.frameStore.deleteFrame(path);
    }
    service.reopenFrame(index);
    await ServiceLocator.frameStore.saveManifest(tourId, service.frames);
    CaptureLog.log('Retake prepared for frame ${index + 1}');
    await load();
  }
}
