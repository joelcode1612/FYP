import 'dart:async';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/ui.dart';
import '../../components/location_evidence_panel.dart';
import '../../components/property_leaflet_map.dart';
import '../../data/app_locator.dart';
import '../../data/location_evidence_api.dart';
import '../../layouts/app_layout.dart';

/// Web property detail, laid out as the source's `property.html`.
///
/// ```text
/// .page-head        eyebrow · h1 · address · verification/suitability badges
/// .detail-grid
///   .analysis       Gallery · Listing information (.kv) · Description
///   .analysis       Actions · Map location · What is not shown
/// ```
///
/// The previous version stacked `.card`s inside a `row`/`w-35` split: no
/// definition list, no gallery, no provenance chips and no "what is not shown"
/// panel — the last of which is the page's honesty contract, not decoration.
///
/// Data honesty rules carried over from the source:
///  * a missing value is labelled, never printed as 0 or invented;
///  * provenance is shown next to each fact;
///  * the score is a relative indicator and always carries the disclaimer.
@client
class PropertyDetailPage extends StatefulComponent {
  /// The property id from the `?id=` query param.
  final String id;

  const PropertyDetailPage({super.key, required this.id});

  @override
  State<PropertyDetailPage> createState() => _PropertyDetailPageState();
}

class _PropertyDetailPageState extends State<PropertyDetailPage> {
  String? _saveMessage;
  bool _compareLinkShown = false;

  /// The listing load, created once per id so a rebuild never re-requests it.
  ///
  /// Resolution order: the catalogue first (`EP-xxxxx` ids — the id space the
  /// saved-list and assessment backends require), then, for numeric ids, the
  /// live Explore detail (`/explore/properties/{id}`, the
  /// `fyp.rental_properties` universe). Unknown ids resolve to null and the
  /// page renders its not-found state; nothing is fabricated in between.
  Future<PropertyDetailLoad?>? _detailFuture;

  /// Source-backed location evidence (`/catalog/properties/{id}/evidence`).
  /// Only catalogue ids carry the subject-feature evidence API; a numeric
  /// rental id gets the honest "no verified mapping" state instead of an
  /// unverified cross-dataset join.
  Future<PropertyEvidence>? _evidenceFuture;

  Future<PropertyDetailLoad?> _load(String id) async {
    final catalog = await AppLocator.properties.detail(id);
    if (catalog != null) {
      return PropertyDetailLoad(
        property: catalog,
        imageUrls: catalog.imageUrls,
        source: 'catalog',
      );
    }
    if (int.tryParse(id) != null) {
      try {
        final detail = await AppLocator.exploreRepo.detail(id);
        return PropertyDetailLoad(
          property: detail.property,
          imageUrls: [for (final photo in detail.photos) photo.url],
          source: 'explore',
        );
      } on Object {
        return null; // Unknown or unpublished numeric id → not found.
      }
    }
    return null;
  }

  /// Saves/removes the shortlist bookmark. A signed-in account persists to
  /// the server first — the message and the bookmark both state what the
  /// account actually holds, so a failed request reports itself instead of
  /// pretending to have saved. A visitor keeps the cookie-backed selection.
  Future<void> _toggleSaved(String id) async {
    final notifier = context.read(appNotifierProvider.notifier);
    if (!AppLocator.isSignedIn) {
      notifier.toggleSaved(id);
      final nowSaved = context.read(appNotifierProvider).saved.contains(id);
      setState(() {
        _saveMessage = nowSaved
            ? 'Saved to your shortlist.'
            : 'Removed from saved.';
      });
      return;
    }
    final savedNow = context.read(appNotifierProvider).saved.contains(id);
    final failure = await AppLocator.persistToggleSaved(
      id,
      wantSaved: !savedNow,
    );
    if (!mounted) return;
    if (failure != null) {
      setState(() {
        _saveMessage =
            'Could not ${savedNow ? 'remove' : 'save'} — ${failure.message} '
            'Your shortlist was not changed.';
      });
      return;
    }
    notifier.toggleSaved(id);
    setState(() {
      _saveMessage = savedNow
          ? 'Removed from your saved properties.'
          : 'Saved to your shortlist on your account.';
    });
  }

