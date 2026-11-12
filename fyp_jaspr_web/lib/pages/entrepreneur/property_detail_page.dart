import 'dart:async';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/property_detail/category_explanation_panel.dart';
import '../../components/property_detail/combined_media_gallery.dart';
import '../../components/property_detail/location_fit_score.dart';
import '../../components/property_detail/shap_contribution_chart.dart';
import '../../components/property_leaflet_map.dart';
import '../../components/ui.dart';
import '../../data/app_locator.dart';
import '../../data/full_analysis_actions_browser.dart';
import '../../data/location_evidence_api.dart';
import '../../data/preference_labels.dart';
import '../../data/property_insights_api.dart';
import '../../layouts/app_layout.dart';

/// Entrepreneur property detail — the V5 "Property Insights" layout.
///
/// ```text
/// top        back · title · verification · address
/// hero       combined Photos / 360° gallery  +  price, facts, facilities, actions
/// fit        Location Fit index (real model output, rescaled to 0-100)
/// why        SHAP contribution chart — what raised and lowered that score
/// analysis   five category tabs, each with its own contributions
/// map        interactive Leaflet map with 500 m / 1 km catchments
/// notes      what this page does not claim
/// ```
///
/// Data honesty: every number comes from the catalogue record, the evidence
/// API or the insights endpoint, which runs the *deployed* PU artifact and its
/// permutation-SHAP decomposition. A missing value is labelled, never printed
/// as 0, and the index is never presented as a success probability.
///
/// The former separate "360° virtual tour" section at the bottom is gone: the
/// panorama now lives inside the gallery's own tab, so there is one media
/// control rather than two competing ones.
@client
class PropertyDetailPage extends StatefulComponent {
  /// The property id from the `?id=` query param.
  final String id;

  /// Optional `?result=` recommendation result id.
  ///
  /// When present the page also renders "Why this property matches your
  /// preferences" from the persisted Layer 2 result. It is the *personalised*
  /// explanation; the SHAP chart above remains the *research model*
  /// explanation and the two are never merged into one claim.
  final String resultId;

  const PropertyDetailPage({super.key, required this.id, this.resultId = ''});

  @override
  State<PropertyDetailPage> createState() => _PropertyDetailPageState();
}

class _PropertyDetailPageState extends State<PropertyDetailPage> {
  String? _saveMessage;
  bool _compareLinkShown = false;
  Future<PropertyDetailLoad?>? _detailFuture;
  Future<PropertyEvidence>? _evidenceFuture;
  Future<PropertyInsights>? _insightsFuture;

  /// The persisted recommendation result, when the card that opened this page
  /// carried one. Null means the visitor arrived without a result context, so
  /// no preference explanation is claimed.
  Future<PersonalisedExplanation?>? _explanationFuture;

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
      final isCatalog = int.tryParse(id) == null;
      _detailFuture = _load(id);
      _evidenceFuture = LocationEvidenceApi.load(id, catalog: isCatalog);
      _insightsFuture = PropertyInsightsApi.load(id, catalog: isCatalog);
      if (component.resultId.isNotEmpty) {
        _explanationFuture = AppLocator.personalisedRecommendations
            .explanation(component.resultId);
      }
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
      // The page renders its own compact title row; the global PageHead would
      // add a second, oversized heading above the gallery.
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
                  insightsFuture: _insightsFuture,
                  explanationFuture: _explanationFuture,
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
  final Future<PropertyInsights>? insightsFuture;
  final Future<PersonalisedExplanation?>? explanationFuture;
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
    required this.insightsFuture,
    this.explanationFuture,
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
  bool _detailsOpen = false;
  String? _copyMessage;

  /// Gallery interaction state. The page is the `@client` boundary, so the
  /// gallery itself stays stateless and receives this value plus callbacks.
  GalleryView _gallery = const GalleryView();
  double _dragX = 0;
  double _dragY = 0;
  double _yawStart = 50;
  double _pitchStart = 50;

  /// SHAP disclosure state.
  bool _shapShowAll = false;
  bool _shapTechnical = false;

  /// The category tab the entrepreneur chose; null opens the most influential.
  String? _categorySelected;

  /// The resolved payload, kept here so the gallery (panorama) and the map
  /// (layer counts, scored coordinate) can use it. They must not issue a second
  /// request, and they must describe the same payload the score shows.
  PropertyInsights? _insights;

