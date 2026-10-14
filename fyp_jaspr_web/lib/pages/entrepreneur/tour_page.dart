import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/ui.dart';
import '../../data/app_locator.dart';
import '../../layouts/app_layout.dart';

/// Web 360° tour: large desktop viewer with a side scene list.
///
/// Ported from `entrepreneur_tour_web_page.dart` in the Flutter web tree. The
/// Flutter version renders a `Panorama` viewer (`WebTourViewer`) — a
/// Flutter-render widget that has no web counterpart — so the page shell,
/// tour metadata, property summary and scene list are ported in full and the
/// viewport itself is a clearly-labelled static placeholder. Frames captured
/// on mobile devices are not reachable from the web runtime, matching the
/// `AppLocator.tourService` note (no frame purge, mobile-only captures).
class TourPage extends StatelessComponent {
  /// The property id from the `?id=` query param.
  final String id;

  const TourPage({super.key, required this.id});

  @override
  Component build(BuildContext context) {
    return AppLayout(
      role: AppRole.entrepreneur,
      currentRoute: '/entrepreneur/tour',
      title: '360° tour',
      subtitle: 'Walk the site in 360° and jump between stations.',
      child: id.isEmpty
          ? const _NotFound()
          : FutureBuilder<VirtualTour?>(
              future: AppLocator.tourRepo.getTourByProperty(id),
              builder: (ctx, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const _Loading();
                }
                final tour = snap.data;
                if (tour == null) {
                  return const _Empty(
                    title: 'No tour for this unit',
                    message:
                        'The owner has not published a 360° tour yet. Visit '
                        'the unit or check similar listings.',
                  );
                }
                return div(classes: 'stack', [
                  div(classes: 'stack', [
                    h2(classes: 'title-xl', [Component.text(tour.title)]),
                    p(classes: 'small', [
                      Component.text(
                        '${tour.sceneCount} scenes · captured '
                        '${tour.capturedAt.day}/${tour.capturedAt.month}/'
                        '${tour.capturedAt.year}',
                      ),
                    ]),
                  ]),
                  div(classes: 'btn-row', [
                    Pill(
                      'Status: ${_statusLabel(tour.status)}',
                      tone: _statusTone(tour.status),
                    ),
                    Pill('${tour.frameCount} frames captured'),
                  ]),
                  _PropertySummary(propertyId: id),
                  _TourViewerPlaceholder(tour: tour),
                ]);
              },
            ),
    );
  }

  String _statusLabel(VirtualTourStatus status) => switch (status) {
    VirtualTourStatus.draft => 'Draft',
    VirtualTourStatus.processing => 'Processing',
    VirtualTourStatus.ready => 'Ready',
    VirtualTourStatus.pendingVerification => 'Pending verification',
    VirtualTourStatus.approved => 'Approved',
    VirtualTourStatus.rejected => 'Rejected',
  };

  String _statusTone(VirtualTourStatus status) => switch (status) {
    VirtualTourStatus.ready || VirtualTourStatus.approved => 'success',
    VirtualTourStatus.processing || VirtualTourStatus.pendingVerification => //
    'warning',
    VirtualTourStatus.rejected => 'danger',
    VirtualTourStatus.draft => 'neutral',
  };
}

/// Compact property summary card above the viewer (title, address line and
/// suitability score), matching the Flutter `_propertyCard`.
class _PropertySummary extends StatelessComponent {
  final String propertyId;
  const _PropertySummary({required this.propertyId});

  @override
  Component build(BuildContext context) {
    return FutureBuilder<CommercialProperty?>(
      future: AppLocator.properties.detail(propertyId),
      builder: (c, psnap) {
        if (!psnap.hasData || psnap.data == null)
          return div(classes: 'stack stack--sm', []);
        final p = psnap.data!;
        return div(classes: 'card row row--top', [
          div(classes: 'grow stack', [
            span(classes: 'title', [Component.text(p.title)]),
            span(classes: 'small', [
              Component.text(
                '${p.address}, ${p.city} · RM${p.rentalRm.toStringAsFixed(0)} · '
                '${p.sizeSqft.toStringAsFixed(0)} sq ft',
              ),
            ]),
          ]),
          span(classes: 'metric', [
            Component.text(p.suitabilityScore.toStringAsFixed(0)),
          ]),
        ]);
      },
    );
  }
}

/// Static placeholder for the Flutter `WebTourViewer` / `Panorama` viewport.
/// The scene list and "Scene N of M" caption keep the loaded tour data
/// visible; the interactive panorama itself requires the mobile app.
class _TourViewerPlaceholder extends StatelessComponent {
  final VirtualTour tour;
  const _TourViewerPlaceholder({required this.tour});

  @override
  Component build(BuildContext context) {
    return div(classes: 'row row--top row--sm', [
      div(classes: 'grow', [
        div(classes: 'card--dark stack', [
          Icon('threesixty', size: 'lg', label: '360 degree tour'),
          span(classes: 'title', [Component.text(tour.title)]),
          span(classes: 'small muted-on-dark', [
            Component.text('Scene 1 of ${tour.sceneCount}'),
          ]),
          span(classes: 'small muted-on-dark', [
            Component.text(
              '360° viewer — the interactive panorama requires the mobile '
              'app. This is a static preview of the tour.',
            ),
          ]),
        ]),
      ]),
      div(classes: 'w-20', [
        div(classes: 'card stack', [
          span(classes: 'overline', [Component.text('Scenes')]),
          ul(classes: 'stack', [
            for (var i = 0; i < tour.sceneCount; i++)
              li([Component.text('Scene ${i + 1}')]),
          ]),
        ]),
      ]),
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

class _Empty extends StatelessComponent {
  final String title;
  final String message;
  const _Empty({required this.title, required this.message});

  @override
  Component build(BuildContext context) {
    return div(classes: 'card stack', [
      span(classes: 'overline', [Component.text('360° tour')]),
      h2(classes: 'title-lg', [Component.text(title)]),
      p(classes: 'body', [Component.text(message)]),
    ]);
  }
}

class _NotFound extends StatelessComponent {
  const _NotFound();

  @override
  Component build(BuildContext context) {
    return div(classes: 'card stack', [
      span(classes: 'overline', [Component.text('360° tour')]),
      h2(classes: 'title-lg', [Component.text('Record not found')]),
      p(classes: 'body', [
        Component.text(
          'This tour could not be loaded — the property id is missing or the '
          'listing is unavailable.',
        ),
      ]),
      const ActionLink(
        'Back to explore',
        href: '/entrepreneur/explore',
        variant: 'secondary',
      ),
    ]);
  }
}