  @override
  void initState() {
    super.initState();
    final id = component.id;
    if (id.isNotEmpty) {
      _detailFuture = _load(id);
      _evidenceFuture = LocationEvidenceApi.load(
        id,
        catalog: int.tryParse(id) == null,
      );
      Future.microtask(() {
        if (!mounted) return;
        unawaited(
          context.read(entrepreneurNotifierProvider.notifier).loadAnalysis(id),
        );
      });
    }
  }

  @override
  Component build(BuildContext context) {
    final saved = context.watch(appNotifierProvider.select((app) => app.saved));
    final compared = context.watch(
      appNotifierProvider.select((app) => app.compared),
    );

    // The header carries the property's own title and address, so it is
    // rendered inside the future rather than by `AppLayout`.
    return AppLayout(
      role: AppRole.entrepreneur,
      currentRoute: '/entrepreneur/property-detail',
      title: 'Property',
      eyebrow: 'Property',
      showPageHead: false,
      child: component.id.isEmpty
          ? const _NotFound()
          : FutureBuilder<PropertyDetailLoad?>(
              future: _detailFuture,
              builder: (c, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const _Loading();
                }
                // `hasData` is false for both "pending" and "completed
                // with null", so the null case needs its own branch —
                // otherwise an unknown id spins forever.
                final load = snap.data;
                if (load == null) return const _NotFound();
                final p = load.property;
                return _Detail(
                  property: p,
                  imageUrls: load.imageUrls,
                  source: load.source,
                  evidenceFuture: _evidenceFuture,
                  saved: saved.contains(p.id),
                  compared: compared.contains(p.id),
                  saveMessage: _saveMessage,
                  compareLinkShown: _compareLinkShown,
                  onToggleSaved: () => _toggleSaved(p.id),
                  onToggleCompared: () {
                    context
                        .read(appNotifierProvider.notifier)
                        .toggleCompared(p.id);
                    final nowCompared = context
                        .read(appNotifierProvider)
                        .compared
                        .contains(p.id);
                    setState(() => _compareLinkShown = nowCompared);
                  },
                );
              },
            ),
    );
  }
}

/// One resolved detail load: the entity plus the photo urls the backend
/// served for it. [source] is the id universe that answered — 'catalog' for
/// the imported workbook, 'explore' for the approved-and-published
/// `fyp.rental_properties` rows — shown as provenance, never mixed up.
class PropertyDetailLoad {
  final CommercialProperty property;
  final List<String> imageUrls;
  final String source;

  const PropertyDetailLoad({
    required this.property,
    required this.imageUrls,
    required this.source,
  });
}

class _Detail extends StatelessComponent {
  final CommercialProperty property;

  /// Photo URLs the backend returned for this listing; empty is a genuine
  /// "no photographs" state.
  final List<String> imageUrls;
  final String source;

  /// Evidence load for the preview panel; null only when the page has no id.
  final Future<PropertyEvidence>? evidenceFuture;
  final bool saved;
  final bool compared;
  final String? saveMessage;
  final bool compareLinkShown;
  final void Function() onToggleSaved;
  final void Function() onToggleCompared;

  const _Detail({
    required this.property,
    required this.imageUrls,
    required this.source,
    required this.evidenceFuture,
    required this.saved,
    required this.compared,
    required this.onToggleSaved,
    required this.onToggleCompared,
    this.saveMessage,
    this.compareLinkShown = false,
  });

  /// Provenance of a listing fact.
  ///
  /// The source tags each row `admin` or `owner`. The target carries one
  /// verifiable signal — [CommercialProperty.verification] — so an approved
  /// listing's rent/area/availability are labelled "Admin verified" and every
  /// owner-supplied attribute is labelled "Owner provided". Nothing is claimed
  /// as verified unless the listing actually is.
  bool get _adminVerified =>
      property.verification == VerificationStatus.verified;

  String get _addressLine =>
      '${property.address}, ${property.postcode} ${property.city}, '
      '${property.state}';

