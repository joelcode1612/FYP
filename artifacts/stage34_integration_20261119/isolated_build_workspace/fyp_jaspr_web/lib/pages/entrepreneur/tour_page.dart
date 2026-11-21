import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/ui.dart';
import '../../data/app_locator.dart';
import '../../layouts/app_layout.dart';

/// Web 360° tour, laid out as the source's `tour.html`.
///
/// ```text
/// .page-head      "Virtual tour" · property title · address · tour date
/// .detail-grid
///   .tour-stage   pano · drag hint · zoom/reset controls
///   .panel        Property at a glance (.kv) · badges · actions · disclaimer
/// ```
///
/// The viewer is a **static placeholder**: the Flutter `Panorama` widget has no
/// web counterpart and captured frames are not reachable from the web runtime,
/// matching the `AppLocator.tourService` note. What is real is the tour's
/// metadata, the property summary and the honesty notice — the source says the
/// panorama is synthetic, and so does this page.
@client
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
      eyebrow: 'Virtual tour',
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
                  return const _Empty();
                }
                return _TourBody(tour: tour, propertyId: id);
              },
            ),
    );
  }
}

class _TourBody extends StatelessComponent {
  final VirtualTour tour;
  final String propertyId;

  const _TourBody({required this.tour, required this.propertyId});

  @override
  Component build(BuildContext context) {
    return FutureBuilder<CommercialProperty?>(
      future: AppLocator.properties.detail(propertyId),
      builder: (c, psnap) {
        final prop = psnap.data;
        return div(classes: 'detail-grid', [
          // --- Viewer ------------------------------------------------------
          div([
            div(classes: 'tour-stage', [
              div(
                classes: 'pano',
                attributes: const {
                  'style':
                      'background-image:linear-gradient(120deg,#dbe3ee,#eef2f7 40%,'
                      '#dbe3ee 70%,#e8eef6);',
                },
                [],
              ),
              span(classes: 'tour-hint', [
                Component.text('Drag to look around'),
              ]),
              div(classes: 'tour-controls', [
                button(
                  attributes: const {'type': 'button'},
                  [Component.text('−')],
                ),
                button(
                  attributes: const {'type': 'button'},
                  [Component.text('+')],
                ),
                button(
                  attributes: const {'type': 'button'},
                  [Component.text('Reset')],
                ),
              ]),
            ]),
            div(classes: 'notice notice-info', [
              Component.text(
                'Static preview — the interactive panorama requires the mobile '
                'app. Scene 1 of ${tour.sceneCount}, captured '
                '${tour.capturedAt.day}/${tour.capturedAt.month}/'
                '${tour.capturedAt.year}.',
              ),
            ]),
          ]),

          // --- Property at a glance ---------------------------------------
          section(classes: 'panel', [
            h2([Component.text('Property at a glance')]),
            if (prop != null)
              dl(classes: 'kv', [
                _row('Monthly rent', prop.rentalDisplay, 'admin'),
                _row(
                  'Floor area',
                  '${prop.sizeSqft.toStringAsFixed(0)} sq ft',
                  'admin',
                ),
                _row('Type', prop.propertyType, 'owner'),
                _row('Tour scenes', '${tour.sceneCount}', 'owner'),
                _row(
                  'Tour status',
                  StatusBadge.tourLabel(tour.status),
                  'admin',
                ),
              ]),
            if (prop != null)
              div(classes: 'chips', [
                StatusBadge(
                  'Verification: ${prop.verification.label.toLowerCase()}',
                  tone: toneForVerification(prop.verification),
                ),
                StatusBadge(
                  'Suitability: ${prop.suitabilityScore.toStringAsFixed(0)}/100',
                  tone: 'action',
                ),
              ]),
            div(classes: 'actions-row', [
              ActionLink(
                'Full details',
                href: '/entrepreneur/property-detail?id=$propertyId',
                variant: 'primary',
              ),
              ActionLink(
                'Map',
                href: '/entrepreneur/explore?id=map',
                variant: 'secondary',
                icon: 'map',
              ),
              ActionLink(
                'Location report',
                href: '/entrepreneur/report?id=$propertyId',
                variant: 'secondary',
                icon: 'description',
              ),
            ]),
            p(classes: 'disclaimer', [
              Component.text(
                'A tour shows the space only. It does not confirm licensing, '
                'extraction or venting capacity, grease-trap provision, or '
                'expected revenue.',
              ),
            ]),
          ]),
        ]);
      },
    );
  }

  Component _row(String label, String value, String prov) => div([
    dt([Component.text(label)]),
    dd([Component.text(value)]),
    span([
      span(classes: 'prov prov-$prov', [
        Component.text(switch (prov) {
          'admin' => 'Admin verified',
          'owner' => 'Owner provided',
          'model' => 'Model output',
          _ => 'Demo value',
        }),
      ]),
    ]),
  ]);
}

class _Loading extends StatelessComponent {
  const _Loading();

  @override
  Component build(BuildContext context) => div(classes: 'loading', [
    span(classes: 'spinner', []),
    Component.text('Loading tour…'),
  ]);
}

class _Empty extends StatelessComponent {
  const _Empty();

  @override
  Component build(BuildContext context) => EmptyState(
    title: 'No tour for this unit',
    body:
        'The owner has not published a 360° tour yet. Visit the unit or check '
        'similar listings.',
    action: const ActionLink(
      'Back to explore',
      href: '/entrepreneur/explore',
      variant: 'primary',
    ),
  );
}

class _NotFound extends StatelessComponent {
  const _NotFound();

  @override
  Component build(BuildContext context) => EmptyState(
    title: 'Record not found',
    body:
        'This tour could not be loaded — the property id is missing or the '
        'listing is unavailable.',
    action: const ActionLink(
      'Back to explore',
      href: '/entrepreneur/explore',
      variant: 'primary',
    ),
  );
}
