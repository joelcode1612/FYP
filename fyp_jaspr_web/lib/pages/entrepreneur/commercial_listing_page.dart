import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/ui.dart';
import '../../data/app_locator.dart';
import '../../layouts/app_layout.dart';

/// The **verified commercial listing** behind one recommendation.
///
/// This is deliberately NOT the Property Insights page. Two different
/// identifiers address two different records:
///
/// * `?id=MD-00510`  — the research catalogue unit (insights, SHAP, evidence)
/// * `?id=14823`     — the numeric `fyp.rental_properties` listing (this page)
///
/// They are related only through `fyp.property_subject_links` where
/// `match_verified` is true, and the recommendation payload already resolved
/// that link. Treating one id as the other is exactly how a card ends up
/// linking to a record that does not exist.
///
/// Data comes from `GET /api/v1/explore/properties/{id}`, which returns 404
/// for a listing that is not approved **and** published. A pending or
/// withdrawn listing is therefore indistinguishable from an absent one — by
/// design, so this page can never leak an unpublished rental as available.
@client
class CommercialListingPage extends StatefulComponent {
  /// The numeric listing id from `?id=`.
  final String id;

  const CommercialListingPage({super.key, required this.id});

  @override
  State<CommercialListingPage> createState() => _CommercialListingPageState();
}

class _CommercialListingPageState extends State<CommercialListingPage> {
  late final Future<ExplorePropertyDetail?> _future = _load(component.id);

  static Future<ExplorePropertyDetail?> _load(String raw) async {
    final id = int.tryParse(raw.trim());
    // A canonical EP-/MD- id can never address a rental listing. Fail here
    // rather than issuing a request that the backend would 422 on.
    if (id == null || id <= 0) return null;
    try {
      return await AppLocator.exploreRepo.detail('$id');
    } catch (_) {
      return null;
    }
  }