  @override
  Component build(BuildContext context) {
    return div(classes: 'sw-pd', [
      PageHead(
        eyebrow: 'Property',
        title: property.title,
        description: _addressLine,
        badges: [
          StatusBadge(
            'Verification: ${property.verification.label.toLowerCase()}',
            tone: toneForVerification(property.verification),
          ),
          // The suitability badge renders only when a research score exists —
          // printing 0/100 would present "not calculated" as a measured value.
          if (property.hasSuitabilityScore)
            StatusBadge(
              'Suitability: ${property.suitabilityScore.toStringAsFixed(0)}/100',
              tone: _scoreTone(property.suitabilityScore),
            ),
        ],
      ),
      div(classes: 'sw-pd__layout', [
        // --- Main column: facts and source-backed analysis -------------------
        div(classes: 'sw-pd__main', [
          _galleryPanel(),
          _listingPanel(),
          LocationEvidencePreview(
            future: evidenceFuture,
            propertyId: property.id,
          ),
          _descriptionPanel(),
        ]),
        // --- Side column: score, map, actions, caveats ------------------------
        div(classes: 'sw-pd__side', [
          _scorePanel(),
          _mapPanel(),
          _actionsPanel(),
          _notShownPanel(),
        ]),
      ]),
    ]);
  }

  // ------------------------------------------------------- imported score

  Component _scorePanel() {
    // The gauge renders only when a research score exists — an absent score
    // must never present as a 0/100 measurement.
    final available = property.hasSuitabilityScore;
    final clamped = property.suitabilityScore.clamp(0.0, 100.0);
    return section(classes: 'panel sw-pd__score-panel', [
      span(classes: 'sw-pd__eyebrow', [Component.text('PROPERTY SCORE')]),
      h2([Component.text('Location suitability index')]),
      if (available) ...[
        div(classes: 'sw-pd__score-row', [
          strong(classes: 'sw-pd__score-number', [
            Component.text(property.suitabilityScore.toStringAsFixed(0)),
          ]),
          span(classes: 'sw-pd__score-max', [Component.text('/ 100')]),
        ]),
        div(classes: 'sw-pd__score-track', [
          div(
            classes: 'sw-pd__score-fill',
            attributes: {'style': 'width:${clamped.toStringAsFixed(1)}%'},
            [],
          ),
        ]),
        p(classes: 'sw-pd__footnote', [
          Component.text(
            'Imported research index. This is not a calibrated PU '
            'business-success probability or a personalized recommendation '
            'score.',
          ),
        ]),
      ] else
        p(classes: 'small', [
          Component.text(
            'No measured suitability index is available for this listing.',
          ),
        ]),
      ActionLink(
        'View measured analysis',
        href:
            '/entrepreneur/property-analysis?id=${Uri.encodeComponent(property.id)}',
        variant: 'secondary',
        icon: 'analytics',
      ),
    ]);
  }

  // ------------------------------------------------------------------ gallery

  Component _galleryPanel() {
    // Photo URLs come from the backend's own records (property_photos for the
    // explore universe, the catalogue image_url otherwise). No URL is a real
    // state — the caption says so rather than styling a placeholder as data.
    final url = imageUrls.isNotEmpty ? imageUrls.first : property.imageUrl;
    return section(classes: 'panel', [
      h2([Component.text('Gallery')]),
      div(classes: 'gallery', [
        if (url != null)
          Component.element(
            tag: 'img',
            attributes: {
              'src': url,
              'alt': property.title,
              'loading': 'lazy',
              'referrerpolicy': 'no-referrer',
              'style': 'width:100%;height:100%;object-fit:cover',
            },
          )
        else
          span(classes: 'cover', [Icon('storefront', size: 'lg')]),
      ]),
      p(classes: 'disclaimer', [
        Component.text(
          url == null
              ? 'No image URL is available for this property.'
              : 'Source listing image. Availability depends on the original '
                    'image host.',
        ),
      ]),
    ]);
  }

  // ------------------------------------------------------------ listing facts

