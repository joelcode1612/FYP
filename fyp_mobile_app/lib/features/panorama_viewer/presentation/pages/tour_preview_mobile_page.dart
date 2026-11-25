import 'package:fyp/features/property_management/presentation/widgets/provider_agent_inspection_panel.dart';
import 'package:shared_logic/shared_logic.dart';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:fyp/features/panorama_viewer/presentation/widgets/mobile_swipe_panorama.dart';
import 'package:fyp/features/panorama_viewer/presentation/pages/panorama_fullscreen_page.dart';

import 'package:fyp/core/di/service_locator.dart';
import 'package:fyp/core/theme/sitewise_theme.dart';
import 'package:fyp/core/utils/pano_bytes.dart';
import 'package:fyp/features/capture_360/presentation/widgets/stitching_results_panel.dart';
import 'package:fyp/features/capture_360/presentation/widgets/capture_theme.dart';
import 'package:fyp/features/capture_360/application/tour_preview_viewmodel.dart';
import 'package:fyp/shared/presentation/widgets/sitewise_button.dart';
import 'package:fyp/shared/presentation/widgets/sitewise_confirm_dialog.dart';
import 'package:fyp/shared/presentation/widgets/sitewise_empty_state.dart';
import 'package:fyp/shared/presentation/widgets/sitewise_loading_state.dart';
import 'package:fyp/shared/presentation/widgets/sitewise_secondary_button.dart';
import 'package:fyp/shared/presentation/layouts/mobile_app_shell.dart';
import 'package:fyp/features/capture_360/presentation/pages/ar_capture_mobile_page.dart';

/// Mobile tour preview: real 360° panorama, per-target frame grid with
/// retake, regenerate, submit and delete. The capture screen resumes for
/// retakes. The grid follows the tour's capture engine — 38 directions for
/// the sphere flow, the legacy 26-point layout for tours captured before it.

class TourPreviewMobilePage extends ConsumerStatefulWidget {
  final String tourId;
  const TourPreviewMobilePage({super.key, required this.tourId});

  @override
  ConsumerState<TourPreviewMobilePage> createState() =>
      _TourPreviewMobilePageState();
}

class _TourPreviewMobilePageState extends ConsumerState<TourPreviewMobilePage> {
  bool get _canCapture =>
      ref.read(authNotifierProvider).user?.role == AppRole.agent;
  late final TourPreviewViewModel vm;
  bool _continued = false;
  bool _checklistEdited = false;

  /// Cached file reads, one future per path. Without this, every rebuild of
  /// the preview (regeneration stages, button state changes) re-read every
  /// frame file and the panorama from disk — the "repeated image downloads"
  /// failure mode. A change of path (retake, regenerate) starts a new read.
  final Map<String, Future<Uint8List?>> _bytesCache = {};

