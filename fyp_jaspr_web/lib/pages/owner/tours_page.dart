import 'dart:async';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/bloc.dart';
import '../../components/ui.dart';
import '../../data/app_locator.dart';
import '../../layouts/app_layout.dart';

/// Web 360° tours: property-picked capture workspace with per-tour preview,
/// submit-for-verification and delete with confirmation.
///
/// Ported from `owner_tours_web_page.dart` in the Flutter web tree. The
/// Flutter version rebuilds on `AppCubit` + `OwnerViewModel` and embeds a
/// `WebTourViewer` (a Panorama widget with no web build) in each card; this
/// version rebuilds on a per-page [OwnerCubit] and renders a labelled static
/// placeholder where the panorama viewport sat. Capture (`/owner/capture`)
/// resumes a live camera session on-device, so the capture buttons render as
/// disabled hints instead of navigating. Delete confirmation — a Flutter
/// dialog — becomes an inline `overlay` + `dialog` (the established pattern
/// from the topbar controls).
class ToursPage extends StatefulComponent {
  const ToursPage({super.key});

  @override
  State<ToursPage> createState() => _ToursPageState();
}

class _ToursPageState extends State<ToursPage> {
  late final OwnerCubit vm;

  /// One-shot success notice (the Flutter SnackBar equivalent).
  String? _notice;

  /// Tour awaiting delete confirmation, or `null` when the dialog is closed.
  VirtualTour? _confirming;

  @override
  void initState() {
    super.initState();
    vm = AppLocator.newOwnerCubit();
    unawaited(vm.load());
  }

  @override
  void dispose() {
    unawaited(vm.close());
    super.dispose();
  }

  Future<void> _submit(VirtualTour tour) async {
    await vm.submitTour(tour.id);
    if (mounted) setState(() => _notice = 'Submitted for verification.');
  }

  Future<void> _delete(VirtualTour tour) async {
    setState(() => _confirming = null);
    await vm.deleteTour(tour.id);
    if (mounted) setState(() => _notice = 'Tour deleted.');
  }

  @override
  Component build(BuildContext context) {
    return CubitBuilder<OwnerCubit, OwnerState>(
      cubit: vm,
      builder: (context, _) {
        return AppLayout(
          role: AppRole.owner,
          currentRoute: '/owner/tours',
          title: '360° Tours',
          subtitle: AppRole.owner.label,
          child: div(classes: 'stack', [
            div(classes: 'row row--top', [
              div(classes: 'grow stack', [
                h2(classes: 'title-lg', [
                  Component.text('Capture → arrange → preview → publish'),
                ]),
                p(classes: 'small', [
                  Component.text(
                    'Capture a 360° tour for a listing to help entrepreneurs '
                    'explore remotely.',
                  ),
                ]),
              ]),
              const ActionButton(
                'Capture new tour (AR)',
                onClick: null,
                icon: 'camera_alt',
              ),
              span(classes: 'small muted', [
                Component.text('Capture runs in the mobile app'),
              ]),
            ]),
            if (_notice != null)
              div(classes: 'card', [
                p(classes: 'body text-success', [Component.text(_notice!)]),
              ]),
            if (vm.loading)
              const _Loading()
            else if (vm.tours.isEmpty)
              const _EmptyTours()
            else
              div(classes: 'grid-2', [
                for (final tour in vm.tours)
                  _TourCard(
                    tour: tour,
                    onSubmit: () => _submit(tour),
                    onDelete: () => setState(() => _confirming = tour),
                  ),
              ]),
            if (_confirming != null)
              _ConfirmDialog(
                onCancel: () => setState(() => _confirming = null),
                onConfirm: () => _delete(_confirming!),
              ),
          ]),
        );
      },
    );
  }
}

class _TourCard extends StatelessComponent {
  final VirtualTour tour;
  final void Function() onSubmit;
  final void Function() onDelete;

  const _TourCard({
    required this.tour,
    required this.onSubmit,
    required this.onDelete,
  });

  @override
  Component build(BuildContext context) {
    final status = tour.status;
    final canSubmit =
        status == VirtualTourStatus.draft || status == VirtualTourStatus.ready;
    return div(classes: 'card stack', [
      div(classes: 'row', [
        h3(classes: 'title grow', [Component.text(tour.title)]),
        Pill(_statusLabel(status), tone: _statusTone(status)),
      ]),
      p(classes: 'small', [
        Component.text('${tour.sceneCount} scenes · ${_statusLabel(status)}'),
      ]),
      // The Flutter page embeds `WebTourViewer` (Panorama + scene list) here.
      // Panorama rendering is Flutter-plugin-bound, so this is a labelled
      // static placeholder per the porting guide.
      div(classes: 'card--flat stack', [
        span(classes: 'overline', [Component.text('360° preview')]),
        p(classes: 'small muted', [
          Component.text(
            'Interactive panorama preview requires the mobile app.',
          ),
        ]),
      ]),
      ActionLink(
        'Open preview & manage',
        href: '/owner/tour-preview?id=${tour.id}',
        variant: 'secondary',
        icon: 'preview',
      ),
      div(classes: 'btn-row', [
        if (canSubmit) ActionButton('Submit', onClick: onSubmit, icon: 'send'),
        ActionButton(
          'Delete',
          onClick: onDelete,
          variant: 'danger-outline',
          icon: 'delete_outline',
        ),
      ]),
    ]);
  }
}

/// Shared status vocabulary, matching the Flutter tours page's
/// `_statusLabel` / `_statusPill` mappings exactly.
String _statusLabel(VirtualTourStatus status) => switch (status) {
  VirtualTourStatus.draft => 'Draft',
  VirtualTourStatus.processing => 'Processing…',
  VirtualTourStatus.ready => 'Ready',
  VirtualTourStatus.pendingVerification => 'Pending verification',
  VirtualTourStatus.approved => 'Approved',
  VirtualTourStatus.rejected => 'Rejected',
};

String _statusTone(VirtualTourStatus status) => switch (status) {
  VirtualTourStatus.approved => 'success',
  VirtualTourStatus.pendingVerification ||
  VirtualTourStatus.processing => 'warning',
  VirtualTourStatus.rejected => 'danger',
  VirtualTourStatus.draft || VirtualTourStatus.ready => 'action',
};

class _Loading extends StatelessComponent {
  const _Loading();

  @override
  Component build(BuildContext context) {
    return div(classes: 'card', [
      p(classes: 'body muted', [Component.text('Loading…')]),
    ]);
  }
}

class _EmptyTours extends StatelessComponent {
  const _EmptyTours();

  @override
  Component build(BuildContext context) {
    return div(classes: 'card stack', [
      span(classes: 'icon-tile', [Icon('threesixty', size: 'lg')]),
      h3(classes: 'title', [Component.text('No tours yet')]),
      p(classes: 'body', [
        Component.text(
          'Capture a 360° tour for a listing to help entrepreneurs explore '
          'remotely.',
        ),
      ]),
      p(classes: 'small muted', [
        Component.text('Capture runs in the mobile app'),
      ]),
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