  @override
  void initState() {
    super.initState();
    // The score sections read the future directly so they can show a skeleton;
    // this mirror only feeds the gallery and the map.
    component.insightsFuture?.then<void>(
      (value) {
        if (!mounted) return;
        setState(() => _insights = value);
      },
      onError: (Object _) {
        // The score sections already render the failure; the gallery and map
        // keep their photos-only and coordinates-only defaults.
      },
    );
  }

  CommercialProperty get property => component.property;
  List<String> get imageUrls => component.imageUrls;
  bool get saved => component.saved;
  bool get compared => component.compared;
  String? get saveMessage => component.saveMessage;
  bool get compareLinkShown => component.compareLinkShown;
  void Function() get onToggleSaved => component.onToggleSaved;
  void Function() get onToggleCompared => component.onToggleCompared;

  // -- gallery handlers ----------------------------------------------------

  void _stepPhoto(int delta) {
    final total = _images.length;
    if (total < 2) return;
    setState(() {
      _gallery = _gallery.copyWith(
        index: (_gallery.index + delta + total) % total,
        photoFailed: false,
      );
    });
  }

  void _dragStart(double x, double y) {
    _dragX = x;
    _dragY = y;
    _yawStart = _gallery.yaw;
    _pitchStart = _gallery.pitch;
    setState(() => _gallery = _gallery.copyWith(dragging: true));
  }

  void _dragMove(double x, double y) {
    final dx = x - _dragX;
    final dy = y - _dragY;
    setState(() {
      _gallery = _gallery.copyWith(
        // Dragging right reveals what is to the left, so yaw decreases.
        yaw: (_yawStart - dx / 8).clamp(0.0, 100.0),
        pitch: (_pitchStart - dy / 12).clamp(0.0, 100.0),
      );
    });
  }

  void _setZoom(double value) {
    setState(() => _gallery = _gallery.copyWith(zoom: value.clamp(1.0, 3.0)));
  }

  void _resetView() {
    setState(() => _gallery = _gallery.copyWith(yaw: 50, pitch: 50, zoom: 1));
  }

  String get _addressLine =>
      '${property.address}, ${property.postcode} ${property.city}, '
      '${property.state}';

  List<String> get _images {
    final urls = imageUrls.where((url) => url.trim().isNotEmpty).toList();
    if (urls.isNotEmpty) return urls;
    final single = property.imageUrl;
    return single != null && single.trim().isNotEmpty ? [single] : const [];
  }