  Future<Uint8List?> _bytesFor(String path) => _bytesCache.putIfAbsent(
    path,
    () => readImageBytes(
      path,
    ).timeout(const Duration(seconds: 8), onTimeout: () => null),
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
        title: vm.liveBackend && _continued
            ? 'Review inspection'
            : 'Tour preview',
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
                child: vm.liveBackend
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _header(vm.tour!),
                          const SizedBox(height: 12),
                          _captureStatusCard(),
                          const SizedBox(height: 12),
                          _panorama(vm.tour!),
                          const SizedBox(height: 8),
                          _draftSavedLine(),
                          if (vm.generating)
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: Row(
                                children: [
                                  const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Text(vm.stage ?? 'Processing…'),
                                  ),
                                ],
                              ),
                            ),
                          if (vm.error != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: Text(
                                vm.error!,
                                style: const TextStyle(
                                  color: SitewiseColors.danger,
                                ),
                              ),
                            ),
                          const SizedBox(height: 12),
                          if (_continued) ...[
                            if (int.tryParse(vm.propertyId)
                                case final propertyId?)
                              ProviderAgentInspectionPanel(
                                propertyId: propertyId,
                                onEdited: () =>
                                    setState(() => _checklistEdited = true),
                                onSaved: () async {
                                  await vm.refreshServerState();
                                  if (mounted) {
                                    setState(() => _checklistEdited = false);
                                  }
                                },
                              ),
                            _reviewCard(),
                          ],
                          if (_canCapture &&
                              !_continued &&
                              vm.inspectionError != null)
                            SitewiseSecondaryButton(
                              label: 'Refresh inspection',
                              icon: Icons.refresh,
                              onPressed: vm.refreshServerState,
                            ),
                          if (_canCapture && !_continued && vm.assignmentReady)
                            SitewiseButton(
                              label: 'Continue',
                              icon: Icons.arrow_forward,
                              onPressed:
                                  vm.generating ||
                                      (!vm.hasPanorama &&
                                          vm.previewPanoramaId == null)
                                  ? null
                                  : () => setState(() => _continued = true),
                            ),
                          const SizedBox(height: 16),
                          if (_canCapture && _continued)
                            SitewiseButton(
                              label: vm.submitting
                                  ? 'Submitting to Admin…'
                                  : 'Submit to Admin',
                              icon: Icons.verified_user_outlined,
                              onPressed:
                                  vm.submissionEligible &&
                                      !_checklistEdited &&
                                      !vm.submitting &&
                                      !vm.generating
                                  ? _submitToAdmin
                                  : null,
                            ),
                          const SizedBox(height: 12),
                          SitewiseSecondaryButton(
                            label: 'Recapture',
                            icon: Icons.replay_rounded,
                            onPressed:
                                vm.generating ||
                                    vm.submitting ||
                                    vm.tour?.status ==
                                        VirtualTourStatus.pendingVerification
                                ? null
                                : _recapture,
                          ),
                          const SizedBox(height: 16),
                          Text(
                            'Photographs (${vm.frames.length}/${vm.specs.length})',
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 8),
                          _frameGrid(),
                          const SizedBox(height: 12),
                          if (vm.tour!.status ==
                              VirtualTourStatus.pendingVerification)
                            const Card(
                              child: Padding(
                                padding: EdgeInsets.all(16),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Submitted for Admin Review',
                                      style: TextStyle(
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    SizedBox(height: 4),
                                    Text(
                                      'Your property verification is awaiting '
                                      'review.',
                                    ),
                                  ],
                                ),
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
                                    'The panorama and all captured frames will '
                                    'be permanently removed.',
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
                      )
                    : Column(
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
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Text(vm.stage ?? 'Processing…'),
                                  ),
                                ],
                              ),
                            ),
                          if (vm.error != null)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Text(
                                vm.error!,
                                style: const TextStyle(
                                  color: SitewiseColors.danger,
                                ),
                              ),
                            ),
                          if (_canCapture) _uploadCard(),
                          if (_canCapture && vm.hasPanorama)
                            SitewiseSecondaryButton(
                              label: 'View Full Screen',
                              icon: Icons.fullscreen_rounded,
                              onPressed: vm.generating ? null : _openFullscreen,
                            ),
                          const SizedBox(height: 12),
                          if (_canCapture && vm.frames.isNotEmpty)
                            SitewiseSecondaryButton(
                              label: 'Retake Photos',
                              icon: Icons.photo_camera_back_outlined,
                              onPressed: vm.generating ? null : _resumeCapture,
                            ),
                          if (_canCapture)
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
                          if (_canCapture && vm.liveBackend) ...[
                            _reviewCard(),
                            const SizedBox(height: 12),
                          ],
                          if (_canCapture && vm.stitchService != null) ...[
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
                          if (vm.tour!.status ==
                              VirtualTourStatus.pendingVerification)
                            const Card(
                              child: Padding(
                                padding: EdgeInsets.all(16),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Submitted for Admin Review',
                                      style: TextStyle(
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    SizedBox(height: 4),
                                    Text(
                                      'Your property verification is awaiting '
                                      'review.',
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          const SizedBox(height: 8),
                          if (_canCapture)
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
    final panoramaId = vm.previewPanoramaId;
    if (vm.liveBackend && panoramaId != null && !vm.hasPanorama) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Text(
              'Panorama generated successfully',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: SizedBox(
              height: 300,
              child: _CanonicalPanoramaBox(
                key: ValueKey(panoramaId),
                panoramaId: panoramaId,
              ),
            ),
          ),
        ],
      );
    }
    final path = tour.panoramaPath;
    if (path == null) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(20),
          child: Text('Generate the panorama to preview it here.'),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.only(bottom: 8),
          child: Text(
            'Panorama generated successfully',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
        ClipRRect(
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
                      style: TextStyle(
                        color: SitewiseColors.muted,
                        fontSize: 12,
                      ),
                    ),
                  );
                }
                return MobileSwipePanorama(bytes: bytes);
              },
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: TextButton.icon(
            onPressed: vm.generating ? null : _openFullscreen,
            icon: const Icon(Icons.fullscreen_rounded, size: 16),
            label: const Text('View Full Screen'),
          ),
        ),
      ],
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
              if (_canCapture && canRetake && frame != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: TextButton.icon(
                    onPressed: vm.generating
                        ? null
                        : () => _retake(spec.targetId),
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
    if (!_canCapture) return;
    final tour = vm.tour;
    if (tour == null || vm.generating) return;
    await vm.retakeTarget(targetId);
    _invalidateImageCaches();
    if (!mounted) return;
    await _openCapture(tour);
  }

  /// Reopens the session without deleting anything — the panel's way out when
  /// a pair failed to register and the frame itself is fine.
  Future<void> _resumeCapture() async {
    if (!_canCapture) return;
    final tour = vm.tour;
    if (tour == null || vm.generating) return;
    await _openCapture(tour);
  }

  Future<void> _openCapture(VirtualTour tour) async {
    final navigator = Navigator.of(context);
    final completed = await navigator.pushNamed(
      '/owner/capture',
      arguments: ArCaptureRequest(
        propertyId: tour.propertyId,
        title: tour.title,
      ),
    );
    if (!mounted ||
        completed != true ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    if (navigator.canPop()) {
      navigator.pop();
    } else {
      navigator.pushReplacementNamed(
        '/provider/inspection',
        arguments: tour.propertyId,
      );
    }
  }

  /// The ✓-row status card (§6): the two facts the Agent needs before the
  /// preview — the capture count and whether the panorama exists.
  Widget _captureStatusCard() {
    final complete = vm.frames.length == vm.specs.length && vm.specs.isNotEmpty;
    final hasPanorama = vm.hasPanorama || vm.canonicalReady;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  complete
                      ? Icons.check_circle_outline
                      : Icons.radio_button_unchecked,
                  size: 18,
                  color: complete
                      ? SitewiseColors.success
                      : SitewiseColors.warning,
                ),
                const SizedBox(width: 10),
                Text(
                  '${vm.frames.length} / ${vm.specs.length} photos captured',
                  style: const TextStyle(fontSize: 15),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(
                  hasPanorama
                      ? Icons.check_circle_outline
                      : Icons.radio_button_unchecked,
                  size: 18,
                  color: hasPanorama
                      ? SitewiseColors.success
                      : SitewiseColors.warning,
                ),
                const SizedBox(width: 10),
                Text(
                  hasPanorama
                      ? 'Panorama generated'
                      : 'Panorama not generated yet',
                  style: const TextStyle(fontSize: 15),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _draftSavedLine() => const Padding(
    padding: EdgeInsets.symmetric(horizontal: 4),
    child: Row(
      children: [
        Icon(Icons.save_outlined, size: 16, color: SitewiseColors.muted),
        SizedBox(width: 8),
        Text('Draft saved automatically', style: TextStyle(fontSize: 13)),
      ],
    ),
  );

  /// The Recapture choice (§8): retake the targets that need improving, or
  /// start a whole new 38-photo attempt. The previous draft survives both —
  /// the new-attempt path archives the old station instead of deleting it.
  Future<void> _recapture() async {
    if (!_canCapture) return;
    final tour = vm.tour;
    if (tour == null) return;
    final choice = await showDialog<_RecaptureChoice>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Recapture 360° photographs?'),
        content: const Text(
          'You can improve the panorama by replacing captured photographs. '
          'The current draft and its Sitewise copy are kept until a new '
          'panorama has been generated.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(
              context,
              rootNavigator: true,
            ).pop(_RecaptureChoice.retakeTargets),
            child: const Text('Retake selected targets'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(
              context,
              rootNavigator: true,
            ).pop(_RecaptureChoice.newAttempt),
            child: const Text('Start a new 38-photo capture'),
          ),
        ],
      ),
    );
    if (!mounted || choice == null) return;
    setState(() {
      _continued = false;
      _checklistEdited = false;
    });
    if (choice == _RecaptureChoice.retakeTargets) {
      await _resumeCapture();
      return;
    }
    final ok = await vm.startNewCaptureAttempt();
    if (!mounted) return;
    if (ok) {
      _invalidateImageCaches();
      await _openCapture(tour);
      if (mounted && ModalRoute.of(context)?.isCurrent == true) {
        await vm.refreshServerState();
      }
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(vm.error ?? 'The new capture could not be started.'),
        ),
      );
    }
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
                color: complete ? SitewiseColors.muted : SitewiseColors.warning,
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
    if (vm.uploadPending && vm.queueState?.panorama?.lastError != null) {
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
            label: 'Retry panorama upload',
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

  /// Explicit confirmation before the one-way Admin submission. The backend
  /// re-checks every precondition server-side; a refusal message names the
  /// missing requirement (assignment state, the four on-site checks, or a
  /// verified panorama) instead of a raw error trace.
  Future<void> _submitToAdmin() async {
    final acknowledge = vm.populationRequiresAcknowledgement;
    final ok = await showSitewiseConfirmDialog(
      context,
      title: 'Submit Property for Admin Verification?',
      message:
          "The property's inspection, 360° panorama, and supporting "
          'information will be sent to the Administrator for review. You '
          'will not be able to edit the submission while it is under '
          'review.'
          '${acknowledge ? '\n\nPopulation data is unavailable. Submit without a population figure?' : ''}',
      confirmLabel: 'Confirm Submission',
    );
    if (!ok || !mounted) return;
    final done = await vm.submit(acknowledgeUnavailablePopulation: acknowledge);
    if (!mounted) return;
    if (done) {
      // Backend confirmed — the dedicated confirmation screen carries the
      // backend's stage, never a local assumption of success.
      await Navigator.of(context).pushNamed(
        '/provider/submission-success',
        arguments: int.tryParse(vm.tour?.propertyId ?? '') ?? 0,
      );
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(vm.error ?? 'The submission was refused.')),
    );
  }

  /// Fullscreen inspection of the stitched result. The local panorama file
  /// is read once (cached like every other preview read); the canonical
  /// viewer offers its own fullscreen action after its signed fetch.
  Future<void> _openFullscreen() async {
    final path = vm.tour?.panoramaPath;
    if (path == null || vm.generating) return;
    final bytes = await _bytesFor(path);
    if (!mounted || bytes == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PanoramaFullscreenPage(bytes: bytes),
      ),
    );
  }

  /// The Final Verification Review (§9): every row is a real, server- or
  /// disk-verified fact. A row without evidence shows its missing-item
  /// action instead of a checkmark — nothing is faked, and the submit button
  /// enables only when the backend-verifiable set is complete.
  Widget _reviewCard() {
    final propertyId = int.tryParse(vm.tour?.propertyId ?? '');
    final rows = <_ReviewRow>[
      _ReviewRow(
        label: 'Property information',
        state: propertyId != null && vm.assignmentStatus.isNotEmpty
            ? _RowState.pass
            : _RowState.pending,
        actionLabel: 'Review Property Details',
        onAction: propertyId == null || vm.submitting
            ? null
            : () async {
                await Navigator.of(
                  context,
                ).pushNamed('/provider/property-detail', arguments: propertyId);
                if (mounted) await vm.refreshServerState();
              },
      ),
      _ReviewRow(
        label: _checklistEdited
            ? 'Checklist has unsaved changes'
            : vm.inspectionError != null
            ? 'Could not confirm the saved checklist'
            : vm.checksComplete
            ? 'Checklist saved · 4 of 4 confirmed'
            : 'Checklist needs attention',
        state:
            !_checklistEdited && vm.inspectionError == null && vm.checksComplete
            ? _RowState.pass
            : _RowState.pending,
        actionLabel: vm.inspectionError != null
            ? 'Refresh'
            : 'Complete Inspection',
        onAction: propertyId == null || vm.submitting
            ? null
            : () async {
                if (vm.inspectionError != null) {
                  await vm.refreshServerState();
                  return;
                }
                await Navigator.of(
                  context,
                ).pushNamed('/provider/property-detail', arguments: propertyId);
                if (mounted) await vm.refreshServerState();
              },
      ),
      _ReviewRow(
        label: '38 photographs captured',
        state: vm.frames.length == vm.specs.length
            ? _RowState.pass
            : _RowState.pending,
        actionLabel: 'Retake Photos',
        onAction: vm.generating ? null : _resumeCapture,
      ),
      _ReviewRow(
        label: vm.panoramaReviewStatus,
        state: vm.panoramaUploaded ? _RowState.pass : _RowState.pending,
      ),
      _ReviewRow(
        label: 'Ownership / authorisation',
        state: vm.assignmentReady ? _RowState.pass : _RowState.info,
        info: vm.assignmentStatus.isEmpty
            ? 'Verified by Sitewise when you submit'
            : 'Assignment status: '
                  '${vm.assignmentStatus.replaceAll('_', ' ')}',
      ),
      const _ReviewRow(
        label: 'Other required property evidence',
        state: _RowState.info,
        info: 'Checked by Sitewise when you submit',
      ),
    ];

    final eligible =
        !_checklistEdited && vm.submissionEligible && vm.panoramaUploaded;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              eligible ? 'Ready for Admin Review' : 'Verification review',
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
            ),
            const SizedBox(height: 10),
            for (final row in rows) ...[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    switch (row.state) {
                      _RowState.pass => Icons.check_circle_outline,
                      _RowState.pending => Icons.radio_button_unchecked,
                      _RowState.info => Icons.info_outline,
                    },
                    size: 18,
                    color: switch (row.state) {
                      _RowState.pass => SitewiseColors.success,
                      _RowState.pending => SitewiseColors.warning,
                      _RowState.info => SitewiseColors.muted,
                    },
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(row.label, style: const TextStyle(fontSize: 15)),
                        if (row.state == _RowState.info && row.info != null)
                          Text(
                            row.info!,
                            style: const TextStyle(
                              color: SitewiseColors.muted,
                              fontSize: 12,
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (row.state == _RowState.pending && row.actionLabel != null)
                    TextButton.icon(
                      onPressed: row.onAction,
                      icon: const Icon(Icons.arrow_forward_rounded, size: 14),
                      label: Text(
                        row.actionLabel!,
                        style: const TextStyle(fontSize: 12),
                      ),
                      style: TextButton.styleFrom(
                        foregroundColor: SitewiseColors.action,
                        minimumSize: const Size(48, 48),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 6),
            ],
            const SizedBox(height: 6),
            // The Submit to Admin button is a MAIN preview action rendered
            // below this card (§6) — the card only explains what is missing.
            if (!eligible)
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text(
                  'Submit to Admin will sync the panorama if needed.',
                  style: TextStyle(color: SitewiseColors.muted, fontSize: 12),
                ),
              ),
          ],
        ),
      ),
    );
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