  Component _listingPanel() {
    final admin = StatusBadge('Admin verified', tone: 'success');
    final owner = StatusBadge('Owner provided', tone: 'neutral');

    return section(classes: 'panel', [
      h2([Component.text('Listing information')]),
      dl(classes: 'kv', [
        _row(
          'Monthly rent',
          property.rentalDisplay,
          _adminVerified ? admin : owner,
        ),
        _row(
          'Floor area',
          '${property.sizeSqft.toStringAsFixed(0)} sq ft',
          _adminVerified ? admin : owner,
        ),
        _row('Property type', property.propertyType, owner),
        // Observed availability from the backend record when it exists;
        // "Not recorded" is the honest fallback — never an invented status.
        _row(
          'Availability',
          property.availability ?? 'Not recorded',
          property.availability != null && _adminVerified ? admin : owner,
        ),
        if (property.tenure != null) _row('Tenure', property.tenure!, owner),
        if (property.furnishing != null)
          _row('Furnishing', property.furnishing!, owner),
        if (property.floorLevel != null)
          _row('Floor level', property.floorLevel!, owner),
        if (property.bathrooms != null)
          _row('Bathrooms', '${property.bathrooms}', owner),
        if (property.isFnbSuitable != null)
          _row('F&B suitable', property.isFnbSuitable! ? 'Yes' : 'No', owner),
        if (property.hasParking != null)
          _row('Parking', property.hasParking! ? 'Yes' : 'No', owner),
        if (property.isCornerLot != null)
          _row('Corner lot', property.isCornerLot! ? 'Yes' : 'No', owner),
        if (property.isFreehold != null)
          _row('Freehold', property.isFreehold! ? 'Yes' : 'No', owner),
        _row(
          'Rental efficiency',
          'RM${property.rentalPerSqft.toStringAsFixed(2)} / sq ft',
          owner,
        ),
        _row(
          'Coordinates',
          property.hasCoordinates
              ? '${property.latitude.toStringAsFixed(4)}, '
                    '${property.longitude.toStringAsFixed(4)}'
              : 'Not recorded',
          owner,
        ),
        _row(
          'Research link',
          property.hasResearchLink ? 'Verified' : 'None',
          owner,
        ),
        _row(
          '360° tour',
          property.hasTour ? 'Published' : 'Not available',
          property.hasTour ? admin : owner,
        ),
      ]),
    ]);
  }

  Component _row(String label, String value, Component prov) => div([
    dt([Component.text(label)]),
    dd([Component.text(value)]),
    span([prov]),
  ]);

  // -------------------------------------------------------------- description

  Component _descriptionPanel() {
    // The backend's own description takes precedence; the composed summary is
    // the fallback and derives only from fields actually present.
    final description = (property.description?.trim().isNotEmpty ?? false)
        ? property.description!
        : '${property.title} is a ${property.propertyType.toLowerCase()} of '
              '${property.sizeSqft.toStringAsFixed(0)} sq ft in '
              '${property.city}, ${property.state}, offered at '
              '${property.rentalDisplay} per month.';
    return section(classes: 'panel', [
      h2([Component.text('Description')]),
      p(classes: 'body', [Component.text(description)]),
      if (property.requirements.isNotEmpty || property.tags.isNotEmpty)
        div(classes: 'chips', [
          for (final r in property.requirements)
            span(classes: 'tag ml', [Component.text(r)]),
          for (final t in property.tags)
            span(classes: 'tag det', [Component.text(t)]),
        ]),
      span(classes: 'prov prov-owner', [
        Component.text(
          source == 'explore' ? 'Explore listing' : 'Owner provided',
        ),
      ]),
    ]);
  }

  // ------------------------------------------------------------------ actions

