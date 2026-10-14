import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/property_card.dart';
import '../../components/ui.dart';
import '../../data/app_locator.dart';
import '../../layouts/app_layout.dart';

/// Web owner property detail: listing and map on the left, management
/// actions on the right.
///
/// Ported from `owner_property_detail_web_page.dart` in the Flutter web tree.
/// The Flutter version reads the property through
/// `ServiceLocator.properties.detail(propertyId)` and submits through the
/// same service; this version uses [AppLocator.properties]. Detail ids travel
/// as `?id=` instead of `settings.arguments`.
///
/// Flutter-only pieces: the map panel (plugin-bound) renders as a labelled
/// placeholder with the pin coordinates, and the post-submit SnackBar + pop
/// becomes an inline success card with a link back to the list — the page
/// itself stays put, which is the web-native equivalent.
class PropertyDetailPage extends StatefulComponent {
  final String id;

  const PropertyDetailPage({super.key, required this.id});

  @override
  State<PropertyDetailPage> createState() => _PropertyDetailPageState();
}

class _PropertyDetailPageState extends State<PropertyDetailPage> {
  /// `true` once "Submit for verification" succeeded — replaces the Flutter
  /// SnackBar + Navigator.pop with an inline success card.
  bool _submitted = false;

  @override
  Component build(BuildContext context) {
    return AppLayout(
      role: AppRole.owner,
      currentRoute: '/owner/property-detail',
      title: 'Property detail',
      subtitle: AppRole.owner.label,
      child: _submitted
          ? _SubmittedCard()
          : component.id.isEmpty
          // Also the SSR guard: static generation renders this route
          // without query params, and jaspr forbids non-null futures
          // during server rendering (same pattern as the entrepreneur
          // detail pages).
          ? _NotFound(id: component.id)
          : FutureBuilder<CommercialProperty?>(
              future: AppLocator.properties.detail(component.id),
              builder: (ctx, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const _Loading();
                }
                final p = snap.data;
                if (p == null) return _NotFound(id: component.id);
                return _DetailBody(
                  property: p,
                  onSubmit: () async {
                    await AppLocator.properties.submit(p.id);
                    if (mounted) setState(() => _submitted = true);
                  },
                );
              },
            ),
    );
  }
}

class _DetailBody extends StatelessComponent {
  final CommercialProperty property;
  final void Function() onSubmit;

  const _DetailBody({required this.property, required this.onSubmit});

  @override
  Component build(BuildContext context) {
    final prop = property;
    return div(classes: 'row row--top', [
      div(classes: 'w-60', [
        div(classes: 'card stack', [
          div(classes: 'row', [
            h2(classes: 'title-lg grow', [Component.text(prop.title)]),
            Pill(
              prop.verification.label,
              tone: toneForVerification(prop.verification),
            ),
          ]),
          p(classes: 'body', [
            Component.text(
              '${prop.address}, ${prop.postcode} ${prop.city}, ${prop.state}',
            ),
          ]),
          p(classes: 'body', [
            Component.text(
              'RM${prop.rentalRm.toStringAsFixed(0)} · '
              '${prop.sizeSqft.toStringAsFixed(0)} sq ft · '
              '${prop.propertyType}',
            ),
          ]),
          _MapPanel(
            latitude: prop.latitude,
            longitude: prop.longitude,
            label: prop.title,
          ),
        ]),
      ]),
      div(classes: 'grow', []),
      div(classes: 'w-35', [
        div(classes: 'card stack', [
          h3(classes: 'title', [Component.text('Manage listing')]),
          ActionLink(
            'Edit listing',
            href: '/owner/add-property?id=${prop.id}',
            variant: 'secondary',
            icon: 'edit',
          ),
          if (prop.verification == VerificationStatus.draft)
            ActionButton(
              'Submit for verification',
              onClick: onSubmit,
              icon: 'send',
            ),
        ]),
      ]),
    ]);
  }
}

/// Static stand-in for `SitewiseMapPanel` — the Flutter version draws a map
/// through a plugin that has no web build. The pin coordinates stay visible
/// so the panel still communicates what the map would show.
class _MapPanel extends StatelessComponent {
  final double latitude;
  final double longitude;
  final String label;

  const _MapPanel({
    required this.latitude,
    required this.longitude,
    required this.label,
  });

  @override
  Component build(BuildContext context) {
    return div(classes: 'card--flat stack', [
      span(classes: 'overline', [Component.text('Location')]),
      p(classes: 'small muted', [
        Component.text('Map view requires the mobile app.'),
      ]),
      p(classes: 'small', [
        Component.text(
          '$label · ${latitude.toStringAsFixed(4)}, '
          '${longitude.toStringAsFixed(4)}',
        ),
      ]),
    ]);
  }
}

class _SubmittedCard extends StatelessComponent {
  @override
  Component build(BuildContext context) {
    return div(classes: 'card stack', [
      span(classes: 'overline', [Component.text('Submitted')]),
      p(classes: 'body text-success', [
        Component.text('Submitted for verification.'),
      ]),
      const ActionLink(
        'Back to my properties',
        href: '/owner/properties',
        variant: 'secondary',
      ),
    ]);
  }
}

class _NotFound extends StatelessComponent {
  final String id;
  const _NotFound({required this.id});

  @override
  Component build(BuildContext context) {
    return div(classes: 'card stack', [
      span(classes: 'overline', [Component.text('Property')]),
      h2(classes: 'title-lg', [Component.text('Record not found')]),
      p(classes: 'body', [
        Component.text('No listing matches the requested id.'),
      ]),
      p(classes: 'small muted', [Component.text('Requested record id: $id')]),
      const ActionLink(
        'Back to my properties',
        href: '/owner/properties',
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