/// What the Recapture dialog returned (§8).
enum _RecaptureChoice { retakeTargets, newAttempt }

/// One row of the Final Verification Review.
class _ReviewRow {
  const _ReviewRow({
    required this.label,
    required this.state,
    this.actionLabel,
    this.onAction,
    this.info,
  });

  final String label;
  final _RowState state;
  final String? actionLabel;
  final VoidCallback? onAction;
  final String? info;
}

enum _RowState {
  /// Verified by real saved data or a backend confirmation.
  pass,

  /// Not yet verified — the row shows its missing-item action.
  pending,

  /// Determined only at submission time by the backend; shown as neutral
  /// information, never as a checkmark.
  info,
}

/// Renders the canonical panorama for one backend panorama id.
///
/// The viewing URL is minted fresh on every load and expires, so a 401/403
/// from storage is answered by asking the backend for a new URL once — not by
/// retrying the stale link — before the honest failure is shown. A network
/// problem is a retry, never a fabricated image.
class _CanonicalPanoramaBox extends StatefulWidget {
  const _CanonicalPanoramaBox({super.key, required this.panoramaId});

  final String panoramaId;

  @override
  State<_CanonicalPanoramaBox> createState() => _CanonicalPanoramaBoxState();
}

class _CanonicalPanoramaBoxState extends State<_CanonicalPanoramaBox> {
  bool _loading = true;
  Uint8List? _bytes;
  String? _failure;
  bool _reResolvedExpiredUrl = false;

