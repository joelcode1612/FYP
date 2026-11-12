import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../../application/services/service_locator.dart';
import '../../../core/utils/capture_log.dart';
import '../../../features/capture/data/repositories/sitewise_capture_repository.dart';
import '../../../features/capture/presentation/screens/ar_capture_screen.dart';
import '../widgets/sitewise_button.dart';

/// What the capture screen was opened for. [title] names the tour record; a
/// bare property id (deep link) still works and falls back to a generic title.
class ArCaptureRequest {
  const ArCaptureRequest({required this.propertyId, this.title});

  final String propertyId;
  final String? title;
}

/// Guided 26-point 360° capture, driven by ARCore.
///
/// The camera view, the world-anchored GLB target, the plane detection and the
/// stills all come from the in-app ARCore host
/// (`com.example.fyp.ar.ArCoreCapturePlugin`), reached through
/// `ArCoreHost` → `ArSessionService` → `CaptureController`. There is no second
/// camera session and no sensor-derived pose: ARCore owns the camera device for
/// the duration of the capture, and every guidance decision (station
/// calibration, alignment, drift, steadiness, shutter) is made from its pose.
///
/// This page is only the host: it resolves the tour the frames belong to, gives
/// the controller a tour-scoped [SiteWiseCaptureRepository], and hands the
/// completed frames to the existing stitcher. The AR UI itself is
/// [CaptureModuleScreen], which is the reference implementation's own screen.
class ArCaptureMobilePage extends StatefulWidget {
  const ArCaptureMobilePage({super.key, required this.request});

  final ArCaptureRequest request;

  @override
  State<ArCaptureMobilePage> createState() => _ArCaptureMobilePageState();
}

class _ArCaptureMobilePageState extends State<ArCaptureMobilePage> {
  SiteWiseCaptureRepository? _repository;
  String? _tourId;
  bool _preparing = true;
  bool _generating = false;
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
      final repository = SiteWiseCaptureRepository(
        tourId: tour.id,
        frameStore: ServiceLocator.frameStore,
        onProgress: (count) => _syncFrameCount(tour.id, count),
      );
      if (!mounted) return;
      setState(() {
        _tourId = tour.id;
        _repository = repository;
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

  /// Stitch the confirmed frames with the existing OpenCV pipeline and open the
  /// preview. Called once, when the controller reports every target saved.
  Future<void> _generate() async {
    final tourId = _tourId;
    if (tourId == null || _generating) return;
    setState(() {
      _generating = true;
      _stage = 'Validating frames…';
    });
    try {
      final manifest = await ServiceLocator.frameStore.loadManifest(tourId);
      final ordered = manifest.entries.toList()
        ..sort((a, b) => a.key.compareTo(b.key));
      final frames = [for (final entry in ordered) entry.value];
      if (frames.length < 26) {
        throw StateError(
          'Only ${frames.length} of 26 frames are saved, so the panorama '
          'cannot be generated yet.',
        );
      }
      final result = await ServiceLocator.panoramas.generate(
        tourId: tourId,
        frames: frames,
        onStage: (stage) {
          if (mounted) setState(() => _stage = stage);
        },
      );
      if (!mounted) return;
      setState(() => _generating = false);
      if (!result.success) {
        setState(() => _stage = result.message);
        return;
      }
      Navigator.of(
        context,
      ).pushReplacementNamed('/tour-preview', arguments: tourId);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _generating = false;
        _stage = readableFailure(
          error,
          fallback: 'The panorama could not be generated.',
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final repository = _repository;
    if (_setupError != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('AR 360° capture')),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.view_in_ar_outlined, size: 48),
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
    if (_preparing || repository == null) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator()),
      );
    }
    return Stack(
      children: [
        CaptureModuleScreen(
          repository: repository,
          stationId: _tourId,
          onComplete: _generate,
        ),
        // The reference screen blocks the system back gesture so a capture
        // cannot be lost by an accidental swipe. SiteWise still needs an
        // explicit exit: leaving keeps every saved frame on disk and the tour
        // as a draft, which is exactly what "Resume Previous Capture" restores.
        Positioned(
          left: 12,
          top: MediaQuery.paddingOf(context).top + 8,
          child: _ExitButton(
            onPressed: () {
              if (_generating) return;
              Navigator.of(context).pop();
            },
          ),
        ),
        if (_generating)
          Positioned(
            left: 16,
            right: 16,
            bottom: 24,
            child: _StitchingBanner(stage: _stage ?? 'Generating panorama…'),
          ),
      ],
    );
  }
}

class _ExitButton extends StatelessWidget {
  const _ExitButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.black54,
    shape: const CircleBorder(),
    child: InkWell(
      onTap: onPressed,
      customBorder: const CircleBorder(),
      child: const Padding(
        padding: EdgeInsets.all(8),
        child: Icon(Icons.arrow_back, color: Colors.white, size: 20),
      ),
    ),
  );
}

class _StitchingBanner extends StatelessWidget {
  const _StitchingBanner({required this.stage});

  final String stage;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: 0.86),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Row(
      children: [
        const SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            stage,
            style: const TextStyle(color: Colors.white, fontSize: 13),
          ),
        ),
      ],
    ),
  );
}
