import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:shared_logic/shared_logic.dart';

import '../../../application/services/service_locator.dart';
import '../../../core/config/mobile_config.dart';
import '../../../core/utils/capture_log.dart';
import '../../../data/datasources/local/capture_frame_store.dart';
import '../../../features/capture/data/repositories/sitewise_capture_repository.dart';
import '../../../features/sphere_capture/data/sitewise_sphere_session_store.dart';
import '../../../features/sphere_capture/presentation/screens/sphere_capture_screen.dart';
import '../widgets/sitewise_button.dart';
import '../widgets/sitewise_confirm_dialog.dart';

/// What the capture screen was opened for. [title] names the tour record; a
/// bare property id (deep link) still works and falls back to a generic title.
class ArCaptureRequest {
  const ArCaptureRequest({required this.propertyId, this.title});

  final String propertyId;
  final String? title;
}

/// Guided 38-point 360° capture, driven by device rotation only.
///
/// The sphere's centre is the phone at all times: the 38 directions come from
/// the fixed layout in `sphere_target.dart`, the pose comes from the fused
/// rotation vector and the shutter fires inside a 2° alignment cone while the
/// phone is angularly still. There is no AR session, no plane detection and no
/// world anchor, so walking moves the whole sphere with the phone — only
/// rotation is tracked.
///
/// This page is only the host: it resolves the tour the frames belong to, gives
/// the controller a tour-scoped [SiteWiseCaptureRepository] (frames and
/// records inside `<appDocs>/sitewise/tours/<tourId>/ar_capture/<tourId>/`), a
/// [SitewiseSphereSessionStore] for the resumable session metadata, and hands
/// the stitched panorama back to the tour record and the Sitewise upload. The
/// capture UI itself is [SphereCaptureScreen], the reference implementation's
/// own screen.
///
/// A station captured by the retired 26-point ARCore flow carries records but
/// no `session.json` marker (the 38-flow writes it before the camera starts).
/// Such a station is never resumed as a 38-point session: the host offers an
/// explicit fresh start, which deletes the legacy capture, and otherwise backs
/// out without touching anything.
class ArCaptureMobilePage extends StatefulWidget {
  const ArCaptureMobilePage({super.key, required this.request});

  final ArCaptureRequest request;

  @override
  State<ArCaptureMobilePage> createState() => _ArCaptureMobilePageState();
}

class _ArCaptureMobilePageState extends State<ArCaptureMobilePage> {
  SiteWiseCaptureRepository? _repository;
  SitewiseSphereSessionStore? _sessions;
  String? _tourId;

  /// The device-local panorama once the sphere flow stitched it. While it is
  /// set and the Sitewise upload has not been accepted, the banner offers an
  /// upload retry — the captured frames and the stitched result are never
  /// reworked by an upload failure.
  String? _panoramaPath;
  bool _preparing = true;
  bool _uploading = false;
  String? _stage;
  String? _setupError;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  Future<void> _prepare() async {
    final propertyId = widget.request.propertyId;
    if (propertyId.isEmpty) {
      setState(() {
        _setupError =
            'No property was supplied, so there is nothing to capture '
            'a tour for.';
        _preparing = false;
      });
      return;
    }
    try {
      // One unfinished capture per property. Reusing the draft is what makes
      // "resume" safe: a second tour for the same property would split the
      // saved frames across two records.
      final tour =
          await ServiceLocator.tourService.tourForPropertyDraft(propertyId) ??
          await ServiceLocator.tourService.createDraft(
            propertyId: propertyId,
            title: widget.request.title ?? '360° tour',
            frameCount: 0,
          );
      final frameStore = ServiceLocator.frameStore;

      // Engine check before anything opens: records without a session marker
      // were written by the retired 26-point flow and must not be resumed as a
      // 38-point session. A station the 38-flow has never touched (no records
      // at all) just starts normally.
      final isSphereEngine = await SitewiseSphereSessionStore.hasSessionMarker(
        frameStore: frameStore,
        tourId: tour.id,
      );
      if (!isSphereEngine) {
        final legacyRecords = await SiteWiseCaptureRepository(
          tourId: tour.id,
          frameStore: frameStore,
        ).loadRecords(tour.id);
        if (legacyRecords.isNotEmpty) {
          if (!mounted) return;
          final restart = await showSitewiseConfirmDialog(
            context,
            title: 'Start the 38-point capture over?',
            message:
                'This tour was captured with the previous 26-point flow, which '
                'this app no longer runs. Its ${legacyRecords.length} saved '
                'photographs cannot be finished into a 38-point panorama. '
                'Start over deletes them and captures all 38 points; Cancel '
                'keeps everything exactly as it is.',
            confirmLabel: 'Start over',
            destructive: true,
          );
          if (!restart) {
            if (!mounted) return;
            Navigator.of(context).pop();
            return;
          }
          await _purgeLegacyCapture(tour.id);
        }
      }

      final repository = SiteWiseCaptureRepository(
        tourId: tour.id,
        frameStore: frameStore,
        onProgress: (count) => _syncFrameCount(tour.id, count),
      );
      if (!mounted) return;
      setState(() {
        _tourId = tour.id;
        _repository = repository;
        _sessions = SitewiseSphereSessionStore(
          frameStore: frameStore,
          tourId: tour.id,
        );
        _preparing = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _setupError = readableFailure(
          error,
          fallback: 'The capture session could not be prepared.',
        );
        _preparing = false;
      });
    }
  }