  static const _timeout = Duration(seconds: 20);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failure = null;
    });
    try {
      final url = await ServiceLocator.panoramaViews.viewUrl(widget.panoramaId);
      final response = await http.get(Uri.parse(url)).timeout(_timeout);
      if (!mounted) return;
      final status = response.statusCode;
      if (status == 200 && response.bodyBytes.isNotEmpty) {
        setState(() {
          _bytes = response.bodyBytes;
          _loading = false;
        });
        return;
      }
      if (status == 401 || status == 403) {
        // Signed URLs expire. One fresh mint is the fix; failing again
        // immediately means the link is being revoked, not aged.
        if (!_reResolvedExpiredUrl) {
          _reResolvedExpiredUrl = true;
          return _load();
        }
        setState(() {
          _loading = false;
          _failure = 'The Sitewise panorama link is not usable right now.';
        });
        return;
      }
      setState(() {
        _loading = false;
        _failure =
            'The Sitewise panorama could not be reached '
            '(server said $status).';
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failure =
            'A network problem stopped the Sitewise panorama from loading: '
            '${readableFailure(error, fallback: 'connection error')}';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const ColoredBox(
        color: Colors.black,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    final bytes = _bytes;
    if (bytes == null) {
      return ColoredBox(
        color: Colors.black,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off_outlined, color: Colors.white70),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Text(
                  _failure ?? 'The Sitewise panorama could not be loaded.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ),
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: _load,
                icon: const Icon(Icons.refresh_rounded, size: 16),
                label: const Text('Try again'),
              ),
            ],
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: MobileSwipePanorama(bytes: bytes)),
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: TextButton.icon(
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => PanoramaFullscreenPage(bytes: bytes),
                ),
              );
            },
            icon: const Icon(Icons.fullscreen_rounded, size: 16),
            label: const Text('View Full Screen'),
            style: TextButton.styleFrom(
              foregroundColor: Colors.white70,
              minimumSize: const Size(48, 48),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
        ),
      ],
    );
  }
}
