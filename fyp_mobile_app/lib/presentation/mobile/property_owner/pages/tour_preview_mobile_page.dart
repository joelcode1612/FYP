import 'package:shared_logic/shared_logic.dart';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:panorama/panorama.dart';

import '../../../../core/theme/sitewise_theme.dart';
import '../../../../core/utils/pano_bytes.dart';
import '../../../shared/viewmodels/tour_preview_viewmodel.dart';
import '../../../shared/widgets/sitewise_button.dart';
import '../../../shared/widgets/sitewise_confirm_dialog.dart';
import '../../../shared/widgets/sitewise_empty_state.dart';
import '../../../shared/widgets/sitewise_loading_state.dart';
import '../../../shared/widgets/sitewise_secondary_button.dart';
import '../../shell/mobile_app_shell.dart';

/// Mobile tour preview: real 360° panorama, 26-frame grid with retake,
/// regenerate, submit and delete. The capture screen resumes for retakes.

class TourPreviewMobilePage extends StatefulWidget {
  final AppCubit appState;
  final String tourId;
  const TourPreviewMobilePage({
    super.key,
    required this.appState,
    required this.tourId,
  });

  @override
  State<TourPreviewMobilePage> createState() => _TourPreviewMobilePageState();
}

class _TourPreviewMobilePageState extends State<TourPreviewMobilePage> {
  late final TourPreviewViewModel vm;

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
        appState: widget.appState,
        title: 'Tour preview',
        currentRoute: '/owner/tours',
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
                      onPressed: vm.generating ? null : () => vm.regenerate(),
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
          future: readPanoramaBytes(path),
          builder: (c, snap) {
            if (!snap.hasData || snap.data == null) {
              return const Center(child: CircularProgressIndicator());
            }
            return Panorama(child: Image.memory(snap.data!));
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
        return InkWell(
          onTap: () => _retake(i),
          child: Card(
            clipBehavior: Clip.antiAlias,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: FutureBuilder<Uint8List?>(
                    future: readImageBytes(f.imagePath),
                    builder: (cc, snap) => snap.data == null
                        ? const Icon(Icons.image_outlined)
                        : Image.memory(snap.data!, fit: BoxFit.cover),
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
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _retake(int index) async {
    final tour = vm.tour;
    if (tour == null) return;
    await vm.retakeFrame(index, tour.propertyId);
    if (mounted) {
      Navigator.of(
        context,
      ).pushNamed('/owner/capture', arguments: tour.propertyId);
    }
  }
}