  /// Deletes the legacy 26-point station and its manifest mirror, so the
  /// 38-point flow starts from an empty directory. Only the station subtree is
  /// removed — the tour record and anything else in the tour directory stay.
  Future<void> _purgeLegacyCapture(String tourId) async {
    try {
      final root = await ServiceLocator.frameStore.tourRoot(tourId);
      final stationDir = Directory(p.join(root, 'ar_capture', tourId));
      if (await stationDir.exists()) {
        await stationDir.delete(recursive: true);
      }
      await ServiceLocator.frameStore.saveManifest(
        tourId,
        const <int, CapturedFrame>{},
      );
      CaptureLog.log('Legacy 26-point capture cleared for tour $tourId');
    } catch (error) {
      CaptureLog.log('Legacy capture could not be cleared: $error');
      if (!mounted) return;
      setState(() {
        _setupError =
            'The previous capture could not be cleared, so the 38-point '
            'capture was not started: ${readableFailure(error, fallback: 'storage error')}';
        _preparing = false;
      });
    }
  }

  /// The tour record carries the real number of confirmed frames, so the
  /// preview and the owner's listings never claim progress that was not saved.
  Future<void> _syncFrameCount(String tourId, int count) async {
    try {
      final tour = await ServiceLocator.tourRepo.tourById(tourId);
      if (tour == null || tour.frameCount == count) return;
      await ServiceLocator.tourRepo.updateTour(
        tour.copyWith(frameCount: count, sceneCount: count),
      );
    } catch (error) {
      CaptureLog.log('Frame count could not be recorded: $error');
    }
  }

  /// The sphere flow finished stitching. Attach the panorama to the tour
  /// record, then push it to Sitewise and open the preview. Stitching itself
  /// stays inside the capture screen — the host only ever sees the finished
  /// file.
  Future<void> _onPanoramaReady(String panoramaPath) async {
    final tourId = _tourId;
    if (tourId == null || _uploading) return;
    setState(() {
      _panoramaPath = panoramaPath;
      _uploading = true;
      _stage = 'Uploading panorama to Sitewise…';
    });
    try {
      final tour = await ServiceLocator.tourRepo.tourById(tourId);
      if (tour != null) {
        await ServiceLocator.tourRepo.updateTour(
          tour.copyWith(
            panoramaPath: panoramaPath,
            status: VirtualTourStatus.ready,
          ),
        );
      }
    } catch (error) {
      CaptureLog.log('Panorama could not be recorded on the tour: $error');
    }
    await _pushPanorama();
  }

