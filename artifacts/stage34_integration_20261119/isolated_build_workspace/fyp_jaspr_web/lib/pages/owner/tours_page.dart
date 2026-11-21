import 'dart:async';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/ui.dart';
import '../../data/auth_service.dart';
import '../../layouts/app_layout.dart';

/// The signed-in owner id from the server-verified profile. Each navigation is
/// a fresh document, so the family argument is stable for the page's lifetime.
String _ownerId() => WebAuth.profile?['user_id'] as String? ?? '';

/// Owner 360° tours, laid out as the source's `sitewise-owner/tours.html`.
///
/// ```text
/// .page-head   "Virtual tours" · "360° tours" · explanation
/// .rows        .row-card  (media · title/address/status · actions)
/// .owner-note  the capture-sequence note
/// ```
///
/// The source shows one **row per listing's tour** with its status pill, the
/// station count and the two actions. The previous version used a 2-column grid
/// of large cards each embedding a dead "preview" placeholder, which made a
/// management list read like a gallery.
@client
class ToursPage extends StatefulComponent {
  const ToursPage({super.key});

  @override
  State<ToursPage> createState() => _ToursPageState();
}

class _ToursPageState extends State<ToursPage> {
  /// One-shot success notice (the Flutter SnackBar equivalent).
  String? _notice;

  /// Tour awaiting delete confirmation, or `null` when the dialog is closed.
  VirtualTour? _confirming;

  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      if (!mounted) return;
      unawaited(context.read(ownerNotifierProvider(_ownerId()).notifier).load());
    });
  }

  Future<void> _submit(VirtualTour tour) async {
    await context.read(ownerNotifierProvider(_ownerId()).notifier).submitTour(
      tour.id,
    );
    if (mounted) setState(() => _notice = 'Submitted for verification.');
  }

  Future<void> _delete(VirtualTour tour) async {
    setState(() => _confirming = null);
    await context.read(ownerNotifierProvider(_ownerId()).notifier).deleteTour(
      tour.id,
    );
    if (mounted) setState(() => _notice = 'Tour deleted.');
  }

  @override
  Component build(BuildContext context) {
    return AppLayout(
      role: AppRole.owner,
      currentRoute: '/owner/tours',
      title: '360° tours',
      eyebrow: 'Virtual tours',
      subtitle:
          'Each tour is captured for one property. Tours are only visible to '
          'entrepreneurs after an administrator approves them.',
      // Inside the layout, so submit/delete notifications rebuild only the
      // content, never the chrome.
      child: _Content(
        onRowDelete: (tour) => setState(() => _confirming = tour),
        confirming: _confirming,
        onConfirmDelete: () => _delete(_confirming!),
        onDialogCancel: () => setState(() => _confirming = null),
        notice: _notice,
        onNoticeSubmit: _submit,
      ),
    );
  }
}

/// The tour list, watching the owner state so submit/delete publishes rebuild
/// only this content, never the chrome.
class _Content extends StatelessComponent {
  const _Content({
    required this.onRowDelete,
    required this.confirming,
    required this.onConfirmDelete,
    required this.onDialogCancel,
    required this.notice,
    required this.onNoticeSubmit,
  });

  final void Function(VirtualTour tour) onRowDelete;
  final VirtualTour? confirming;
  final Future<void> Function() onConfirmDelete;
  final void Function() onDialogCancel;
  final String? notice;
  final Future<void> Function(VirtualTour tour) onNoticeSubmit;

  @override
  Component build(BuildContext context) {
    final state = context.watch(ownerNotifierProvider(_ownerId()));
    return state.loading
        ? const _Loading()
        : div(classes: 'stack stack--md', [
            if (notice != null)
              div(classes: 'notice notice-info', [Component.text(notice!)]),
            if (state.tours.isEmpty)
              EmptyState(
                title: 'No tours yet',
                body:
                    'Capture a 360° tour for a listing to help '
                    'entrepreneurs explore remotely. Capture runs in the '
                    'mobile app, where the camera is available.',
                action: const ActionLink(
                  'View my listings',
                  href: '/owner/properties',
                  variant: 'primary',
                ),
              )
            else
              div(classes: 'rows', [
                for (final tour in state.tours) _row(tour),
              ]),
            p(classes: 'owner-note', [
              Component.text(
                'A tour is captured as a fixed sequence of stations. The '
                'station count on each row comes from the tour record, not '
                'from a number hardcoded in the interface.',
              ),
            ]),
            if (confirming != null)
              _ConfirmDialog(onCancel: onDialogCancel, onConfirm: onConfirmDelete),
          ]);
  }

  Component _row(VirtualTour tour) {
    final status = tour.status;
    final canSubmit =
        status == VirtualTourStatus.draft || status == VirtualTourStatus.ready;
    return div(classes: 'row-card', [
      span(classes: 'row-media', [Icon('360', size: 'lg')]),
      div(classes: 'row-main', [
        h3([Component.text(tour.title)]),
        div(classes: 'meta', [
          Component.text(
            '${tour.sceneCount} scenes · captured '
            '${tour.capturedAt.day}/${tour.capturedAt.month}/'
            '${tour.capturedAt.year}',
          ),
        ]),
        div(classes: 'badges', [
          StatusBadge.forTour(status, dot: true),
          StatusBadge('${tour.frameCount} frames', tone: 'neutral'),
        ]),
        if (status == VirtualTourStatus.rejected)
          div(classes: 'notice notice-danger', [
            Component.text(
              'Rejected. Re-capture the stations flagged by the administrator '
              'and submit again.',
            ),
          ]),
      ]),
      div(classes: 'row-actions', [
        if (canSubmit)
          ActionButton(
            'Submit for verification',
            onClick: () => onNoticeSubmit(tour),
            icon: 'send',
          ),
        ActionLink(
          'Preview & manage',
          href: '/owner/tour-preview?id=${tour.id}',
          variant: 'secondary',
        ),
        ActionButton(
          'Delete',
          onClick: () => onRowDelete(tour),
          variant: 'danger-outline',
        ),
      ]),
    ]);
  }
}

class _Loading extends StatelessComponent {
  const _Loading();

  @override
  Component build(BuildContext context) => div(classes: 'loading', [
    span(classes: 'spinner', []),
    Component.text('Loading tours…'),
  ]);
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
            'The panorama and all captured frames will be permanently removed.',
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
