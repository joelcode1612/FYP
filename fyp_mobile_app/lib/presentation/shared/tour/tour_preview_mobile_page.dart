import 'package:shared_logic/shared_logic.dart';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import '../../mobile/widgets/mobile_swipe_panorama.dart';

import '../../../core/theme/sitewise_theme.dart';
import '../../../core/utils/pano_bytes.dart';
import '../../../features/capture/presentation/widgets/stitching_results_panel.dart';
import '../../../features/virtual_tour/presentation/capture_theme.dart';
import '../viewmodels/tour_preview_viewmodel.dart';
import '../widgets/sitewise_button.dart';
import '../widgets/sitewise_confirm_dialog.dart';
import '../widgets/sitewise_empty_state.dart';
import '../widgets/sitewise_loading_state.dart';
import '../widgets/sitewise_secondary_button.dart';
import '../../mobile/shell/mobile_app_shell.dart';
import 'ar_capture_mobile_page.dart';

/// Mobile tour preview: real 360° panorama, per-target frame grid with
/// retake, regenerate, submit and delete. The capture screen resumes for
/// retakes. The grid follows the tour's capture engine — 38 directions for
/// the sphere flow, the legacy 26-point layout for tours captured before it.

class TourPreviewMobilePage extends StatefulWidget {
  final String tourId;
  const TourPreviewMobilePage({super.key, required this.tourId});

  @override
  State<TourPreviewMobilePage> createState() => _TourPreviewMobilePageState();
}

class _TourPreviewMobilePageState extends State<TourPreviewMobilePage> {
  late final TourPreviewViewModel vm;

  /// Cached file reads, one future per path. Without this, every rebuild of
  /// the preview (regeneration stages, button state changes) re-read every
  /// frame file and the panorama from disk — the "repeated image downloads"
  /// failure mode. A change of path (retake, regenerate) starts a new read.
  final Map<String, Future<Uint8List?>> _bytesCache = {};

  Future<Uint8List?> _bytesFor(String path) => _bytesCache.putIfAbsent(
    path,
    () => readImageBytes(path).timeout(
      const Duration(seconds: 8),
      onTimeout: () => null,
    ),
  );

  /// A retake or regeneration overwrites the files in place; dropping the
  /// cached reads is what makes the preview show the NEW image instead of a
  /// stale one after a successful update.
  void _invalidateImageCaches() => _bytesCache.clear();

  @override
  void initState() {
    super.initState();
    vm = TourPreviewViewModel(tourId: widget.tourId)..load();
  }

