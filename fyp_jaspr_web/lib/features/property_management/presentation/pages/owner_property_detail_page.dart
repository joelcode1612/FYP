import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import 'package:sitewise_jaspr_web/shared/presentation/components/ui.dart';
import 'package:sitewise_jaspr_web/core/di/app_locator.dart';
import 'package:sitewise_jaspr_web/shared/presentation/layouts/app_layout.dart';

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
@client
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

  /// The server's own sentence when the submission was refused (e.g. 409 for
  /// a listing already in review) — shown instead of a success card.
  String? _submitError;

  /// Strips wrapper prefixes so the backend's sentence is what the owner
  /// reads (same convention as the entrepreneur wizard).
  static String _cleanError(Object error) {
    var raw = error.toString();
    raw = raw.replaceFirst(
      RegExp(r'^((Bad state|Exception|Error|StateError)(\([^)]*\))?):\s*'),
      '',
    );
    final trimmed = raw.trim();
    return trimmed.isEmpty ? 'The submission could not be completed.' : trimmed;
  }

  @override
  Component build(BuildContext context) {
    return AppLayout(
      role: AppRole.owner,
      currentRoute: '/owner/property-detail',
      title: 'Property detail',
      eyebrow: 'Listing status',
      subtitle:
          'The full record for this listing, including its verification state.',
      child: _submitted
          ? _SubmittedCard()
          : component.id.isEmpty
          // Also the SSR guard: static generation renders this route
          // without query params, and jaspr forbids non-null futures
          // during server rendering (same pattern as the entrepreneur
          // detail pages).
          ? _NotFound(id: component.id)
          : FutureBuilder<OwnerListing>(
              future: AppLocator.ownerListings.getListing(component.id),
              builder: (ctx, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const _Loading();
                }
                final p = snap.data;
                if (p == null) return _NotFound(id: component.id);
                return Component.fragment([
                  if (_submitError != null)
                    div(classes: 'notice notice-danger', [
                      Component.text(_submitError!),
                    ]),
                  _DetailBody(
                    property: p,
                    onSubmit: () async {
                      // Listing-scope submission through the unified
                      // workflow: this page manages no ownership documents,
                      // so ownership stays `not_submitted` and only the
                      // listing accuracy dimension enters admin review.
                      try {
                        await AppLocator.propertyVerificationRepo.submit(
                          p.id,
                          scope: 'listing',
                        );
                        if (mounted) {
                          setState(() {
                            _submitted = true;
                            _submitError = null;
                          });
                        }
                      } catch (error) {
                        if (mounted) {
                          setState(() => _submitError = _cleanError(error));
                        }
                      }
                    },
                  ),
                ]);
              },
            ),
    );
  }
}

class _DetailBody extends StatelessComponent {
  final OwnerListing property;
  final void Function() onSubmit;

  const _DetailBody({required this.property, required this.onSubmit});

  @override
  Component build(BuildContext context) {
    final prop = property;
    // Source `property-status.html`: a `.detail-grid` with the listing facts as
    // a `.kv` table on the left and the management actions on the right.
    return div(classes: 'detail-grid', [
      div(classes: 'analysis', [
        section(classes: 'panel', [
          h2([Component.text(prop.name)]),
          div(classes: 'chips', [
            StatusBadge(
              prop.status.label,
              tone: toneForVerification(prop.status),
              dot: true,
            ),
          ]),
          dl(classes: 'kv', [
            _row(
              'Address',
              [prop.address, prop.city, prop.state, prop.postcode]
                  .whereType<String>()
                  .where((v) => v.trim().isNotEmpty)
                  .join(', '),
            ),
            _row('State', prop.state ?? 'Not provided'),
            _row(
              'Monthly rent',
              prop.rentalPrice == null
                  ? 'Not provided'
                  : 'RM ${prop.rentalPrice!.toStringAsFixed(2)}',
            ),
            _row(
              'Built-up area',
              prop.sizeSqft == null
                  ? 'Not provided'
                  : '${prop.sizeSqft!.toStringAsFixed(0)} sq ft',
            ),
            _row(
              'Rental per sq ft',
              prop.psf == null
                  ? 'Not available'
                  : 'RM ${prop.psf!.toStringAsFixed(2)} / sq ft',
            ),
            _row('Property type', prop.propertyType ?? 'Not provided'),
            _row('Floor level', prop.floorDescription ?? 'Not provided'),
            _row('Unit position', prop.unitPosition ?? 'Not provided'),
            _row(
              'Shop frontage',
              prop.frontageFt == null
                  ? 'Not provided'
                  : '${prop.frontageFt!.toStringAsFixed(1)} ft',
            ),
            _row('Furnishing', prop.furnishing ?? 'Not provided'),
            _row(
              'Owner-declared parking',
              prop.hasParking == null
                  ? 'Not sure'
                  : prop.hasParking!
                  ? 'Available'
                  : 'Not available',
            ),
            _row(
              'Minimum rental period',
              prop.leaseDurationNegotiable == true
                  ? 'Negotiable'
                  : prop.leaseDurationMonths == null
                  ? 'Not provided'
                  : '${prop.leaseDurationMonths} months',
            ),
            _row('Availability', prop.availability ?? 'Not provided'),
            _row('Available from', prop.availableFrom ?? 'Not applicable'),
            _row(
              'Rental deposit',
              prop.rentalDepositMyr == null
                  ? 'Not provided'
                  : 'RM ${prop.rentalDepositMyr!.toStringAsFixed(2)}',
            ),
            _row('Land tenure', prop.tenure ?? 'Not provided'),
            _row('Title type', prop.titleType ?? 'Not provided'),
            _row(
              'Landlord F&B permission (owner-declared)',
              prop.landlordFnbPermission ?? 'Not provided',
            ),
          ]),
        ]),
        section(classes: 'panel', [
          h2([Component.text('Location')]),
          _MapPanel(
            latitude: prop.latitude,
            longitude: prop.longitude,
            label: prop.name,
          ),
        ]),
      ]),
      div(classes: 'analysis', [
        section(classes: 'panel', [
          h2([Component.text('Manage listing')]),
          div(classes: 'actions-row', [
            if (prop.locallyEditable)
              ActionLink(
                'Edit listing',
                href: '/owner/add-property?id=${prop.id}',
                variant: 'secondary',
                icon: 'edit',
              ),
          ]),
          // Draft AND rejected listings can (re)submit: the backend refuses
          // transitions that are not open with its own 409 sentence, which
          // renders verbatim in the notice above.
          if (prop.status == VerificationStatus.draft ||
              prop.status == VerificationStatus.rejected)
            ActionButton(
              'Submit for verification',
              onClick: onSubmit,
              icon: 'send',
            ),
          if (prop.status != VerificationStatus.draft)
            p(classes: 'small', [
              Component.text(
                'This listing is already in the verification process. An '
                'administrator records the decision.',
              ),
            ]),
        ]),
      ]),
    ]);
  }

  /// One definition-list row: label + value.
  Component _row(String label, String value) => div([
    dt([Component.text(label)]),
    dd([Component.text(value)]),
    span([]),
  ]);
}

/// Static stand-in for `SitewiseMapPanel` — the Flutter version draws a map
/// through a plugin that has no web build. The pin coordinates stay visible
/// so the panel still communicates what the map would show.
class _MapPanel extends StatelessComponent {
  final double? latitude;
  final double? longitude;
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
          latitude == null || longitude == null
              ? '$label · Coordinates not available'
              : '$label · ${latitude!.toStringAsFixed(4)}, ${longitude!.toStringAsFixed(4)}',
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
