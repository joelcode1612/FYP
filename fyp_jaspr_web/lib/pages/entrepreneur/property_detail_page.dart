import 'dart:async';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/property_detail/location_insights.dart';
import '../../components/property_leaflet_map.dart';
import '../../components/ui.dart';
import '../../data/app_locator.dart';
import '../../data/full_analysis_actions_browser.dart';
import '../../data/location_evidence_api.dart';
import '../../layouts/app_layout.dart';

/// Entrepreneur property detail — V4 layout.
///
/// ```text
/// hero        gallery (arrows/count/dots) + summary (facts, price, actions)
/// details     expandable property details
/// score       circular PU research index + category overview
/// insights    five categories · 500 m / 1 km · analysis panel + sidebar
/// tour        integrated 360° panel (published tour only)
/// supporting  map · what is not shown
/// ```
///
/// Data honesty: every value comes from the catalogue/explore record or the
/// subject-feature evidence API. A missing value is labelled, never printed
/// as 0; the research index is never presented as a success probability.
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
  Future<PropertyDetailLoad?>? _detailFuture;
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

  Future<void> _toggleSaved(String id) async {
    final notifier = context.read(appNotifierProvider.notifier);
    if (!AppLocator.isSignedIn) {
      notifier.toggleSaved(id);
      final nowSaved = context.read(appNotifierProvider).saved.contains(id);
      setState(() {
        _saveMessage = nowSaved ? 'Saved to your shortlist.' : 'Removed from saved.';
      });
      return;
    }
    final savedNow = context.read(appNotifierProvider).saved.contains(id);
    final failure = await AppLocator.persistToggleSaved(id, wantSaved: !savedNow);
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
                final load = snap.data;
                if (load == null) return const _NotFound();
                final p = load.property;
                return _Detail(
                  key: ValueKey('detail-${p.id}'),
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
/// served for it. [source] is the id universe that answered.
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

class _Detail extends StatefulComponent {
  final CommercialProperty property;
  final List<String> imageUrls;
  final String source;
  final Future<PropertyEvidence>? evidenceFuture;
  final bool saved;
  final bool compared;
  final String? saveMessage;
  final bool compareLinkShown;
  final void Function() onToggleSaved;
  final void Function() onToggleCompared;

  const _Detail({
    super.key,
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

  @override
  State<_Detail> createState() => _DetailState();
}

class _DetailState extends State<_Detail> {
  int _image = 0;
  bool _detailsOpen = false;
  String? _copyMessage;

  CommercialProperty get property => component.property;
  List<String> get imageUrls => component.imageUrls;
  String get source => component.source;
  bool get saved => component.saved;
  bool get compared => component.compared;
  String? get saveMessage => component.saveMessage;
  bool get compareLinkShown => component.compareLinkShown;
  void Function() get onToggleSaved => component.onToggleSaved;
  void Function() get onToggleCompared => component.onToggleCompared;

  String get _addressLine =>
      '${property.address}, ${property.postcode} ${property.city}, '
      '${property.state}';

  List<String> get _images {
    final urls = imageUrls.where((url) => url.trim().isNotEmpty).toList();
    if (urls.isNotEmpty) return urls;
    final single = property.imageUrl;
    return single != null && single.trim().isNotEmpty ? [single] : const [];
  }

  String _summary() => [
        property.title,
        _addressLine,
        '${property.rentalDisplay} per month',
        '${property.sizeSqft.toStringAsFixed(0)} sq ft',
        property.propertyType,
        if (property.floorLevel != null) 'Floor ${property.floorLevel}',
        if (property.availability != null) property.availability!,
      ].join(' · ');

  Future<void> _copySummary() async {
    final ok = await copyText(_summary());
    if (!mounted) return;
    setState(() {
      _copyMessage = ok ? 'Property summary copied.' : 'Copy is unavailable in this browser.';
    });
  }

  @override
  Component build(BuildContext context) {
    return div(classes: 'sw-v4', [
      _hero(),
      _detailsPanel(),
      _scoreCards(),
      LocationInsightsV4(
        key: ValueKey('insights-${property.id}'),
        propertyId: property.id,
        puScore: property.hasSuitabilityScore ? property.suitabilityScore : null,
        hasPuScore: property.hasSuitabilityScore,
      ),
      _tourSection(),
      div(classes: 'sw-v4__support', [
        _mapPanel(),
        _notShownPanel(),
      ]),
    ]);
  }

  // -------------------------------------------------------------------- hero

  Component _media() {
    final images = _images;
    return div(classes: 'sw-v4__media', [
      if (images.isEmpty)
        div(classes: 'sw-v4__media-empty', [
          Icon('storefront', size: 'lg', label: 'No photograph recorded'),
          span([Component.text('No photograph recorded for this listing.')]),
        ])
      else
        Component.element(
          tag: 'img',
          attributes: {
            'src': images[_image.clamp(0, images.length - 1)],
            'alt': '${property.title} — photograph ${_image + 1} of ${images.length}',
            'referrerpolicy': 'no-referrer',
          },
        ),
      if (images.length > 1) ...[
        div(classes: 'sw-v4__count', [
          Component.text('${_image + 1} / ${images.length}'),
        ]),
        button(
          classes: 'sw-v4__nav sw-v4__nav--prev',
          attributes: {'type': 'button', 'aria-label': 'Previous photograph'},
          events: {
            'click': (e) => setState(
              () => _image = (_image - 1 + images.length) % images.length,
            ),
          },
          [Component.text('‹')],
        ),
        button(
          classes: 'sw-v4__nav sw-v4__nav--next',
          attributes: {'type': 'button', 'aria-label': 'Next photograph'},
          events: {
            'click': (e) => setState(() => _image = (_image + 1) % images.length),
          },
          [Component.text('›')],
        ),
        div(classes: 'sw-v4__dots', [
          for (var i = 0; i < images.length; i++)
            button(
              classes: i == _image ? 'sw-v4__dot is-on' : 'sw-v4__dot',
              attributes: {'type': 'button', 'aria-label': 'Photograph ${i + 1}'},
              events: {'click': (e) => setState(() => _image = i)},
              const [],
            ),
        ]),
      ],
    ]);
  }

  Component _fact(String label, String? value) => div(classes: 'sw-v4__fact', [
        span(classes: 'sw-v4__fact-label', [Component.text(label)]),
        span(
          classes: value == null || value.trim().isEmpty
              ? 'sw-v4__fact-value is-absent'
              : 'sw-v4__fact-value',
          [Component.text(value == null || value.trim().isEmpty ? 'Not available' : value)],
        ),
      ]);

  Component _hero() => div(classes: 'sw-v4__hero', [
        div(classes: 'sw-v4__gallery', [
          _media(),
          if (property.hasTour)
            ActionLink(
              'View 360° tour',
              href: '#sw-v4-tour',
              variant: 'secondary',
              icon: '360',
            ),
        ]),
        div(classes: 'sw-v4__summary', [
          div(classes: 'sw-v4__badges', [
            StatusBadge(
              'Verification: ${property.verification.label.toLowerCase()}',
              tone: toneForVerification(property.verification),
            ),
            if (property.availability != null)
              StatusBadge(property.availability!, tone: 'neutral'),
          ]),
          h1(classes: 'sw-v4__title', [Component.text(property.title)]),
          p(classes: 'sw-v4__addr', [Component.text(_addressLine)]),
          div(classes: 'sw-v4__price', [
            strong([Component.text(property.rentalDisplay)]),
            span([Component.text('/ month')]),
          ]),
          div(classes: 'sw-v4__facts', [
            _fact('Floor space', '${property.sizeSqft.toStringAsFixed(0)} sq ft'),
            _fact('Floor', property.floorLevel),
            _fact('Property type', property.propertyType),
            _fact('Availability', property.availability),
          ]),
          p(classes: 'sw-v4__desc', [
            Component.text(
              (property.description?.trim().isNotEmpty ?? false)
                  ? property.description!
                  : '${property.title} is a ${property.propertyType.toLowerCase()} '
                        'of ${property.sizeSqft.toStringAsFixed(0)} sq ft in '
                        '${property.city}, ${property.state}.',
            ),
          ]),
          div(classes: 'sw-v4__actions', [
            ActionButton(
              'Copy property summary',
              variant: 'secondary',
              icon: 'content_copy',
              onClick: _copySummary,
            ),
            ActionButton(
              saved ? 'Saved' : 'Save property',
              variant: saved ? 'ghost' : 'primary',
              icon: saved ? 'bookmark' : 'bookmark_border',
              onClick: onToggleSaved,
            ),
            ActionButton(
              compared ? 'In compare' : 'Add to compare',
              variant: 'secondary',
              icon: 'compare_arrows',
              onClick: onToggleCompared,
            ),
            ActionLink(
              'Assess this property',
              href: '/entrepreneur/assessment?id=${property.id}',
              variant: 'secondary',
              icon: 'fact_check',
            ),
          ]),
          if (saveMessage != null)
            span(classes: 'small text-success', [Component.text(saveMessage!)]),
          if (_copyMessage != null) span(classes: 'small', [Component.text(_copyMessage!)]),
          if (compareLinkShown && compared)
            ActionLink('Open compare', href: '/entrepreneur/compare', variant: 'ghost'),
        ]),
      ]);

  // ----------------------------------------------------------------- details

  Component _detailRow(String label, String? value) => div(classes: 'sw-v4__detail-row', [
        span([Component.text(label)]),
        span(
          classes: value == null || value.trim().isEmpty ? 'is-absent' : null,
          [Component.text(value == null || value.trim().isEmpty ? 'Not available' : value)],
        ),
      ]);

  Component _detailsPanel() {
    final rows = <(String, String?)>[
      ('Unit size', '${property.sizeSqft.toStringAsFixed(0)} sq ft'),
      ('Rental efficiency', 'RM${property.rentalPerSqft.toStringAsFixed(2)} / sq ft'),
      ('Floor level', property.floorLevel),
      ('Bathrooms', property.bathrooms?.toString()),
      ('Furnishing', property.furnishing),
      ('Tenure', property.tenure),
      ('Parking', property.hasParking == null
          ? null
          : (property.hasParking! ? 'Onsite parking' : 'No onsite parking')),
      ('F&B suitable', property.isFnbSuitable == null
          ? null
          : (property.isFnbSuitable! ? 'Yes' : 'No')),
      ('Corner lot', property.isCornerLot == null ? null : (property.isCornerLot! ? 'Yes' : 'No')),
      ('Freehold', property.isFreehold == null ? null : (property.isFreehold! ? 'Yes' : 'No')),
      ('Coordinates', property.hasCoordinates
          ? '${property.latitude.toStringAsFixed(4)}, ${property.longitude.toStringAsFixed(4)}'
          : null),
      ('Research link', property.hasResearchLink ? 'Verified' : null),
    ];
    return section(classes: 'sw-v4__details', [
      button(
        classes: 'sw-v4__details-toggle',
        attributes: {'type': 'button', 'aria-expanded': '$_detailsOpen'},
        events: {'click': (e) => setState(() => _detailsOpen = !_detailsOpen)},
        [
          Component.text(_detailsOpen ? 'Hide property details' : 'View more property details'),
          Component.text(_detailsOpen ? '  ▴' : '  ▾'),
        ],
      ),
      if (_detailsOpen)
        div(classes: 'sw-v4__detail-grid', [
          for (final (label, value) in rows) _detailRow(label, value),
        ]),
    ]);
  }

  // ------------------------------------------------------------------- score

  Component _scoreCards() {
    final has = property.hasSuitabilityScore;
    final score = property.suitabilityScore.clamp(0.0, 100.0);
    return div(classes: 'sw-v4__scorecards', [
      section(classes: 'sw-v4__score-main', [
        div(
          classes: 'sw-v4__ring',
          attributes: {'style': '--pct:${has ? score.toStringAsFixed(0) : 0}'},
          [
            div(classes: 'sw-v4__ring-inner', [
              strong([Component.text(has ? score.toStringAsFixed(0) : '—')]),
              span([Component.text('/ 100')]),
            ]),
          ],
        ),
        h3([Component.text('PU research association index')]),
        p(classes: 'small', [
          Component.text(
            has
                ? 'Relative association with the observed F&B sample in the '
                    'research dataset. Not a success probability, profit forecast '
                    'or personalised recommendation score.'
                : 'Not calculated for this property. No value is substituted.',
          ),
        ]),
        ActionLink(
          'View measured analysis',
          href: '/entrepreneur/property-analysis?id=${Uri.encodeComponent(property.id)}',
          variant: 'secondary',
          icon: 'analytics',
        ),
      ]),
      section(classes: 'sw-v4__score-side', [
        h3([Component.text('What influences the location?')]),
        for (final c in const [
          'People nearby',
          'Other food businesses',
          'Nearby places',
          'Getting there',
          'Parking nearby',
        ])
          div(classes: 'sw-v4__cat-row', [
            span(classes: 'sw-v4__cat-name', [Component.text(c)]),
            span(classes: 'sw-v4__cat-bar-absent', [
              Component.text('Category score not produced by the backend'),
            ]),
          ]),
        p(classes: 'sw-v4__note', [
          Component.text(
            'No validated per-category score contract exists, so bars are shown '
            'as unavailable rather than invented. The measured inputs are in '
            'Location Insights below.',
          ),
        ]),
      ]),
    ]);
  }

  // -------------------------------------------------------------------- tour

  Component _tourSection() => section(
        classes: 'sw-v4__tour',
        attributes: {'id': 'sw-v4-tour'},
        [
          div(classes: 'sw-v4__tour-head', [
            h2([Component.text('360° virtual tour')]),
            span(classes: 'sw-v4__tour-status', [
              Component.text(property.hasTour ? 'Tour recorded' : 'No published tour'),
            ]),
          ]),
          div(classes: 'sw-v4__tour-stage', [
            Icon('panorama', size: 'lg', label: '360 tour'),
            if (property.hasTour) ...[
              p([
                Component.text(
                  'A tour record exists for this property, but no browser-accessible '
                  'published panorama is available: approved tours store a private '
                  'storage key, and this build has no signed-URL endpoint.',
                ),
              ]),
              ActionLink(
                'Open tour workflow',
                href: '/entrepreneur/tour?id=${property.id}',
                variant: 'secondary',
                icon: '360',
              ),
            ] else
              p([
                Component.text(
                  'No accessible published 360° tour. Capture → stitch → review → '
                  'publish; a tour appears here only after approval and publication.',
                ),
              ]),
          ]),
        ],
      );

  // -------------------------------------------------------------- supporting

  Component _mapPanel() => section(classes: 'panel sw-pd__map-panel', [
        h2([Component.text('Map & nearby properties')]),
        PropertyLeafletMap(property: property, height: 330),
        p(classes: 'sw-pd__footnote', [
          Component.text(
            'Interactive Leaflet map, CARTO/OSM tiles, 500 m and 1 km '
            'straight-line catchments. Nearby pins are the research reference '
            'properties, not F&B competitors. Coordinates can be approximate.',
          ),
        ]),
      ]);

  Component _notShownPanel() => section(classes: 'panel', [
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
          li([Component.text('Owner contact details and internal verification notes.')]),
        ]),
        p(classes: 'disclaimer', [
          Component.text(
            'The research index is a relative decision-support indicator. It is '
            'not a probability of business success, a revenue forecast, '
            'regulatory approval, or a guarantee of any kind.',
          ),
        ]),
      ]);
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
              'This property could not be loaded. It may have been removed, or '
              'the link is incomplete.',
          action: const ActionLink(
            'Browse properties',
            href: '/entrepreneur/explore',
            variant: 'primary',
          ),
        ),
      ]);
}
