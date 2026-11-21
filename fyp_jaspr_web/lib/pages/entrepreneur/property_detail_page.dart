import 'dart:async';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/property_detail/business_match_panel.dart';
import '../../components/property_detail/business_type_fit_panel.dart';
import '../../components/property_detail/category_explanation_panel.dart';
import '../../components/property_detail/combined_media_gallery.dart';
import '../../components/property_detail/district_demographics_panel.dart';
import '../../components/property_detail/location_fit_score.dart';
import '../../components/property_detail/location_insights.dart';
import '../../components/property_detail/shap_contribution_chart.dart';
import '../../components/property_leaflet_map.dart';
import '../../components/ui.dart';
import '../../data/app_locator.dart';
import '../../data/full_analysis_actions_browser.dart';
import '../../data/location_evidence_api.dart';
import '../../data/property_insights_api.dart';
import '../../layouts/app_layout.dart';

/// Entrepreneur property detail — the final "business-first" layout.
///
/// ```text
/// top        back · title · verification · address
/// hero       combined Photos / 360° gallery  +  price, facts, facilities, actions
/// details    collapsible listing facts — collapsed by default, sits directly
///            above the business match so the primary answer stays first
/// match      Why this property matches YOUR business — selected business,
///            saved recommendation match ring and measured quick facts
/// tabs       1 Your business match   reasons + things to check
///            2 Why this area score?  Location Fit + SHAP contributions
///            3 What's nearby         categories, DOSM district ages, map
/// notes      what this page does not claim
/// ```
///
/// Data honesty: every number comes from the catalogue record, the evidence
/// API or the insights endpoint, which runs the *deployed* PU artifact and its
/// permutation-SHAP decomposition. The personalised match comes only from the
/// persisted Layer 2 result carried by `?result=` — it is never derived from
/// the PU score. A missing value is labelled, never printed as 0, and no
/// score is ever presented as a success probability.
///
/// The former four-business comparison (café / restaurant / bakery / takeaway
/// ranking) is gone by design: the entrepreneur already chose their business,
/// so this page explains the recommended property for THAT business.
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

  /// Optional `?businessType=` selection carried from Recommendations.
  ///
  /// It selects which category output the Stage-2 SHAP explanation describes.
  /// An empty value means the visitor arrived without a selection, in which
  /// case the backend explains the model's own top category and the page says
  /// so instead of pretending a choice was made.
  final String businessType;

  const PropertyDetailPage({
    super.key,
    required this.id,
    this.resultId = '',
    this.businessType = '',
  });

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
      _insightsFuture = PropertyInsightsApi.load(
        id,
        catalog: isCatalog,
        businessType: component.businessType.isEmpty
            ? null
            : component.businessType,
      );
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

  /// Whether the "View all location details" list in the business-match hero
  /// is expanded. Same page-owned disclosure pattern as [_shapShowAll].
  bool _featureDetailsOpen = false;

  /// The category tab the entrepreneur chose; null opens the most influential.
  String? _categorySelected;

  /// Which of the three insight tabs is open: `business`, `score`, `nearby`.
  ///
  /// The state lives here — the page is the `@client` boundary — so the tab
  /// survives every panel rebuild and the panels themselves stay stateless.
  /// Business opens first: the page's primary question is the match for the
  /// business the entrepreneur already selected.
  String _infoTab = 'business';

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

  /// A thumbnail whose URL failed gets its own placeholder. This never affects
  /// the main image or selects another photo: the user can still click it.
  void _thumbError(int index) {
    setState(() {
      _gallery = _gallery.copyWith(
        thumbFailed: <int>{..._gallery.thumbFailed, index},
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
      [
        property.address.trim(),
        [property.postcode.trim(), property.city.trim()]
            .where((part) => part.isNotEmpty)
            .join(' '),
        property.state.trim(),
      ].where((part) => part.isNotEmpty).join(', ');

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
        if (property.isFnbSuitable == true) 'Suitable for a food business',
        if (property.isCornerLot == true) 'Corner lot',
        if (property.isFreehold == true) 'Freehold',
        if (property.furnishing != null && property.furnishing!.trim().isNotEmpty)
          property.furnishing!,
        if (property.tenure != null && property.tenure!.trim().isNotEmpty)
          property.tenure!,
        ...property.tags.where(
          (tag) => tag != 'Imported dataset' && !tag.startsWith('Quality:'),
        ),
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
      _copyMessage = ok ? 'Property details copied.' : 'Could not copy the details. Please try again.';
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
          onThumbError: _thumbError,
          onDragStart: _dragStart,
          onDragMove: _dragMove,
          onDragEnd: () => setState(() => _gallery = _gallery.copyWith(dragging: false)),
          onZoom: _setZoom,
          onResetView: _resetView,
        ),
        _summaryCard(),
      ]),
      // Section order: gallery/summary, then the collapsed listing-details
      // accordion, then "Your business & this property" and the tabs. The
      // accordion reuses the existing detail rows — nothing is duplicated.
      _detailsPanel(),
      _businessMatchSection(),
      _insightTabs(),
      _notShownPanel(),
    ]);
  }

  // ------------------------------------------------- business match section

  /// "Why this property matches your business" — the section above the tabs.
  ///
  /// Rendered even without a result context: the hero then states that the
  /// personalised match is unavailable while still naming the measured area
  /// facts, so the section never shows a fabricated percentage.
  Component _businessMatchSection() {
    return FutureBuilder<PropertyEvidence>(
      future: component.evidenceFuture,
      builder: (c, evidenceSnap) {
        final evidence =
            evidenceSnap.connectionState == ConnectionState.done
                ? evidenceSnap.data
                : null;
        final explanationFuture = component.explanationFuture;
        if (explanationFuture == null) {
          return BusinessMatchHero(
            property: property,
            evidence: evidence,
            insights: _insights,
            detailsOpen: _featureDetailsOpen,
            onToggleDetails: () => setState(
              () => _featureDetailsOpen = !_featureDetailsOpen,
            ),
          );
        }
        return FutureBuilder<PersonalisedExplanation?>(
          future: explanationFuture,
          builder: (c, snap) {
            final loading = snap.connectionState != ConnectionState.done;
            return BusinessMatchHero(
              property: property,
              explanation: snap.data,
              loading: loading,
              evidence: evidence,
              insights: _insights,
              detailsOpen: _featureDetailsOpen,
              onToggleDetails: () => setState(
                () => _featureDetailsOpen = !_featureDetailsOpen,
              ),
            );
          },
        );
      },
    );
  }

  // -------------------------------------------------------------- info tabs

  /// "Explore this property" — the three insight tabs.
  ///
  /// One panel is rendered at a time. Only the selected panel is mounted, so a
  /// tab that owns a Leaflet map never initialises it inside a hidden
  /// container (Leaflet measures its container once, and a `display:none`
  /// parent would leave it with a 0×0 viewport).
  Component _insightTabs() {
    return section(
      classes: 'sw-info',
      attributes: const {'aria-labelledby': 'sw-info-title'},
      [
        div(classes: 'sw-info__head', [
          span(classes: 'sw-info__eyebrow', [
            Component.text('Explore this property'),
          ]),
          h2(
            classes: 'sw-info__title',
            attributes: const {'id': 'sw-info-title'},
            [Component.text('Understand why this property fits your needs')],
          ),
          p(classes: 'sw-info__lede', [
            Component.text(
              'Review the reasons behind your selected-business '
              'recommendation, understand the area score and explore nearby '
              'services.',
            ),
          ]),
        ]),
        div(
          classes: 'sw-info__tabs',
          attributes: const {
            'role': 'tablist',
            'aria-label': 'Explore property information',
          },
          [
            _infoTabButton(
              key: 'business',
              title: 'Your business match',
              description: 'Why this property may suit you',
              icon: _tabIcon('business'),
            ),
            _infoTabButton(
              key: 'score',
              title: 'Why this area score?',
              description: 'Explore the measured area score',
              icon: _tabIcon('score'),
            ),
            _infoTabButton(
              key: 'nearby',
              title: "What's nearby",
              description: 'People, shops and travel',
              icon: _tabIcon('nearby'),
            ),
          ],
        ),
        if (_infoTab == 'business') _businessTab(),
        if (_infoTab == 'score') _scoreTab(),
        if (_infoTab == 'nearby') _nearbyTab(),
      ],
    );
  }

  Component _infoTabButton({
    required String key,
    required String title,
    required String description,
    required Component icon,
  }) {
    final active = _infoTab == key;
    return button(
      classes: 'sw-info__tab${active ? ' is-active' : ''}',
      attributes: {
        'type': 'button',
        'role': 'tab',
        'id': 'sw-info-tab-$key',
        'aria-selected': '$active',
        'aria-controls': 'sw-info-panel-$key',
      },
      events: events(onClick: () => setState(() => _infoTab = key)),
      [
        span(
          classes: 'sw-info__tab-icon',
          attributes: const {'aria-hidden': 'true'},
          [icon],
        ),
        span(classes: 'sw-info__tab-text', [
          span(classes: 'sw-info__tab-title', [Component.text(title)]),
          span(classes: 'sw-info__tab-desc', [Component.text(description)]),
        ]),
      ],
    );
  }

  Component _tabPanel(String key, List<Component> children) => div(
        classes: 'sw-info__panel',
        attributes: {
          'id': 'sw-info-panel-$key',
          'role': 'tabpanel',
          'aria-labelledby': 'sw-info-tab-$key',
          'tabindex': '0',
        },
        children,
      );

  Component _tabIcon(String key) => svg(
        classes: 'sw-info__glyph',
        attributes: const {
          'viewBox': '0 0 24 24',
          'fill': 'none',
          'stroke': 'currentColor',
          'stroke-width': '1.85',
          'stroke-linecap': 'round',
          'stroke-linejoin': 'round',
          'aria-hidden': 'true',
        },
        [
          if (key == 'score') ...[
            path(attributes: const {'d': 'M4 20V12m5 8V5m5 15v-9m5 9V8'}, const []),
            path(attributes: const {'d': 'M2 20h20'}, const []),
          ] else if (key == 'business') ...[
            path(attributes: const {'d': 'M4 10h16l-1.3 10H5.3L4 10Z'}, const []),
            path(attributes: const {'d': 'M3 10l2.5-5h13L21 10'}, const []),
            path(attributes: const {'d': 'M9 20v-6h6v6'}, const []),
          ] else ...[
            path(attributes: const {
              'd': 'M20 10c0 5.2-8 11-8 11S4 15.2 4 10a8 8 0 1 1 16 0Z',
            }, const []),
            circle(
              attributes: const {'cx': '12', 'cy': '10', 'r': '2.6'},
              const [],
            ),
          ],
        ],
      );

  // ------------------------------------------------------------- tab: score

  Component _scoreTab() {
    final future = component.insightsFuture;
    return _tabPanel('score', [
      div(classes: 'sw-info__intro', [
        h3([Component.text('How suitable is this area for a food business?')]),
        p([
          Component.text(
            'This score compares the surrounding area with places where food '
            'businesses already operate. It cannot predict how many customers '
            'you will get or how much you will earn.',
          ),
        ]),
      ]),
      if (future == null)
        div(classes: 'sw-info__note', [
          Component.text(
            'We could not load the area information for this property.',
          ),
        ])
      else
        FutureBuilder<PropertyInsights>(
          future: future,
          builder: (c, snap) {
            final loading = snap.connectionState != ConnectionState.done;
            if (loading) return const _InsightsLoading();
            final insights = snap.data ??
                PropertyInsights.unavailable(
                  property.id,
                  'We could not load the area information right now.',
                );
            return div(classes: 'sw-pd__insights', [
              LocationFitScore(insights: insights),
              // Stage 2 — the entrepreneur's own business type. Separate model,
              // separate SHAP, separate wording; never merged into the PU score.
              BusinessTypeFitPanel(insights: insights),
              ShapContributionChart(
                insights: insights,
                showAll: _shapShowAll,
                showTechnical: _shapTechnical,
                onToggleAll: () => setState(() => _shapShowAll = !_shapShowAll),
                onToggleTechnical: () =>
                    setState(() => _shapTechnical = !_shapTechnical),
              ),
              CategoryExplanationPanel(
                insights: insights,
                selectedKey: _categorySelected,
                onSelect: (key) => setState(() => _categorySelected = key),
              ),
            ]);
          },
        ),
    ]);
  }

  // ---------------------------------------------------------- tab: business

  /// Tab 1 — reasons to consider the location and things to check in person,
  /// driven by the saved recommendation explanation plus measured evidence.
  ///
  /// Without a result context the panel still renders: the measured reasons
  /// stand on their own and the source note explains that a personalised
  /// explanation appears when the page is opened from a recommendation.
  Component _businessTab() {
    return _tabPanel('business', [
      FutureBuilder<PropertyEvidence>(
        future: component.evidenceFuture,
        builder: (c, evidenceSnap) {
          final evidence =
              evidenceSnap.connectionState == ConnectionState.done
                  ? evidenceSnap.data
                  : null;
          final explanationFuture = component.explanationFuture;
          if (explanationFuture == null) {
            return BusinessMatchDetail(
              property: property,
              evidence: evidence,
            );
          }
          return FutureBuilder<PersonalisedExplanation?>(
            future: explanationFuture,
            builder: (c, snap) {
              final loading = snap.connectionState != ConnectionState.done;
              return BusinessMatchDetail(
                property: property,
                explanation: snap.data,
                loading: loading,
                evidence: evidence,
              );
            },
          );
        },
      ),
    ]);
  }

  // ------------------------------------------------------------ tab: nearby

  Component _nearbyTab() {
    final score = _insights?.score;
    return _tabPanel('nearby', [
      LocationInsightsV4(
        propertyId: property.id,
        puScore: score?.value,
        hasPuScore: score != null,
      ),
      _districtSection(),
      _mapPanel(),
    ]);
  }

  /// The DOSM district demographics block, fed by the same cached evidence
  /// response the nearby categories use. District figures stay clearly
  /// separated from the 500 m / 1 km catchment estimates.
  Component _districtSection() {
    return FutureBuilder<PropertyEvidence>(
      future: component.evidenceFuture,
      builder: (c, snap) {
        final evidence = snap.connectionState == ConnectionState.done
            ? snap.data
            : null;
        return DistrictDemographicsPanel(
          statistics: evidence?.districtStatistics,
          residents500m: _evidenceMetric(evidence, 'pop_500m'),
          residents1km: _evidenceMetric(evidence, 'pop_1000m'),
        );
      },
    );
  }

  static EvidenceMetric? _evidenceMetric(PropertyEvidence? evidence, String key) {
    if (evidence == null) return null;
    for (final group in evidence.groups) {
      for (final metric in group.metrics) {
        if (metric.key == key) return metric;
      }
    }
    return null;
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
        'The 360° photo is being prepared.',
      );
    }
    if (property.hasTour) {
      return PanoramaMedia.unavailable(
        'The 360° photo is not ready to view yet.',
      );
    }
    return PanoramaMedia.unavailable(
      'No 360° photo is available for this property yet.',
    );
  }

  // ------------------------------------------------------------------- title

  Component _titleRow() => div(classes: 'sw-pd__top', [
        div(classes: 'sw-pd__top-nav', [
          ActionLink(
            'Back to recommendations',
            href: '/entrepreneur/recommendations',
            variant: 'ghost',
            icon: 'arrow_back',
          ),
          if (property.availability != null)
            StatusBadge(property.availability!, tone: 'neutral'),
        ]),
        div(classes: 'sw-pd__top-main', [
          span(classes: 'sw-pd__eyebrow', [
            Component.text('Commercial property'),
          ]),
          h1(classes: 'sw-pd__title', [Component.text(property.title)]),
          if (_addressLine.isNotEmpty)
            p(classes: 'sw-pd__addr', [Component.text(_addressLine)]),
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
              value == null || value.trim().isEmpty ? 'Not provided' : value,
            ),
          ],
        ),
      ]);

  Component _summaryCard() {
    final facilities = _facilities;
    final management = property.managerName == null ||
            property.managerName!.trim().isEmpty
        ? property.managementLabel
        : '${property.managementLabel} — ${property.managerName}';
    final description = property.description?.trim() ?? '';

    return div(classes: 'sw-pd__summary', [
      div(classes: 'sw-pd__summary-intro', [
        span(classes: 'sw-pd__eyebrow', [Component.text('Monthly rent')]),
        div(classes: 'sw-pd__price', [
          strong([Component.text(property.rentalDisplay)]),
          span([Component.text('/ month')]),
        ]),
      ]),
      div(classes: 'sw-pd__facts', [
        _fact('Floor area', '${property.sizeSqft.toStringAsFixed(0)} sq ft'),
        _fact('Property type', property.propertyType),
        _fact(
          'Rent per sq ft',
          'RM${property.rentalPerSqft.toStringAsFixed(2)} / sq ft',
        ),
        if (property.floorLevel != null && property.floorLevel!.trim().isNotEmpty)
          _fact('Floor level', property.floorLevel),
      ]),
      div(classes: 'sw-pd__management', [
        span(classes: 'sw-pd__management-label', [
          Component.text('Property management'),
        ]),
        strong(classes: 'sw-pd__management-value', [Component.text(management)]),
      ]),
      if (facilities.isNotEmpty) ...[
        h3(classes: 'sw-pd__section-label', [Component.text('Property features')]),
        div(classes: 'sw-pd__chips', [
          for (final facility in facilities.take(10))
            span(classes: 'sw-pd__chip', [Component.text(facility)]),
        ]),
      ],
      // Do not synthesize a repetitive description from the title.
      if (description.isNotEmpty)
        p(classes: 'sw-pd__desc', [Component.text(description)]),
      div(classes: 'sw-pd__actions', [
        div(classes: 'sw-pd__primary-action', [
          ActionLink(
            'Check this property',
            href: '/entrepreneur/assessments?id=${property.id}',
            variant: 'primary',
            icon: 'fact_check',
          ),
        ]),
        div(classes: 'sw-pd__secondary-actions', [
          ActionButton(
            saved ? 'Saved' : 'Save property',
            variant: 'secondary',
            icon: saved ? 'bookmark' : 'bookmark_border',
            onClick: onToggleSaved,
          ),
          ActionButton(
            compared ? 'In compare' : 'Add to compare',
            variant: 'secondary',
            icon: 'compare_arrows',
            onClick: onToggleCompared,
          ),
          ActionButton(
            'Copy summary',
            variant: 'ghost',
            icon: 'content_copy',
            onClick: _copySummary,
          ),
        ]),
      ]),
      if (saveMessage != null)
        span(classes: 'small text-success', [Component.text(saveMessage!)]),
      if (_copyMessage != null)
        span(classes: 'small', [Component.text(_copyMessage!)]),
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
              value == null || value.trim().isEmpty ? 'Not provided' : value,
            ),
          ],
        ),
      ]);

  Component _detailsPanel() {
    // Optional rows are listed only when the source recorded a value — a
    // missing fact is hidden rather than repeated as a "Not provided" row.
    // Recorded zeros and explicit false stay visible: they are real answers.
    String? sqft(double? v) =>
        v == null ? null : '${v.toStringAsFixed(0)} sq ft';
    String? feet(double? v) => v == null ? null : '${v.toStringAsFixed(0)} ft';
    String? text(String? v) =>
        (v == null || v.trim().isEmpty) ? null : v.trim();
    final rows = <(String, String?)>[
      ('Space size', sqft(property.sizeSqft)),
      ('Built-up area', sqft(property.builtUpSqft)),
      ('Land area', sqft(property.landAreaSqft)),
      ('Frontage', feet(property.frontageFt)),
      ('Depth', feet(property.depthFt)),
      ('Floor level', text(property.floorLevel)),
      ('Unit position', text(property.unitPosition)),
      ('Facing direction', text(property.facingDirection)),
      ('Toilets / bathrooms', property.bathrooms?.toString()),
      ('Furnishing', text(property.furnishing)),
      ('Tenure', text(property.tenure)),
      ('Parking', property.hasParking == null
          ? null
          : (property.hasParking! ? 'Onsite parking' : 'No onsite parking')),
      ('Suitable for a food business', property.isFnbSuitable == null
          ? null
          : (property.isFnbSuitable! ? 'Yes' : 'No')),
      ('Corner lot', property.isCornerLot == null
          ? null
          : (property.isCornerLot! ? 'Yes' : 'No')),
      ('Freehold', property.isFreehold == null
          ? null
          : (property.isFreehold! ? 'Yes' : 'No')),
      ('Availability', text(property.availability)),
      if (property.availabilityVerifiedAt != null &&
          property.availabilityVerifiedAt!.trim().isNotEmpty)
        (
          'Availability verified',
          property.availabilityVerifiedAt!.split('T').first,
        ),
    ].where(((row) => row.$2 != null && row.$2!.trim().isNotEmpty)).toList();
    final notice = text(property.listingDataNotice);
    return section(classes: 'sw-pd__details', [
      // The whole header row is the button: keyboard activation (Enter/Space)
      // comes free from the native <button>, and aria-expanded/aria-controls
      // expose the disclosure semantics to assistive technology.
      button(
        classes: 'sw-pd__details-toggle',
        attributes: {
          'type': 'button',
          'aria-expanded': '$_detailsOpen',
          'aria-controls': 'sw-pd-details-body',
        },
        events: events(onClick: () => setState(() => _detailsOpen = !_detailsOpen)),
        [
          Component.text(_detailsOpen ? 'Hide listing details' : 'Show listing details'),
          span(classes: 'sw-pd__details-chevron', [
            const Icon('expand_more', size: 'sm'),
          ]),
        ],
      ),
      // The body stays mounted so the grid-rows transition animates in both
      // directions; collapsed it is clamped to zero height, clipped, and
      // aria-hidden. Its rows are plain text — no focusables are ever trapped.
      div(
        classes: 'sw-pd__details-body${_detailsOpen ? ' is-open' : ''}',
        attributes: {
          'id': 'sw-pd-details-body',
          'aria-hidden': _detailsOpen ? 'false' : 'true',
        },
        [
          div(classes: 'sw-pd__details-body-inner', [
            div(classes: 'sw-pd__detail-grid', [
              for (final (label, value) in rows) _detailRow(label, value),
            ]),
            if (notice != null)
              p(classes: 'sw-pd__data-notice', [Component.text(notice)]),
          ]),
        ],
      ),
    ]);
  }

  // --------------------------------------------------------------------- map

  Component _mapPanel() {
    final layers = _insights?.mapLayers ?? const <MapLayer>[];
    return section(classes: 'sw-pd__map', [
      h2(classes: 'sw-pd__h2', [Component.text('Explore the surrounding area')]),
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
          'The circles show distances of 500 m and 1 km in a straight line, not '
          'actual walking or driving distances. The location may be approximate. '
          'Some nearby information is shown as totals because exact locations '
          'are not available.',
        ),
      ]),
    ]);
  }

  // ------------------------------------------------------------------- notes

  Component _notShownPanel() => section(classes: 'sw-pd__notes', [
        h2(classes: 'sw-pd__h2', [Component.text('Before you decide')]),
        ul([
          li([Component.text(
            'Check with the local council about business licences, kitchen '
            'ventilation and grease-trap requirements before renting.',
          )]),
          li([Component.text(
            'The information here cannot tell you how many customers you '
            'will get or how much your business will earn.',
          )]),
          li([Component.text(
            "The owner's contact details may not be available for this property.",
          )]),
        ]),
        p(classes: 'disclaimer', [
          Component.text(
            'The location score helps you compare areas. It does not predict '
            'profit, confirm regulatory approval or guarantee success.',
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
          title: 'Property not found',
          description: 'This property could not be loaded.',
        ),
        EmptyState(
          title: 'Property unavailable',
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
