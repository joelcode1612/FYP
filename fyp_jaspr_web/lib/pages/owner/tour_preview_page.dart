import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/ui.dart';
import '../../data/app_locator.dart';
import '../../layouts/app_layout.dart';

/// Web tour preview: large panorama beside the frame grid, with regenerate,
/// submit and delete.
///
/// Ported from `tour_preview_web_page.dart` in the Flutter web tree. The
/// Flutter version runs on `TourPreviewViewModel`, which drives the on-device
/// frame store, the panorama stitcher and the live capture session — none of
/// which exist in the browser. This version keeps the same page shell and
/// lifecycle actions against [TourService] directly: the tour record loads
/// via `tourById`, submit/delete call the same service methods, and the
/// panorama viewport and frame grid render as clearly-labelled static
/// placeholders (capture frames live only on the mobile app). Regenerate
/// reproduces the Flutter view-model's own frames<26 guard, which on web
/// always trips at 0/26 frames.
class TourPreviewPage extends StatefulComponent {
  final String id;

  const TourPreviewPage({super.key, required this.id});

  @override
  State<TourPreviewPage> createState() => _TourPreviewPageState();
}

class _TourPreviewPageState extends State<TourPreviewPage> {
  /// Re-fetchable tour future — recreated after submit so the status pill
  /// reflects the service round-trip.
  late Future<VirtualTour?> _tour;

  /// One-shot success notice (the Flutter SnackBar equivalent).
  String? _notice;

  /// Error text — mirrors `TourPreviewViewModel.error` (e.g. a submit
  /// refusal when the panorama is missing).
  String? _error;

  /// Tour awaiting delete confirmation, or `null` when the dialog is closed.
  bool _confirming = false;

  /// Set once delete succeeded — replaces the Flutter pop with an inline
  /// card linking back to the tours list.
  bool _deleted = false;

  @override
  void initState() {
    super.initState();
    _tour = AppLocator.tourService.tourById(component.id);
  }

  void _reload() {
    setState(() {
      _tour = AppLocator.tourService.tourById(component.id);
    });
  }