  @override
  void dispose() {
    vm.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: vm,
      builder: (ctx, _) => MobileAppShell(
        title: 'Tour preview',
        // Matches parentShellRoute('/tour-preview') so the Listing tab stays
        // highlighted while the tour is open.
        currentRoute: '/entrepreneur/recommendations',
        body: vm.loading
            ? const SitewiseLoadingState()
            : vm.tour == null
            ? const SitewiseEmptyState(
                title: 'Tour not found',
                message: 'This virtual tour is no longer available.',
              )
            : SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _header(vm.tour!),
                    const SizedBox(height: 12),
                    _completenessCard(),
                    const SizedBox(height: 12),
                    _panorama(vm.tour!),
                    const SizedBox(height: 12),
                    if (vm.generating)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Row(
                          children: [
                            const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                            const SizedBox(width: 12),
                            Expanded(child: Text(vm.stage ?? 'Processing…')),
                          ],
                        ),
                      ),
                    if (vm.error != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          vm.error!,
                          style: const TextStyle(color: SitewiseColors.danger),
                        ),
                      ),
                    _uploadCard(),
                    SitewiseSecondaryButton(
                      label: vm.hasPanorama
                          ? 'Regenerate panorama'
                          : 'Generate panorama',
                      icon: Icons.auto_awesome,
                      onPressed: vm.generating
                          ? null
                          : () {
                              _invalidateImageCaches();
                              vm.regenerate();
                            },
                    ),
                    const SizedBox(height: 12),
                    if (vm.stitchService != null) ...[
                      _stitchingSection(),
                      const SizedBox(height: 12),
                    ],
                    Text(
                      'Photographs (${vm.frames.length}/${vm.specs.length})',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 8),
                    _frameGrid(),
                    const SizedBox(height: 12),
                    if (vm.tour!.status == VirtualTourStatus.ready ||
                        vm.tour!.status == VirtualTourStatus.draft)
                      SitewiseButton(
                        label: 'Submit for verification',
                        icon: Icons.send,
                        onPressed: () async {
                          final ok = await vm.submit();
                          if (context.mounted && ok) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Submitted for verification.'),
                              ),
                            );
                          }
                        },
                      ),
                    if (vm.tour!.status ==
                        VirtualTourStatus.pendingVerification)
                      const Card(
                        child: Padding(
                          padding: EdgeInsets.all(16),
                          child: Text('Pending administrator verification.'),
                        ),
                      ),
                    const SizedBox(height: 8),
                    SitewiseSecondaryButton(
                      label: 'Delete tour',
                      icon: Icons.delete_outline,
                      onPressed: () async {
                        final ok = await showSitewiseConfirmDialog(
                          context,
                          title: 'Delete this tour?',
                          message:
                              'The panorama and all captured frames will be permanently removed.',
                          confirmLabel: 'Delete',
                          destructive: true,
                        );
                        if (ok) {
                          final done = await vm.remove();
                          if (context.mounted && done) {
                            Navigator.of(context).pop();
                          }
                        }
                      },
                    ),
                  ],
                ),
              ),
      ),
    );
  }

  Widget _header(VirtualTour tour) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tour.title,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                Text(
                  '${tour.frameCount} frames captured',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: _statusColor(tour.status).withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              _statusLabel(tour.status),
              style: TextStyle(
                color: _statusColor(tour.status),
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    ),
  );

  Color _statusColor(VirtualTourStatus status) => switch (status) {
    VirtualTourStatus.approved => SitewiseColors.success,
    VirtualTourStatus.pendingVerification ||
    VirtualTourStatus.processing => SitewiseColors.warning,
    VirtualTourStatus.rejected => SitewiseColors.danger,
    VirtualTourStatus.draft || VirtualTourStatus.ready => SitewiseColors.action,
  };

  String _statusLabel(VirtualTourStatus status) => switch (status) {
    VirtualTourStatus.draft => 'Draft',
    VirtualTourStatus.processing => 'Processing…',
    VirtualTourStatus.ready => 'Ready for submission',
    VirtualTourStatus.pendingVerification => 'Pending verification',
    VirtualTourStatus.approved => 'Approved',
    VirtualTourStatus.rejected => 'Rejected — retake and resubmit',
  };

  Widget _panorama(VirtualTour tour) {
    final path = tour.panoramaPath;
    if (path == null) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(20),
          child: Text('Generate the panorama to preview it here.'),
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: SizedBox(
        height: 300,
        child: FutureBuilder<Uint8List?>(
          future: _bytesFor(path),
          builder: (c, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            final bytes = snap.data;
            if (bytes == null) {
              return const Center(
                child: Text(
                  'Panorama file unavailable. Try regenerating it.',
                  style: TextStyle(color: SitewiseColors.muted, fontSize: 12),
                ),
              );
            }
            return MobileSwipePanorama(bytes: bytes);
          },
        ),
      ),
    );
  }

  /// Every capture direction the station was built from, in shutter order. A
  /// target without a saved photograph is drawn as its own empty slot, so an
  /// incomplete sphere is visible rather than merely a shorter list.
  Widget _frameGrid() {
    final status = vm.tour?.status;
    // A tour awaiting review or already approved is not silently editable.
    final canRetake =
        status == VirtualTourStatus.draft ||
        status == VirtualTourStatus.ready ||
        status == VirtualTourStatus.rejected;
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
        childAspectRatio: 0.8,
      ),
      itemCount: vm.specs.length,
      itemBuilder: (c, i) {
        final spec = vm.specs[i];
        final frame = vm.frameFor(spec.targetId);
        return Card(
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: frame == null
                    ? const Icon(
                        Icons.add_a_photo_outlined,
                        color: SitewiseColors.muted,
                      )
                    : FutureBuilder<Uint8List?>(
                        future: _bytesFor(frame.imagePath),
                        builder: (cc, snap) {
                          if (snap.connectionState != ConnectionState.done) {
                            return const Icon(Icons.image_outlined);
                          }
                          final bytes = snap.data;
                          if (bytes == null) {
                            return const Icon(
                              Icons.image_not_supported_outlined,
                              color: SitewiseColors.muted,
                            );
                          }
                          return Image.memory(bytes, fit: BoxFit.cover);
                        },
                      ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Text(
                  spec.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11),
                ),
              ),
              if (canRetake && frame != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: TextButton.icon(
                    onPressed: vm.generating ? null : () => _retake(spec.targetId),
                    icon: const Icon(Icons.replay_rounded, size: 14),
                    label: const Text('Retake', style: TextStyle(fontSize: 11)),
                    style: TextButton.styleFrom(
                      foregroundColor: SitewiseColors.action,
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                )
              else
                const SizedBox(height: 32),
            ],
          ),
        );
      },
    );
  }

  /// Clears one target's photograph and reopens the live capture session.
  ///
  /// Only that record and that JPEG go; the controller rebuilds its target
  /// list from the records on disk, so it resumes the same station and visits
  /// the direction that is pending again. Nothing else is recaptured.
  Future<void> _retake(int targetId) async {
    final tour = vm.tour;
    if (tour == null || vm.generating) return;
    await vm.retakeTarget(targetId);
    _invalidateImageCaches();
    if (!mounted) return;
    Navigator.of(context).pushNamed(
      '/owner/capture',
      arguments: ArCaptureRequest(
        propertyId: tour.propertyId,
        title: tour.title,
      ),
    );
  }

  /// Reopens the session without deleting anything — the panel's way out when
  /// a pair failed to register and the frame itself is fine.
  Future<void> _resumeCapture() async {
    final tour = vm.tour;
    if (tour == null || vm.generating) return;
    await Navigator.of(context).pushNamed(
      '/owner/capture',
      arguments: ArCaptureRequest(propertyId: tour.propertyId, title: tour.title),
    );
  }

  /// Says how much of the sphere exists on this device and which directions
  /// are missing. The panorama is stitched from exactly these photographs, so
  /// an incomplete set is stated, not hidden behind a generic error.
  Widget _completenessCard() {
    final missing = vm.missingTargetIds;
    final complete = missing.isEmpty;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              complete
                  ? 'All ${vm.specs.length} photographs saved.'
                  : '${vm.frames.length} of ${vm.specs.length} photographs saved.',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              complete
                  ? (vm.hasPanorama
                        ? 'The panorama below is stitched from these saved frames.'
                        : 'Generate the panorama from these saved frames.')
                  : 'Missing targets: ${missing.take(10).join(', ')}'
                        '${missing.length > 10 ? ' (+${missing.length - 10} more)' : ''}. '
                        'Resume the capture to shoot them — saved frames are kept.',
              style: TextStyle(
                color: complete
                    ? SitewiseColors.muted
                    : SitewiseColors.warning,
                fontSize: 12,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The Sitewise copy of the panorama. A device-only result is still a real
  /// panorama, but buyers see nothing until the upload is accepted, so a
  /// pending upload gets its own action instead of a silent success.
  Widget _uploadCard() {
    if (vm.uploadPending) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'This panorama exists only on this device. The frames and the '
            'stitched file are safe here; uploading changes nothing on disk.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          SitewiseButton(
            label: 'Upload panorama to Sitewise',
            icon: Icons.cloud_upload_outlined,
            onPressed: vm.generating ? null : _upload,
          ),
          const SizedBox(height: 8),
        ],
      );
    }
    if (!vm.panoramaPublished) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(
        'Uploaded to Sitewise for this property.',
        style: Theme.of(context).textTheme.bodySmall,
      ),
    );
  }

  Future<void> _upload() async {
    final ok = await vm.pushPanorama();
    if (mounted && ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Panorama uploaded to Sitewise.')),
      );
    }
  }

  /// The per-frame stitching evidence: which neighbour each frame registered
  /// against, its inlier counts, and which pair failed. This is the capture
  /// module's own panel, so it keeps the camera theme's dark surface.
  Widget _stitchingSection() {
    final service = vm.stitchService;
    if (service == null) return const SizedBox.shrink();
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: ColoredBox(
        color: CaptureColors.sheet,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: StitchingResultsPanel(
            service: service,
            specs: vm.specs,
            onRetake: _resumeCapture,
            thumbnailFor: (targetId) => vm.recordFor(targetId)?.imagePath,
          ),
        ),
      ),
    );
  }
}