  /// Uploads the stitched panorama to Sitewise and then opens the preview.
  ///
  /// The backend upserts the property's virtual-tour row, which is what the
  /// property-detail 360° viewer reads. A failed upload is honest and
  /// retryable: the device panorama and every captured frame are untouched,
  /// so Retry re-runs only the upload.
  Future<void> _pushPanorama() async {
    final tourId = _tourId;
    final panoramaPath = _panoramaPath;
    if (tourId == null || panoramaPath == null || _uploading) return;
    if (!MobileConfig.usesLiveApi) {
      // A demo build keeps no server records; the device panorama still
      // previews and the tour record stays as the stitcher wrote it.
      if (!mounted) return;
      setState(() {
        _uploading = false;
        _stage = null;
      });
      _openPreview();
      return;
    }
    setState(() {
      _uploading = true;
      _stage = 'Uploading panorama to Sitewise…';
    });
    try {
      final bytes = await File(panoramaPath).readAsBytes();
      final previous = await ServiceLocator.frameStore.loadPanoramaUpload(
        tourId,
      );
      if (previous != null &&
          previous.accepted &&
          previous.covers(panoramaPath, bytes.length)) {
        // Sitewise already holds this exact panorama; sending it again would
        // only create a second storage object for the same result.
        if (!mounted) return;
        setState(() {
          _uploading = false;
          _stage = null;
        });
        _openPreview();
        return;
      }
      // Written before the request: if the process dies mid-upload, the tour
      // directory says "sent, not accepted" and the review screen finishes
      // the job instead of claiming a panorama that never arrived.
      final record = PanoramaUploadRecord(
        tourId: tourId,
        propertyId: widget.request.propertyId,
        panoramaPath: panoramaPath,
        bytes: bytes.length,
      );
      await ServiceLocator.frameStore.savePanoramaUpload(record);
      await ServiceLocator.virtualTours.uploadPanorama(
        propertyId: widget.request.propertyId,
        bytes: bytes,
        filename: p.basename(panoramaPath),
      );
      await ServiceLocator.frameStore.savePanoramaUpload(
        record.copyWith(uploadedAt: DateTime.now()),
      );
      if (!mounted) return;
      setState(() {
        _uploading = false;
        _stage = null;
      });
      _openPreview();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _uploading = false;
        _stage =
            'The panorama was generated on this device, but the Sitewise '
            'upload failed: ${readableFailure(error, fallback: 'upload error')} '
            'The frames and the panorama are kept — you can retry.';
      });
    }
  }

  void _openPreview() {
    final tourId = _tourId;
    if (tourId == null || !mounted) return;
    Navigator.of(
      context,
    ).pushReplacementNamed('/tour-preview', arguments: tourId);
  }

  @override
  Widget build(BuildContext context) {
    final repository = _repository;
    if (_setupError != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('360° capture')),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.threesixty_outlined, size: 48),
              const SizedBox(height: 12),
              Text(_setupError!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              SitewiseButton(
                label: 'Back',
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
      );
    }
    if (_preparing || repository == null || _sessions == null) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator()),
      );
    }
    return Stack(
      children: [
        SphereCaptureScreen(
          sessionId: _tourId,
          repository: repository,
          sessions: _sessions,
          onPanoramaReady: _onPanoramaReady,
        ),
        // Upload progress and failure, one tappable line at the bottom edge.
        // Stitching progress lives inside the capture screen's own completion
        // overlay; by the time this banner shows, the panorama already exists.
        if (_uploading || _stage != null)
          Positioned(
            left: 16,
            right: 16,
            bottom: 24,
            child: _UploadBanner(
              stage: _stage ?? 'Uploading panorama to Sitewise…',
              running: _uploading,
              onRetry: _uploading ? null : _pushPanorama,
            ),
          ),
      ],
    );
  }
}

class _UploadBanner extends StatelessWidget {
  const _UploadBanner({
    required this.stage,
    required this.running,
    this.onRetry,
  });

  final String stage;
  final bool running;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: 0.86),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Row(
      children: [
        if (running) ...[
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
            ),
          ),
          const SizedBox(width: 12),
        ] else ...[
          const Icon(Icons.error_outline, color: Colors.orangeAccent, size: 18),
          const SizedBox(width: 12),
        ],
        Expanded(
          child: Text(
            stage,
            style: const TextStyle(color: Colors.white, fontSize: 13),
          ),
        ),
        if (!running && onRetry != null)
          TextButton(
            onPressed: onRetry,
            child: const Text(
              'Retry',
              style: TextStyle(color: Colors.white),
            ),
          ),
      ],
    ),
  );
}