  Component _actionsPanel() {
    return section(classes: 'panel', [
      h2([Component.text('Actions')]),
      div(classes: 'actions-row', [
        // The assessment workspace is the decision-support entry point, so it
        // leads. One primary action per row: the analysis link drops to
        // secondary rather than competing with it.
        ActionLink(
          'Assess this property',
          href: '/entrepreneur/assessment?id=${property.id}',
          icon: 'fact_check',
        ),
        ActionLink(
          'Explore location analysis',
          href: '/entrepreneur/explore?id=${property.id}',
          variant: 'secondary',
          icon: 'map',
        ),
        ActionLink(
          'Full property analysis',
          href:
              '/entrepreneur/property-analysis?id=${Uri.encodeComponent(property.id)}',
          variant: 'secondary',
          icon: 'analytics',
        ),
        ActionLink(
          'Why this score',
          href: '/entrepreneur/explanation?property=${property.id}',
          variant: 'secondary',
        ),
        ActionButton(
          saved ? 'Saved ✓' : 'Save favourite',
          variant: 'secondary',
          icon: saved ? 'bookmark' : 'bookmark_border',
          onClick: onToggleSaved,
        ),
        ActionButton(
          compared ? 'In compare ✓' : 'Add to compare',
          variant: 'secondary',
          icon: 'compare_arrows',
          onClick: onToggleCompared,
        ),
        if (property.hasTour)
          ActionLink(
            'Open 360° tour',
            href: '/entrepreneur/tour?id=${property.id}',
            variant: 'secondary',
            icon: '360',
          ),
        ActionLink(
          'Location report',
          href: '/entrepreneur/report?id=${property.id}',
          variant: 'secondary',
          icon: 'description',
        ),
      ]),
      if (saveMessage != null)
        span(classes: 'small text-success', [Component.text(saveMessage!)]),
      if (compareLinkShown && compared)
        ActionLink(
          'Open compare',
          href: '/entrepreneur/compare',
          variant: 'ghost',
        ),
    ]);
  }

  // ---------------------------------------------------------------------- map

  Component _mapPanel() => section(classes: 'panel sw-pd__map-panel', [
    h2([Component.text('Map & nearby properties')]),
    PropertyLeafletMap(property: property, height: 330),
    p(classes: 'sw-pd__footnote', [
      Component.text(
        'Interactive Leaflet map, CARTO/OSM tiles, 500 m and 1 km straight-line '
        'catchments. Nearby pins are the 955 research reference properties, not '
        'F&B competitors. Coordinates can be approximate.',
      ),
    ]),
    ActionLink(
      'Open full location analysis',
      href:
          '/entrepreneur/property-analysis?id=${Uri.encodeComponent(property.id)}',
      variant: 'secondary',
      icon: 'map',
    ),
  ]);

  // ----------------------------------------------------------- not shown list

  Component _notShownPanel() {
    // The source's honesty contract for this page: the things the system
    // deliberately does not claim.
    return section(classes: 'panel', [
      h2([Component.text('What is not shown')]),
      ul([
        li([
          Component.text(
            'Regulatory status (licensing, extraction, venting, grease trap) — '
            'not verified by this system.',
          ),
        ]),
        li([
          Component.text(
            'Revenue, footfall or customer-volume forecasts — this system does '
            'not produce them.',
          ),
        ]),
        li([
          Component.text(
            'Owner contact details and internal verification notes.',
          ),
        ]),
      ]),
      p(classes: 'disclaimer', [
        Component.text(
          'A suitability score is a relative decision-support indicator. It is '
          'not a probability of business success, a revenue forecast, regulatory '
          'approval, or a guarantee of any kind.',
        ),
      ]),
    ]);
  }

  static String _scoreTone(double score) {
    if (score >= 75) return 'success';
    if (score >= 55) return 'action';
    if (score >= 40) return 'warning';
    return 'danger';
  }
}

class _Loading extends StatelessComponent {
  const _Loading();

  @override
  Component build(BuildContext context) => div(classes: 'loading', [
    span(classes: 'spinner', []),
    Component.text('Loading property…'),
  ]);
}

class _NotFound extends StatelessComponent {
  const _NotFound();

  @override
  Component build(BuildContext context) => div([
    const PageHead(
      eyebrow: 'Property',
      title: 'Record not found',
      description: 'This property could not be loaded.',
    ),
    EmptyState(
      title: 'No property selected',
      body:
          'This property could not be loaded. It may have been removed, or the '
          'link is incomplete.',
      action: const ActionLink(
        'Browse properties',
        href: '/entrepreneur/explore',
        variant: 'primary',
      ),
    ),
  ]);
}