  Future<void> _submit(VirtualTour tour) async {
    try {
      await AppLocator.tourService.submitTour(tour.id);
      if (!mounted) return;
      setState(() {
        _notice = 'Submitted for verification.';
        _error = null;
      });
      _reload();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _delete(VirtualTour tour) async {
    try {
      await AppLocator.tourService.deleteTour(tour.id);
      if (!mounted) return;
      setState(() {
        _deleted = true;
        _confirming = false;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  /// The Flutter view-model's regenerate guard, minus the stitcher: frames
  /// are captured on-device, so the stored count is always 0 in the browser.
  void _regenerate() {
    setState(() {
      _error =
          'Panorama cannot be generated. Only 0/26 frames are stored. '
          'Capture frames in the mobile app.';
    });
  }

  @override
  Component build(BuildContext context) {
    return AppLayout(
      role: AppRole.owner,
      currentRoute: '/owner/tour-preview',
      title: 'Tour preview',
      subtitle:
          'Preview the 360° tour captured for this listing and manage its scenes.',
      child: _deleted
          ? _DeletedCard()
          : component.id.isEmpty
          // Also the SSR guard: static generation renders this route
          // without query params, and jaspr forbids non-null futures
          // during server rendering (same pattern as the entrepreneur
          // detail pages).
          ? const _NotFound()
          : FutureBuilder<VirtualTour?>(
              future: _tour,
              builder: (ctx, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const _Loading();
                }
                final tour = snap.data;
                if (tour == null) return const _NotFound();
                return _PreviewBody(
                  tour: tour,
                  notice: _notice,
                  error: _error,
                  confirming: _confirming,
                  onRegenerate: _regenerate,
                  onSubmit: () => _submit(tour),
                  onDelete: () => setState(() => _confirming = true),
                  onCancelConfirm: () => setState(() => _confirming = false),
                  onConfirmDelete: () => _delete(tour),
                );
              },
            ),
    );
  }
}

class _PreviewBody extends StatelessComponent {
  final VirtualTour tour;
  final String? notice;
  final String? error;
  final bool confirming;

  final void Function() onRegenerate;
  final void Function() onSubmit;
  final void Function() onDelete;
  final void Function() onCancelConfirm;
  final void Function() onConfirmDelete;

  const _PreviewBody({
    required this.tour,
    required this.notice,
    required this.error,
    required this.confirming,
    required this.onRegenerate,
    required this.onSubmit,
    required this.onDelete,
    required this.onCancelConfirm,
    required this.onConfirmDelete,
  });

  @override
  Component build(BuildContext context) {
    final status = tour.status;
    final canSubmit =
        status == VirtualTourStatus.ready || status == VirtualTourStatus.draft;
    return div(classes: 'stack', [
      div(classes: 'card row row--top', [
        div(classes: 'grow stack', [
          h2(classes: 'title-lg', [Component.text(tour.title)]),
          p(classes: 'small', [
            Component.text('${tour.frameCount} frames captured'),
          ]),
        ]),
        Pill(_statusLabel(status), tone: _statusTone(status)),
      ]),
      if (notice != null)
        p(classes: 'body text-success', [Component.text(notice!)]),
      _Panorama(panoramaPath: tour.panoramaPath),
      h3(classes: 'title', [Component.text('Frames (${tour.frameCount}/26)')]),
      const _FrameGrid(),
      if (error != null)
        p(classes: 'body text-danger', [Component.text(error!)]),
      div(classes: 'btn-row', [
        ActionButton(
          'Regenerate panorama',
          onClick: onRegenerate,
          variant: 'secondary',
          icon: 'auto_awesome',
        ),
        if (canSubmit)
          ActionButton(
            'Submit for verification',
            onClick: onSubmit,
            icon: 'send',
          ),
        ActionButton(
          'Delete tour',
          onClick: onDelete,
          variant: 'danger-outline',
          icon: 'delete_outline',
        ),
      ]),
      if (confirming)
        _ConfirmDialog(onCancel: onCancelConfirm, onConfirm: onConfirmDelete),
    ]);
  }
}

/// Panorama viewport — the Flutter version loads the stitched bytes and hands
/// them to the `Panorama` widget (plugin-bound, no web build). Both branches
/// of the Flutter `_panorama` (no file yet / file present) render as labelled
/// static placeholders.
class _Panorama extends StatelessComponent {
  final String? panoramaPath;

  const _Panorama({required this.panoramaPath});

  @override
  Component build(BuildContext context) {
    if (panoramaPath == null) {
      return div(classes: 'card', [
        p(classes: 'body', [
          Component.text('Generate the panorama to preview it here.'),
        ]),
      ]);
    }
    return div(classes: 'card stack', [
      span(classes: 'overline', [Component.text('360° panorama')]),
      p(classes: 'body muted', [
        Component.text(
          '360° viewer — interactive panorama requires the mobile app.',
        ),
      ]),
    ]);
  }
}

/// Frame thumbnails — captured frames exist only in the mobile app's local
/// frame store, so the browser shows the Flutter empty branch plus a note.
class _FrameGrid extends StatelessComponent {
  const _FrameGrid();

  @override
  Component build(BuildContext context) {
    return div(classes: 'card stack', [
      p(classes: 'body', [Component.text('No frames stored yet.')]),
      p(classes: 'small muted', [
        Component.text(
          'Frames are captured in the mobile app; retakes resume the live '
          'capture session there.',
        ),
      ]),
    ]);
  }
}

/// Preview-page status vocabulary — identical colours to the tours list but
/// with the longer labels the Flutter preview page uses.
String _statusLabel(VirtualTourStatus status) => switch (status) {
  VirtualTourStatus.draft => 'Draft',
  VirtualTourStatus.processing => 'Processing…',
  VirtualTourStatus.ready => 'Ready for submission',
  VirtualTourStatus.pendingVerification => 'Pending verification',
  VirtualTourStatus.approved => 'Approved',
  VirtualTourStatus.rejected => 'Rejected — retake and resubmit',
};

String _statusTone(VirtualTourStatus status) => switch (status) {
  VirtualTourStatus.approved => 'success',
  VirtualTourStatus.pendingVerification ||
  VirtualTourStatus.processing => 'warning',
  VirtualTourStatus.rejected => 'danger',
  VirtualTourStatus.draft || VirtualTourStatus.ready => 'action',
};

class _DeletedCard extends StatelessComponent {
  @override
  Component build(BuildContext context) {
    return div(classes: 'card stack', [
      span(classes: 'overline', [Component.text('Deleted')]),
      p(classes: 'body text-success', [Component.text('Tour deleted.')]),
      const ActionLink(
        'Back to 360° tours',
        href: '/owner/tours',
        variant: 'secondary',
      ),
    ]);
  }
}

class _NotFound extends StatelessComponent {
  const _NotFound();

  @override
  Component build(BuildContext context) {
    return div(classes: 'card stack', [
      span(classes: 'overline', [Component.text('360° Tour')]),
      h2(classes: 'title-lg', [Component.text('Tour not found')]),
      p(classes: 'body', [
        Component.text('This virtual tour is no longer available.'),
      ]),
      const ActionLink(
        'Back to 360° tours',
        href: '/owner/tours',
        variant: 'secondary',
      ),
    ]);
  }
}

class _Loading extends StatelessComponent {
  const _Loading();

  @override
  Component build(BuildContext context) {
    return div(classes: 'card', [
      p(classes: 'body muted', [Component.text('Loading…')]),
    ]);
  }
}

class _ConfirmDialog extends StatelessComponent {
  final void Function() onCancel;
  final void Function() onConfirm;

  const _ConfirmDialog({required this.onCancel, required this.onConfirm});

  @override
  Component build(BuildContext context) {
    return div(classes: 'overlay', events: events(onClick: onCancel), [
      div(classes: 'dialog', events: events(onClick: () {}), [
        div(classes: 'dialog__title', [Component.text('Delete this tour?')]),
        p(classes: 'body', [
          Component.text(
            'The panorama and all captured frames will be permanently '
            'removed.',
          ),
        ]),
        div(classes: 'btn-row', [
          ActionButton('Cancel', onClick: onCancel, variant: 'secondary'),
          ActionButton('Delete', onClick: onConfirm, variant: 'danger-outline'),
        ]),
      ]),
    ]);
  }
}