  @override
  Component build(BuildContext context) {
    return AppLayout(
      role: AppRole.entrepreneur,
      currentRoute: '/entrepreneur/listing',
      title: 'Commercial listing',
      eyebrow: 'Listing',
      subtitle: 'The verified rental listing linked to this recommendation.',
      actions: const [
        ActionLink(
          'Back to AI recommendations',
          href: '/entrepreneur/ai-recommendations',
          variant: 'secondary',
        ),
      ],
      child: FutureBuilder<ExplorePropertyDetail?>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return div(classes: 'loading', [
              span(classes: 'spinner', []),
              Component.text('Loading listing…'),
            ]);
          }
          final detail = snap.data;
          if (detail == null) {
            return EmptyState(
              title: 'This listing is not available',
              body:
                  'It is not approved and published, so it cannot be shown as '
                  'a rental. The research insights for this location are still '
                  'available from the recommendation card.',
              action: ActionLink(
                'Back to AI recommendations',
                href: '/entrepreneur/ai-recommendations',
                variant: 'primary',
              ),
            );
          }
          return _body(detail);
        },
      ),
    );
  }

  Component _body(ExplorePropertyDetail detail) {
    final prop = detail.property;
    final photos = detail.photos;
    final amenities = detail.amenities;
    return div(classes: 'stack', styles: Styles(raw: {'gap': '20px'}), [
      section(classes: 'panel', [
        div(classes: 'panel-head panel-head--split', [
          h2([Component.text(prop.title.isEmpty ? prop.id : prop.title)]),
          span(classes: 'pill', [
            Component.text(prop.verification.label),
          ]),
        ]),
        p(classes: 'what', [
          Component.text(_addressLine(prop.address, prop.city, prop.state, prop.postcode)),
        ]),
        div(classes: 'metrics-row', [
          _metric('Monthly rental', _rm(prop.rentalRm, prop.rentalMaxRm)),
          _metric('Floor area', '${_thousands(prop.sizeSqft)} sq ft'),
          _metric(
            'Property type',
            prop.propertyType.isEmpty ? 'not recorded' : prop.propertyType,
          ),
        ]),
        if (prop.description != null && prop.description!.trim().isNotEmpty) ...[
          h3([Component.text('Description')]),
          p(classes: 'what', [Component.text(prop.description!.trim())]),
        ],
        h3([Component.text('Listing facts')]),
        ul([
          _fact('Availability', prop.availability),
          _fact('Floor level', _level(prop.floorLevel)),
          _fact('Furnishing', prop.furnishing),
          _fact('Tenure', prop.tenure),
        ]),
      ]),
      section(classes: 'panel', [
        h2([Component.text('Photos')]),
        if (photos.isEmpty)
          p(classes: 'what', [
            Component.text(
              'This listing has no stored photographs. Nothing is substituted '
              'to fill the gap.',
            ),
          ])
        else
          div(classes: 'gallery-strip', [
            for (final photo in photos.take(6))
              img(
                src: photo.url,
                alt: prop.title.isEmpty ? 'Listing photo' : prop.title,
                styles: Styles(raw: {
                  'width': '100%',
                  'max-width': '260px',
                  'border-radius': '10px',
                  'object-fit': 'cover',
                }),
              ),
          ]),
      ]),
      if (amenities != null)
        section(classes: 'panel', [
          h2([Component.text('Recorded amenities')]),
          ul([
            _fact('Suitable for', amenities.suitableFor),
            _fact('Amenities', amenities.amenities),
            _fact('Nearby landmarks', amenities.nearbyLandmarks),
            _fact('Remarks', amenities.remarks),
          ]),
        ]),
      if (detail.listingSources.isNotEmpty)
        section(classes: 'panel', [
          h2([Component.text('Where this listing came from')]),
          ul([
            for (final source in detail.listingSources)
              li([
                Component.text(
                  [
                    source.platform ?? 'source not recorded',
                    if (source.availability != null) source.availability!,
                    if (source.url != null) source.url!,
                  ].join(' · '),
                ),
              ]),
          ]),
        ]),
    ]);
  }

  static Component _metric(String label, String value) => div(classes: 'metric', [
        span(classes: 'metric-label', [Component.text(label)]),
        span(classes: 'metric-value', [Component.text(value)]),
      ]);

  /// A fact that is genuinely absent is reported as not recorded, never as a
  /// zero or an empty string presented as data.
  static Component _fact(String label, String? value) => li([
        Component.text('$label: '),
        Component.text(
          (value == null || value.trim().isEmpty) ? 'not recorded' : value,
        ),
      ]);

  static String _rm(double low, double high) {
    final a = _thousands(low);
    if (high > low) return 'RM $a – RM ${_thousands(high)}';
    return 'RM $a';
  }

  /// Thousands separators, because "RM 11000" reads as a data dump rather than
  /// a price.
  static String _thousands(double value) {
    final whole = value.toStringAsFixed(0);
    final buffer = StringBuffer();
    for (var i = 0; i < whole.length; i++) {
      final remaining = whole.length - i;
      buffer.write(whole[i]);
      if (remaining > 1 && remaining % 3 == 1) buffer.write(',');
    }
    return buffer.toString();
  }

  /// `floor_level` is stored numerically for some rows ("12") and as text for
  /// others ("Ground"). A whole number must not surface as "12.0".
  static String? _level(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    final asNumber = double.tryParse(raw.trim());
    if (asNumber != null && asNumber == asNumber.roundToDouble()) {
      return asNumber.toStringAsFixed(0);
    }
    return raw.trim();
  }

  /// Address segments are joined once each: the source address often already
  /// ends with the city, which produced "USJ 9, Subang Jaya, Subang Jaya".
  static String _addressLine(
    String address,
    String city,
    String state,
    String postcode,
  ) {
    final parts = <String>[];
    for (final raw in [address, postcode, city, state]) {
      final part = raw.trim();
      if (part.isEmpty) continue;
      final lower = part.toLowerCase();
      final duplicate = parts.any(
        (existing) =>
            existing.toLowerCase() == lower ||
            existing.toLowerCase().endsWith(', $lower'),
      );
      if (!duplicate) parts.add(part);
    }
    return parts.join(', ');
  }
}
