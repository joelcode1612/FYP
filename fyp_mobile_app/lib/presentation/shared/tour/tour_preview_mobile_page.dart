import 'package:shared_logic/shared_logic.dart';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:panorama/panorama.dart';

import '../../../core/theme/sitewise_theme.dart';
import '../../../core/utils/pano_bytes.dart';
import '../viewmodels/tour_preview_viewmodel.dart';
import '../widgets/sitewise_button.dart';
import '../widgets/sitewise_confirm_dialog.dart';
import '../widgets/sitewise_empty_state.dart';
import '../widgets/sitewise_loading_state.dart';
import '../widgets/sitewise_secondary_button.dart';
import '../../mobile/shell/mobile_app_shell.dart';
import 'ar_capture_mobile_page.dart';

/// Mobile tour preview: real 360° panorama, 26-frame grid with retake,
/// regenerate, submit and delete. The capture screen resumes for retakes.

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
                    _panorama(vm.tour!),
                    const SizedBox(height: 12),
                    Text(
                      'Frames (${vm.frames.length}/26)',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 8),
                    _frameGrid(),
                    const SizedBox(height: 12),
                    if (vm.error != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          vm.error!,
                          style: const TextStyle(color: SitewiseColors.danger),
                        ),
                      ),
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
                    SitewiseSecondaryButton(
                      label: 'Regenerate panorama',
                      icon: Icons.auto_awesome,
                      onPressed: vm.generating
                          ? null
                          : () {
                              _invalidateImageCaches();
                              vm.regenerate();
                            },
                    ),
                    const SizedBox(height: 8),
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
            return Panorama(child: Image.memory(bytes));
          },
        ),
      ),
    );
  }

  Widget _frameGrid() {
    if (vm.frames.isEmpty) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text('No frames stored yet.'),
        ),
      );
    }
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
      itemCount: vm.frames.length,
      itemBuilder: (c, i) {
        final f = vm.frames[i];
        // The grid is ordered by capture sequence, but a missing frame file
        // drops out of the manifest, so the position in this list is not the
        // sequence index. Resolve it from the rig definition instead.
        final sequenceIndex = CaptureTargetDataSource.targets.indexWhere(
          (t) => t.frameIndex == f.frameIndex,
        );
        return Card(
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: FutureBuilder<Uint8List?>(
                  future: _bytesFor(f.imagePath),
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
                padding: const EdgeInsets.all(6),
                child: Text(
                  '#${i + 1} ${f.targetName}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11),
                ),
              ),
              if (canRetake && sequenceIndex >= 0)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: TextButton.icon(
                    onPressed: vm.generating
                        ? null
                        : () => _retake(sequenceIndex),
                    icon: const Icon(Icons.replay_rounded, size: 14),
                    label: const Text('Retake', style: TextStyle(fontSize: 11)),
                    style: TextButton.styleFrom(
                      foregroundColor: SitewiseColors.action,
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  /// Reopens the live capture session at [sequenceIndex] and hands over to the
  /// capture screen, which resumes that exact session — the other 25 frames
  /// are never discarded.
  Future<void> _retake(int sequenceIndex) async {
    final tour = vm.tour;
    if (tour == null || vm.generating) return;
    await vm.retakeFrame(sequenceIndex, tour.propertyId);
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
}