  /// Facilities are the real recorded attributes — tags, stated requirements
  /// and the boolean amenities. Nothing is inferred.
  List<String> get _facilities => <String>{
        if (property.hasParking == true) 'Parking',
        if (property.isFnbSuitable == true) 'F&B suitable',
        if (property.isCornerLot == true) 'Corner lot',
        if (property.isFreehold == true) 'Freehold',
        if (property.furnishing != null && property.furnishing!.trim().isNotEmpty)
          property.furnishing!,
        if (property.tenure != null && property.tenure!.trim().isNotEmpty)
          property.tenure!,
        ...property.tags,
        ...property.requirements,
      }.toList();

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
    return div(classes: 'sw-pd', [
      _titleRow(),
      section(classes: 'sw-pd__hero', [
        CombinedMediaGallery(
          photoUrls: _images,
          propertyTitle: property.title,
          panorama: _panorama(),
          view: _gallery,
          height: 430,
          onTab: (tab) => setState(
            () => _gallery = _gallery.copyWith(tab: tab, full: false, photoFailed: false),
          ),
          onIndex: (index) => setState(
            () => _gallery = _gallery.copyWith(index: index, photoFailed: false),
          ),
          onStep: _stepPhoto,
          onToggleFull: () => setState(() => _gallery = _gallery.copyWith(full: !_gallery.full)),
          onPhotoError: () => setState(() => _gallery = _gallery.copyWith(photoFailed: true)),
          onDragStart: _dragStart,
          onDragMove: _dragMove,
          onDragEnd: () => setState(() => _gallery = _gallery.copyWith(dragging: false)),
          onZoom: _setZoom,
          onResetView: _resetView,
        ),
        _summaryCard(),
      ]),
      FutureBuilder<PropertyInsights>(
        future: component.insightsFuture,
        builder: (c, snap) {
          final loading = snap.connectionState != ConnectionState.done;
          if (loading) return const _InsightsLoading();
          final insights = snap.data ??
              PropertyInsights.unavailable(
                property.id,
                'The location analysis could not be loaded.',
              );
          return div(classes: 'sw-pd__insights', [
            LocationFitScore(insights: insights),
            ShapContributionChart(
              insights: insights,
              showAll: _shapShowAll,
              showTechnical: _shapTechnical,
              onToggleAll: () => setState(() => _shapShowAll = !_shapShowAll),
              onToggleTechnical: () => setState(() => _shapTechnical = !_shapTechnical),
            ),
            CategoryExplanationPanel(
              insights: insights,
              selectedKey: _categorySelected,
              onSelect: (key) => setState(() => _categorySelected = key),
            ),
          ]);
        },
      ),
      _detailsPanel(),
      _preferencePanel(),
      _mapPanel(),
      _notShownPanel(),
    ]);
  }

  /// The gallery's 360° source.
  ///
  /// The backend resolves the panorama through the *verified* catalogue link
  /// (`fyp.property_subject_links` → `virtual_tour`), so a tour is only offered
  /// when its stitching job reports a completed status and a URL. A `hasTour`
  /// flag on its own is a record, not a finished image, and is never rendered
  /// as a tour.
  PanoramaMedia _panorama() {
    final info = _insights?.panorama;
    final ready = info?.readyUrl;
    if (ready != null) return PanoramaMedia.ready(ready);

    if (info != null && info.status == 'processing') {
      return PanoramaMedia.processing(
        info.reason ??
            'A 360° panorama for this property is still being processed, so it '
                'is not shown yet.',
      );
    }
    if (property.hasTour) {
      return PanoramaMedia.unavailable(
        info?.reason ??
            'A tour record exists for this property, but no completed stitched '
                'panorama file is stored or accessible, so there is nothing to '
                'display.',
      );
    }
    return PanoramaMedia.unavailable(
      info?.reason ??
          'No 360° photo has been captured and stitched for this property yet.',
    );
  }

  // ------------------------------------------------------------------- title

  Component _titleRow() => div(classes: 'sw-pd__top', [
        ActionLink(
          'All properties',
          href: '/entrepreneur/explore',
          variant: 'ghost',
          icon: 'arrow_back',
        ),
        div(classes: 'sw-pd__top-main', [
          h1(classes: 'sw-pd__title', [Component.text(property.title)]),
          p(classes: 'sw-pd__addr', [Component.text(_addressLine)]),
        ]),
        div(classes: 'sw-pd__badges', [
          StatusBadge(
            'Verification: ${property.verification.label.toLowerCase()}',
            tone: toneForVerification(property.verification),
          ),
          if (property.availability != null)
            StatusBadge(property.availability!, tone: 'neutral'),
        ]),
      ]);

  // ----------------------------------------------------------------- summary

  Component _fact(String label, String? value) => div(classes: 'sw-pd__fact', [
        span(classes: 'sw-pd__fact-label', [Component.text(label)]),
        span(
          classes: value == null || value.trim().isEmpty
              ? 'sw-pd__fact-value is-absent'
              : 'sw-pd__fact-value',
          [
            Component.text(
              value == null || value.trim().isEmpty ? 'Not available' : value,
            ),
          ],
        ),
      ]);

  Component _summaryCard() {
    final facilities = _facilities;
    return div(classes: 'sw-pd__summary', [
      div(classes: 'sw-pd__price', [
        strong([Component.text(property.rentalDisplay)]),
        span([Component.text('/ month')]),
      ]),
      div(classes: 'sw-pd__facts', [
        _fact('Floor space', '${property.sizeSqft.toStringAsFixed(0)} sq ft'),
        _fact('Property type', property.propertyType),
        _fact('Floor', property.floorLevel),
        _fact(
          'Rental efficiency',
          'RM${property.rentalPerSqft.toStringAsFixed(2)} / sq ft',
        ),
      ]),
      if (facilities.isNotEmpty) ...[
        h3(classes: 'sw-pd__section-label', [Component.text('Facilities')]),
        div(classes: 'sw-pd__chips', [
          for (final facility in facilities.take(10))
            span(classes: 'sw-pd__chip', [Component.text(facility)]),
        ]),
      ],
      p(classes: 'sw-pd__desc', [
        Component.text(
          (property.description?.trim().isNotEmpty ?? false)
              ? property.description!
              : '${property.title} is a ${property.propertyType.toLowerCase()} '
                  'of ${property.sizeSqft.toStringAsFixed(0)} sq ft in '
                  '${property.city}, ${property.state}.',
        ),
      ]),
      div(classes: 'sw-pd__actions', [
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
        ActionButton(
          'Copy summary',
          variant: 'ghost',
          icon: 'content_copy',
          onClick: _copySummary,
        ),
      ]),
      if (saveMessage != null)
        span(classes: 'small text-success', [Component.text(saveMessage!)]),
      if (_copyMessage != null) span(classes: 'small', [Component.text(_copyMessage!)]),
      if (compareLinkShown && compared)
        ActionLink('Open compare', href: '/entrepreneur/compare', variant: 'ghost'),
    ]);
  }

  // ----------------------------------------------------------------- details

  Component _detailRow(String label, String? value) => div(classes: 'sw-pd__detail-row', [
        span([Component.text(label)]),
        span(
          classes: value == null || value.trim().isEmpty ? 'is-absent' : null,
          [
            Component.text(
              value == null || value.trim().isEmpty ? 'Not available' : value,
            ),
          ],
        ),
      ]);

  Component _detailsPanel() {
    final rows = <(String, String?)>[
      ('Unit size', '${property.sizeSqft.toStringAsFixed(0)} sq ft'),
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
      ('Corner lot', property.isCornerLot == null
          ? null
          : (property.isCornerLot! ? 'Yes' : 'No')),
      ('Freehold', property.isFreehold == null
          ? null
          : (property.isFreehold! ? 'Yes' : 'No')),
      ('Coordinates', property.hasCoordinates
          ? '${property.latitude.toStringAsFixed(4)}, ${property.longitude.toStringAsFixed(4)}'
          : null),
      ('Research link', property.hasResearchLink ? 'Verified' : null),
    ];
    return section(classes: 'sw-pd__details', [
      button(
        classes: 'sw-pd__details-toggle',
        attributes: {'type': 'button', 'aria-expanded': '$_detailsOpen'},
        events: events(onClick: () => setState(() => _detailsOpen = !_detailsOpen)),
        [
          Component.text(_detailsOpen ? 'Hide listing details' : 'Show listing details'),
          Component.text(_detailsOpen ? '  ▴' : '  ▾'),
        ],
      ),
      if (_detailsOpen)
        div(classes: 'sw-pd__detail-grid', [
          for (final (label, value) in rows) _detailRow(label, value),
        ]),
    ]);
  }

  // --------------------------------------------------- preference explanation

  /// "Why this property matches your preferences".
  ///
  /// Only rendered when the page was opened from a recommendation result.
  /// The content is the Layer 2 rule engine's own component calculations —
  /// deliberately kept apart from the SHAP chart above, which explains the
  /// research PU model. Merging the two would let a model contribution stand
  /// in for a preference judgement it never made.
  Component _preferencePanel() {
    final future = component.explanationFuture;
    if (future == null) return const Component.fragment([]);
    return section(classes: 'sw-pd__prefs', [
      h2(classes: 'sw-pd__h2', [
        Component.text('Why this property matches your preferences'),
      ]),
      p(classes: 'sw-pd__prefs-lead', [
        Component.text(
          'These reasons come from the recommendation engine\'s own rule '
          'calculations against your saved requirements. The chart above '
          'explains the research location model instead — the two are kept '
          'separate on purpose.',
        ),
      ]),
      FutureBuilder<PersonalisedExplanation?>(
        future: future,
        builder: (c, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return div(classes: 'sw-pd__prefs-skel', [
              span(classes: 'sw-skel sw-skel--line', []),
              span(classes: 'sw-skel sw-skel--line', []),
            ]);
          }
          final e = snap.data;
          if (e == null) {
            return p(classes: 'sw-pd__prefs-empty', [
              Component.text(
                'This recommendation result could not be loaded, so no '
                'preference explanation is shown. The location evidence and '
                'research explanation on this page are unaffected.',
              ),
            ]);
          }
          final pref = e.preferenceMatchScore == null
              ? 'not scorable'
              : '${(e.preferenceMatchScore! * 100).toStringAsFixed(0)}%';
          final finalPct = e.finalScore == null
              ? 'not available'
              : '${(e.finalScore! * 100).toStringAsFixed(0)}/100';
          return div(classes: 'sw-pd__prefs-body', [
            div(classes: 'sw-pd__prefs-figures', [
              _prefFigure('Preference fit', pref),
              _prefFigure('Recommendation score', finalPct),
              _prefFigure('Rank', e.rank == null ? '—' : '#${e.rank}'),
            ]),
            if (e.preferenceReasons.isEmpty)
              p(classes: 'sw-pd__prefs-empty', [
                Component.text(
                  'No preference component could be scored for this property. '
                  'Unknown requirements are excluded, never treated as zero.',
                ),
              ])
            else ...[
              h3(classes: 'sw-pd__prefs-h3', [Component.text('What matched')]),
              ul(classes: 'sw-pd__prefs-list', [
                for (final reason in e.preferenceReasons.take(6))
                  li([Component.text(reason)]),
              ]),
            ],
            if (e.cautions.isNotEmpty) ...[
              h3(classes: 'sw-pd__prefs-h3', [Component.text('Worth checking')]),
              ul(classes: 'sw-pd__prefs-list sw-pd__prefs-list--caution', [
                for (final caution in e.cautions.take(6))
                  li([Component.text(caution)]),
              ]),
            ],
            h3(classes: 'sw-pd__prefs-h3', [Component.text('How each requirement scored')]),
            div(classes: 'sw-pd__prefs-components', [
              for (final entry in e.components.entries)
                div(classes: 'sw-pd__prefs-component', [
                  span(classes: 'sw-pd__prefs-name', [
                    Component.text(componentLabel(entry.key)),
                  ]),
                  span(
                    classes:
                        'sw-pd__prefs-value${entry.value.status == 'unknown' ? ' is-unknown' : ''}',
                    [
                      Component.text(
                        entry.value.status == 'unknown' || entry.value.value == null
                            ? 'not enough data'
                            : '${(entry.value.value! * 100).toStringAsFixed(0)}%',
                      ),
                    ],
                  ),
                ]),
            ]),
          ]);
        },
      ),
    ]);
  }

  Component _prefFigure(String label, String value) => div(classes: 'sw-pd__prefs-figure', [
        span(classes: 'sw-pd__prefs-figure-label', [Component.text(label)]),
        span(classes: 'sw-pd__prefs-figure-value', [Component.text(value)]),
      ]);

  // --------------------------------------------------------------------- map

  Component _mapPanel() {
    final layers = _insights?.mapLayers ?? const <MapLayer>[];
    return section(classes: 'sw-pd__map', [
      h2(classes: 'sw-pd__h2', [Component.text('What is around this location')]),
      PropertyLeafletMap(
        property: property,
        height: 470,
        layers: layers,
        origin: _insights?.origin,
      ),
      // The map explains its own layers inside the frame; this line only
      // covers what the map cannot say about itself, so the two do not repeat
      // each other.
      p(classes: 'sw-pd__footnote', [
        Component.text(
          'The shaded rings are straight-line 500 m and 1 km distances from the '
          'property — not walking or driving catchments. Coordinates can be '
          'approximate. Layers the data records only as counts are shown as '
          'counts, without pins.',
        ),
      ]),
    ]);
  }

  // ------------------------------------------------------------------- notes

  Component _notShownPanel() => section(classes: 'sw-pd__notes', [
        h2(classes: 'sw-pd__h2', [Component.text('What this page does not claim')]),
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
            'Location Fit is a relative decision-support index, not a probability '
            'of business success, a revenue forecast, regulatory approval, or a '
            'guarantee of any kind.',
          ),
        ]),
      ]);
}

/// Shown while the insights request is in flight — a skeleton, not a spinner
/// that pushes the page around when it resolves.
class _InsightsLoading extends StatelessComponent {
  const _InsightsLoading();

  @override
  Component build(BuildContext context) => div(classes: 'sw-pd__insights is-loading', [
        div(classes: 'sw-skel sw-skel--fit', const []),
        div(classes: 'sw-skel sw-skel--chart', const []),
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
