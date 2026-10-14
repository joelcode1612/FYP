import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/property_card.dart';
import '../../components/ui.dart';
import '../../data/app_locator.dart';
import '../../layouts/app_layout.dart';

/// Web listing detail: facts on the left, a static location panel on the right.
///
/// Ported from `admin_listing_detail_web_page.dart`. The Flutter page shows a
/// `SitewiseMapPanel` (a stylised painter, not a real map SDK); here the map
/// area is a static, clearly-labelled placeholder built from the existing
/// `visual visual--map` classes, with the pin coordinates kept visible.
class ListingDetailPage extends StatelessComponent {
  final String id;

  const ListingDetailPage({super.key, required this.id});

  @override
  Component build(BuildContext context) {
    return AppLayout(
      role: AppRole.admin,
      currentRoute: '/admin/listings',
      title: 'Listing detail',
      subtitle:
          'A single listing as submitted, with the details you need to decide whether it should be verified.',
      child: id.isEmpty
          ? _notFound()
          : FutureBuilder<CommercialProperty?>(
              future: AppLocator.properties.detail(id),
              builder: (context, snap) {
                if (snap.connectionState == ConnectionState.done &&
                    snap.data == null) {
                  return _notFound();
                }
                if (!snap.hasData) return _loading();
                return _body(snap.data!);
              },
            ),
    );
  }

  Component _loading() {
    return div(classes: 'card', [
      p(classes: 'body muted', [Component.text('Loading…')]),
    ]);
  }

  Component _notFound() {
    return div(classes: 'card stack', [
      span(classes: 'title', [Component.text('Record not found')]),
      p(classes: 'body', [
        Component.text(
          'No property matches this id. It may have been removed.',
        ),
      ]),
      const ActionLink(
        'Back to listings',
        href: '/admin/listings',
        variant: 'secondary',
      ),
    ]);
  }

  Component _body(CommercialProperty property) {
    return div(classes: 'grid-2', [
      div(classes: 'card stack', [
        div(classes: 'row', [
          span(classes: 'grow title', [Component.text(property.title)]),
          Pill(
            property.verification.label,
            tone: toneForVerification(property.verification),
          ),
        ]),
        p(classes: 'body', [
          Component.text(
            '${property.address}, ${property.postcode} '
            '${property.city}, ${property.state}',
          ),
        ]),
        div(classes: 'body', [
          Component.text(
            'RM${property.rentalRm.toStringAsFixed(0)} / '
            '${property.sizeSqft.toStringAsFixed(0)} sq ft · '
            '${property.propertyType}',
          ),
        ]),
      ]),
      _MapPanel(property: property),
    ]);
  }
}

/// Static stand-in for the Flutter `SitewiseMapPanel`. The painter it used is
/// Flutter-only; this keeps the pin label and coordinates visible and clearly
/// marks the area as a non-interactive preview.
class _MapPanel extends StatelessComponent {
  final CommercialProperty property;

  const _MapPanel({required this.property});

  @override
  Component build(BuildContext context) {
    return div(classes: 'card stack', [
      span(classes: 'overline', [Component.text('Location')]),
      div(classes: 'visual visual--map', [
        div(classes: 'visual__grid', []),
        span(classes: 'visual__pin', []),
        span(classes: 'visual__chip', [
          Icon('location_on', size: 'sm'),
          Component.text(property.title),
        ]),
      ]),
      div(classes: 'small muted', [
        Component.text(
          '${property.latitude.toStringAsFixed(4)}, '
          '${property.longitude.toStringAsFixed(4)} · Klang Valley & beyond',
        ),
      ]),
      div(classes: 'tiny muted', [
        Component.text(
          'Map preview — interactive map view requires the mobile app.',
        ),
      ]),
    ]);
  }
}
