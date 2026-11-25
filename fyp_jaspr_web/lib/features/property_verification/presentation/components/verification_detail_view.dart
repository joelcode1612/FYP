// SITEWISE_ADMIN_REVIEW_UI_V1
import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';
import 'package:universal_web/web.dart' as web;

import 'package:sitewise_jaspr_web/core/di/app_locator.dart';
import 'package:sitewise_jaspr_web/features/panorama_viewer/presentation/components/canonical_panorama_panel.dart';
import 'package:sitewise_jaspr_web/shared/presentation/components/property_leaflet_map.dart';
import 'package:sitewise_jaspr_web/shared/presentation/components/ui.dart';

/// The review workspace's right-hand content: everything the backend's
/// `/staff/properties/{id}/verification` detail returns, rendered once and
/// reused by both surfaces that load it — the review split's detail column
/// (`/admin/listings`) and the standalone `/admin/listing-detail` page.
///
/// Layout (converted from the `sitewise_admin_two_tab_review.html`
/// prototype, themed with the Admin Blue Edition tokens): a property hero,
/// Property overview, inspection, ownership and location intelligence tabs —
/// and a decision sidebar that sits OUTSIDE the tabs. Decisions dispatch
/// through [adminNotifierProvider] so the busy flag, the success notice and
/// the automatic queue/detail refresh stay in the shared controller.
/// Documents stream through the authenticated download endpoint
/// (`AppLocator.propertyVerificationRepo`) — never a public URL. Display
/// photos render from their permanent bucket URLs.
/// The optional panorama flag is a primitive `@client` constructor parameter;
/// the detail arrives through
/// [adminNotifierProvider] and renders via [_VerificationDetailBody].
@client
class VerificationDetailView extends StatefulComponent {
  final bool showPanorama;

  const VerificationDetailView({super.key, this.showPanorama = false});

  @override
  State<VerificationDetailView> createState() =>
      _VerificationDetailViewShellState();
}

class _VerificationDetailViewShellState extends State<VerificationDetailView> {
  @override
  Component build(BuildContext context) {
    final detail = context.watch(
      adminNotifierProvider.select((state) => state.reviewDetail),
    );
    if (detail == null) return Component.fragment([]);
    return _VerificationDetailBody(
      key: ValueKey('verification-detail-${detail.property.propertyId}'),
      detail: detail,
      showPanorama: component.showPanorama,
    );
  }
}

/// The rendering body. Not `@client` — it is instantiated by the shell above
/// with the already-loaded [VerificationDetail]; the [ValueKey] resets its
/// tab/checklist/note-form state whenever a different property is opened.
class _VerificationDetailBody extends StatefulComponent {
  final VerificationDetail detail;

  final bool showPanorama;

  const _VerificationDetailBody({
    super.key,
    required this.detail,
    required this.showPanorama,
  });

  @override
  State<_VerificationDetailBody> createState() =>
      _VerificationDetailBodyState();
}

class _VerificationDetailBodyState extends State<_VerificationDetailBody> {
  /// The selected content tab — `'overview'` or `'intelligence'`. Held in
  /// state so normal state refreshes (busy flags, notices, detail reloads)
  /// never bounce the admin back to the first tab.
  String _tab = 'overview';
  bool _activityExpanded = false;

  final Set<String> _checks = {};
  String? _decisionForm;
  String _affectedComponent = 'property';
  String _note = '';
  bool _decisionBusy = false;
  bool _panoramaReady = false;

  @override
  void didUpdateComponent(covariant _VerificationDetailBody oldComponent) {
    super.didUpdateComponent(oldComponent);
    if (oldComponent.detail.finalReview['token'] !=
        component.detail.finalReview['token']) {
      _checks.clear();
      _decisionForm = null;
      _note = '';
    }
    if (oldComponent.detail.finalReview['panorama_id'] !=
        component.detail.finalReview['panorama_id']) {
      _panoramaReady = false;
    }
  }

  final Set<String> _busyDocs = {};
  String? _downloadError;

  /// DOM-level keyboard handler for the tablist (roving tabindex, per the
  /// prototype's WAI-ARIA tabs pattern). Jaspr's `events()` helper exposes
  /// only click/input/change, so the keydown listener attaches to the
  /// rendered tablist element directly and detaches on dispose.
  web.EventListener? _tabKeyListener;
  web.Element? _tabListEl;

  List<String> get _tabIds => component.showPanorama
      ? const ['overview', 'panorama', 'ownership', 'intelligence']
      : const ['overview', 'intelligence'];

  @override
  void initState() {
    super.initState();
    Future.microtask(_attachTabKeys);
  }

  @override
  void dispose() {
    _locationTimer?.cancel();
    _detachTabKeys();
    super.dispose();
  }

  void _attachTabKeys() {
    if (!mounted || _tabListEl != null) return;
    final el = web.document.querySelector('.vd-tabs');
    if (el == null) return;
    _tabListEl = el;
    void onKey(web.Event event) {
      if (!event.isA<web.KeyboardEvent>()) return;
      final key = (event as web.KeyboardEvent).key;
      const handled = ['ArrowLeft', 'ArrowRight', 'Home', 'End'];
      if (!handled.contains(key)) return;
      final target = event.target;
      if (!target.isA<web.Element>()) return;
      final current = (target as web.Element).getAttribute('data-vd-tab');
      if (current == null) return;
      final index = _tabIds.indexOf(current);
      if (index < 0) return;
      event.preventDefault();
      final next = switch (key) {
        'Home' => 0,
        'End' => _tabIds.length - 1,
        'ArrowRight' => (index + 1) % _tabIds.length,
        _ => (index - 1 + _tabIds.length) % _tabIds.length,
      };
      setState(() => _tab = _tabIds[next]);
      if (_tabIds[next] == 'intelligence') unawaited(_refreshLocation());
      // Move focus with the selection (roving tabindex).
      (el.querySelector('[data-vd-tab="${_tabIds[next]}"]') as web.HTMLElement?)
          ?.focus();
    }

    final listener = onKey.toJS;
    _tabKeyListener = listener;
    el.addEventListener('keydown', listener);
  }

  void _detachTabKeys() {
    final listener = _tabKeyListener;
    if (_tabListEl != null && listener != null) {
      _tabListEl!.removeEventListener('keydown', listener);
    }
    _tabKeyListener = null;
    _tabListEl = null;
  }

  // --- Build ----------------------------------------------------------------

  @override
  Component build(BuildContext context) {
    final detail = component.detail;
    final notice = context.watch(
      adminNotifierProvider.select((state) => state.reviewNotice),
    );
    final error = context.watch(
      adminNotifierProvider.select((state) => state.error),
    );

    return div(
      classes: component.showPanorama ? 'vd stack vd--review-v3' : 'vd stack',
      [
        if (notice != null)
          div(classes: 'notice notice-info row', [
            span(classes: 'grow', [Component.text(notice)]),
            ActionButton(
              'Dismiss',
              variant: 'ghost',
              onClick: () => context
                  .read(adminNotifierProvider.notifier)
                  .clearReviewNotice(),
            ),
          ]),
        if (error != null)
          div(classes: 'notice notice-danger', [Component.text(error)]),
        if (component.showPanorama) _hero(detail),
        div(classes: 'vd-layout', [
          div(classes: 'vd-main stack', [
            if (!component.showPanorama) _hero(detail),
            _tabShell(),
            if (_tab == 'ownership')
              _ownershipEvidencePanel(detail)
            else if (_tab == 'overview')
              _overviewPanel(detail)
            else if (_tab == 'panorama' && component.showPanorama)
              div(
                id: 'vd-panel-panorama',
                classes: 'vd-pano-tab',
                attributes: {
                  'role': 'tabpanel',
                  'aria-labelledby': 'vd-tab-panorama',
                },
                [
                  CanonicalPanoramaPanel(
                    key: ValueKey(detail.finalReview['panorama_id']),
                    evidenceOnly: true,
                    onEvidenceReady: () =>
                        setState(() => _panoramaReady = true),
                    expectedPanoramaId:
                        detail.finalReview['panorama_id'] as String?,
                    propertyId: '${detail.property.propertyId}',
                  ),
                ],
              )
            else
              _intelligencePanel(detail),
          ]),
          _reviewSidebar(detail),
        ]),
      ],
    );
  }

  // --- Hero -------------------------------------------------------------------

  Component _hero(VerificationDetail detail) {
    final property = detail.property;
    final verification = detail.verification;
    final psf = property.rentPerSqft;
    return section(classes: 'card vd-hero', [
      div(classes: 'vd-hero__intro', [
        div(classes: 'vd-hero__label', [
          Component.text(
            'Property submission · Property #${property.propertyId}',
          ),
        ]),
        h2(classes: 'vd-hero__title', [Component.text(property.displayName)]),
        p(classes: 'vd-hero__address', [
          Component.text(_fullAddress(property)),
        ]),
        if (detail.owner != null)
          p(classes: 'small muted', [
            Component.text(
              'Submitted by ${detail.owner!.displayName}'
              '${detail.owner!.email.isEmpty ? '' : ' · ${detail.owner!.email}'}',
            ),
          ]),
        div(classes: 'vd-hero__chips', [
          _statusPill(
            verification.statuses.statusOf(VerificationDimension.listing),
          ),
          if ((property.propertyType ?? '').trim().isNotEmpty)
            span(classes: 'chip', [Component.text(property.propertyType!)]),
          Pill(
            property.isPublished == true ? 'Published' : 'Unpublished',
            tone: property.isPublished == true ? 'success' : 'neutral',
          ),
          if (property.addressValidationStatus == 'validated')
            const Pill('Address validated', tone: 'action'),
        ]),
      ]),
      div(classes: 'vd-hero__facts', [
        _fact(
          'Monthly rent',
          property.monthlyRent == null
              ? 'Not provided'
              : 'RM ${property.monthlyRent!.toStringAsFixed(0)}',
          'Owner-entered price',
        ),
        _fact(
          'Built-up area',
          property.builtUpAreaSqft == null
              ? 'Not provided'
              : '${property.builtUpAreaSqft!.toStringAsFixed(0)} sq ft',
          'Owner-entered size',
        ),
        _fact(
          'Rent per sq ft',
          psf == null ? 'Not derivable' : 'RM ${psf.toStringAsFixed(2)}',
          'Derived from the entered values',
        ),
        _fact(
          'Availability',
          _orNotProvided(property.availability),
          'Owner assertion only',
        ),
      ]),
    ]);
  }

  Component _fact(String label, String value, String note) =>
      div(classes: 'vd-fact', [
        span(classes: 'vd-fact__label', [Component.text(label)]),
        strong(classes: 'vd-fact__value', [Component.text(value)]),
        span(classes: 'vd-fact__note', [Component.text(note)]),
      ]);

  // --- Tabs -------------------------------------------------------------------

  Component _ownershipEvidencePanel(VerificationDetail detail) => section(
    id: 'vd-panel-ownership',
    classes: 'card card-pad vd-panel sw-admin-evidence',
    attributes: {'role': 'tabpanel', 'aria-labelledby': 'vd-tab-ownership'},
    [
      h3([Component.text('Ownership evidence')]),
      p(classes: 'body muted', [
        Component.text(
          'Review the submitted documents before recording an ownership decision.',
        ),
      ]),
      _documents(detail),
    ],
  );

  Component _tabShell() {
    return div(
      classes: 'vd-tabs',
      attributes: {'role': 'tablist', 'aria-label': 'Property review detail'},
      [
        _tabButton('overview', 'Property overview'),
        if (component.showPanorama) _tabButton('panorama', '360° inspection'),
        _tabButton('ownership', 'Ownership evidence'),
        _tabButton('intelligence', 'Location intelligence'),
      ],
    );
  }

  Component _tabButton(String id, String label) {
    final selected = _tab == id;
    return button(
      classes: 'vd-tab${selected ? ' is-active' : ''}',
      attributes: {
        'type': 'button',
        'role': 'tab',
        'id': 'vd-tab-$id',
        'aria-controls': 'vd-panel-$id',
        'aria-selected': '$selected',
        'tabindex': selected ? '0' : '-1',
        'data-vd-tab': id,
      },
      events: events(onClick: () => _selectTab(id)),
      [Component.text(label)],
    );
  }

  /// Switches tabs and loads the selected panel's live state.
  ///
  /// The Intelligence panel has to read the persisted measurement state
  /// directly. The association embedded in the review detail was assembled when
  /// the page was opened: it carries neither the live queue status nor the
  /// address-resolution capability, and those are exactly what the action
  /// buttons and the feature counters depend on. Without this fetch the panel
  /// renders stale counters and disabled actions until the reviewer presses
  /// something first.
  void _selectTab(String id) {
    setState(() => _tab = id);
    if (id == 'intelligence') unawaited(_refreshLocation());
  }

  // --- Tab 1: Property Overview -------------------------------------------------

  Component _overviewPanel(VerificationDetail detail) {
    final property = detail.property;
    final inspection = detail.finalReview['inspection'] as Map? ?? const {};
    final inspectionNotes =
        detail.finalReview['inspection_notes'] as Map? ?? const {};
    return section(
      id: 'vd-panel-overview',
      classes: 'card card-pad vd-panel',
      attributes: {'role': 'tabpanel', 'aria-labelledby': 'vd-tab-overview'},
      [
        div(classes: 'vd-section-head', [
          div(classes: 'stack', [
            h3([Component.text('Property overview')]),
            p(classes: 'small muted', [
              Component.text(
                'Owner-declared listing information alongside evidence reviewed for verification.',
              ),
            ]),
          ]),
          span(classes: 'chip', [Component.text('Owner-provided')]),
        ]),
        div(classes: 'vd-overview-grid', [
          if (inspection.isNotEmpty)
            section(classes: 'vd-panel', [
              h3([Component.text('Submitted Agent inspection checklist')]),
              for (final (key, title) in const [
                ('floor_area_verified', 'Floor area'),
                ('condition_verified', 'Condition'),
                ('parking_verified', 'Parking'),
                ('accessibility_verified', 'Accessibility'),
              ])
                _infoRow(
                  title,
                  inspection[key] == true
                      ? 'Verified on site'
                      : 'Not confirmed',
                ),
            ]),
          for (final (key, title) in const [
            ('condition_notes', 'Condition notes'),
            ('parking_notes', 'Parking notes'),
            ('accessibility_notes', 'Accessibility notes'),
          ])
            if (inspectionNotes[key] case final String note)
              _infoRow(title, note),
          _photos(detail),
          div(classes: 'stack', [
            h4(classes: 'vd-group-title', [
              Component.text('Listing information'),
            ]),
            div(classes: 'vd-info', [
              _infoRow('Property ID', '${property.propertyId}'),
              _infoRow('Property type', _orNotProvided(property.propertyType)),
              _infoRow('Floor level', _orNotProvided(property.floorLevel)),
              _infoRow('Unit position', _orNotProvided(property.unitPosition)),
              _infoRow('Furnishing', _orNotProvided(property.furnishing)),
              _infoRow(
                'Frontage',
                property.frontageFt == null
                    ? 'Not provided'
                    : '${_num(property.frontageFt)} ft · owner-entered',
              ),
              _infoRow('Parking', _parkingLabel(property.hasParking)),
              _infoRow('F&B suitability', _fnbLabel(property.isFnbSuitable)),
              _infoRow('Availability', _orNotProvided(property.availability)),
              _infoRow(
                'Available from',
                _orNotProvided(property.availableFrom),
              ),
              _infoRow(
                'Minimum rental period',
                property.leaseDurationNegotiable == true
                    ? 'Negotiable'
                    : property.leaseDurationMonths == null
                    ? 'Not provided'
                    : '${property.leaseDurationMonths} months',
              ),
              _infoRow(
                'Rental deposit',
                property.rentalDepositMyr == null
                    ? 'Not provided'
                    : 'RM ${_num(property.rentalDepositMyr)}',
              ),
              _infoRow('Tenure', _orNotProvided(property.tenure)),
              _infoRow('Title type', _orNotProvided(property.titleType)),
              _infoRow(
                'Landlord F&B permission (owner-declared)',
                _orNotProvided(property.landlordFnbPermission),
              ),
            ]),
          ]),
        ]),
        div(classes: 'vd-divider', []),
        h4(classes: 'vd-group-title', [
          Component.text('Address & property facts'),
        ]),
        div(classes: 'vd-info vd-info--two', [
          _infoRow('Street address', _orNotProvided(property.address)),
          _infoRow('City / district', _orNotProvided(property.city)),
          _infoRow('State', _orNotProvided(property.state)),
          _infoRow('Postcode', _orNotProvided(property.postcode)),
          _infoRow(
            'Coordinates',
            property.hasCoordinates
                ? '${_num(property.latitude)}, ${_num(property.longitude)}'
                : 'Missing coordinates',
          ),
          _infoRow(
            'Address validation',
            switch (property.addressValidationStatus) {
              'validated' => 'Validated by the provider',
              final other? => other.replaceAll('_', ' '),
              _ => 'Not validated',
            },
          ),
          _infoRow(
            'Google-formatted address',
            _orNotProvided(property.addressFormatted),
          ),
          _infoRow('Record status', _orNotProvided(property.status)),
        ]),
        h4(classes: 'vd-group-title', [Component.text('Description')]),
        p(classes: 'vd-description', [
          Component.text(_orNotProvided(property.description)),
        ]),
      ],
    );
  }

  Component _photos(VerificationDetail detail) {
    final photos = detail.photos.where((photo) => photo.isUsable).toList();
    if (photos.isEmpty) {
      return div(classes: 'vd-photo-empty', [
        span(classes: 'vd-photo-empty__symbol', [
          const Icon('image', size: 'lg'),
        ]),
        strong([Component.text('No property photos submitted')]),
        p([
          Component.text(
            'This view only shows photos the entrepreneur uploaded to this '
            'property. Unrelated stock or catalogue photos are never '
            'substituted here.',
          ),
        ]),
      ]);
    }
    return div(classes: 'stack', [
      div(classes: 'vd-photos', [
        for (final (index, photo) in photos.indexed)
          img(
            src: photo.url,
            alt: (photo.caption == null || photo.caption!.trim().isEmpty)
                ? 'Photo ${index + 1} of ${component.detail.property.displayName}'
                : photo.caption!,
            classes: 'vd-photo',
          ),
      ]),
      if (photos.length > 1)
        p(classes: 'small muted', [
          Component.text('${photos.length} photos uploaded by the submitter.'),
        ]),
    ]);
  }

  // --- Tab 2: Location Intelligence ----------------------------------------------

  /// The pipeline's actual state, in the order the work happens.
  ///
  /// The distinction that matters is not "has a score" but "how far did this
  /// listing get": an address that cannot be geocoded is a different problem
  /// from a queue that has not been started, and both are different from
  /// measurements that were attempted and partly failed. Each label is derived
  /// from persisted state only — nothing here is inferred from a timer.
  String _pipelineLabel(LocationResearchAssociation location) {
    if (!location.hasCoordinates) {
      if (location.addressGeocodable) {
        return 'Geocoding required';
      }
      return location.addressMissingFields.isEmpty
          ? 'Data unavailable'
          : 'Address verification required';
    }
    if (_locationActive(location)) {
      return location.calculationStatus == 'running'
          ? 'Analysis processing'
          : 'Analysis queued';
    }
    return switch (location.calculationStatus) {
      'failed' => 'Analysis failed',
      'stale' => 'Stale · recalculate',
      'current' when location.calculatedFeatures >= 64 => 'Analysis completed',
      'current' when location.calculatedFeatures > 0 =>
        'Analysis partially completed',
      _ => location.calculatedFeatures > 0
          ? 'Analysis partially completed'
          : 'Not calculated',
    };
  }

  Component _intelligencePanel(VerificationDetail detail) {
    final property = detail.property;
    final geo = detail.geoFeatures;
    final research = detail.population;
    final location =
        _liveLocation ?? detail.locationAnalysis.partB.researchAssociation;
    final calculated = geo != null || location.calculatedFeatures > 0;
    final state = _pipelineLabel(location);

    return section(
      id: 'vd-panel-intelligence',
      classes: 'card card-pad vd-panel',
      attributes: {
        'role': 'tabpanel',
        'aria-labelledby': 'vd-tab-intelligence',
      },
      [
        div(classes: 'vd-section-head', [
          div(classes: 'stack', [
            h3([Component.text('Location intelligence')]),
          ]),
          Pill(state, tone: calculated ? 'action' : 'neutral'),
        ]),
        // Data freshness (Phase 10/11). Read-only: the value comes from
        // fyp.property_feature_freshness, never recomputed on page load.
        // An unknown state is explicit — never shown as zero.
        if (detail.freshness != null)
          div(classes: 'vd-freshness', [
            Pill(
              detail.freshness!.label,
              tone: switch (detail.freshness!.status) {
                'current' => 'success',
                'stale' || 'pending' => 'warning',
                'failed' => 'danger',
                _ => 'neutral',
              },
            ),
            span(classes: 'small muted', [
              Component.text(
                [
                  if (detail.freshness!.lastSuccessfulRefreshAt != null)
                    'Last successful refresh '
                        '${_fmtDate(detail.freshness!.lastSuccessfulRefreshAt)}',
                  if (detail.freshness!.sourceRelease != null)
                    'source ${detail.freshness!.sourceRelease}',
                  if (detail.freshness!.calculationVersion != null)
                    'calc ${detail.freshness!.calculationVersion}',
                ].join(' · '),
              ),
            ]),
          ]),
        if (detail.freshness?.lastError != null)
          div(classes: 'vd-note vd-note--warning', [
            span(classes: 'vd-note__symbol', [Component.text('!')]),
            Component.text(
              'The last feature calculation failed (${detail.freshness!.lastError}). '
              'Previously calculated values, when present, remain readable '
              'and are labelled rather than replaced with zeros.',
            ),
          ]),
        if (detail.provenance.isNotEmpty)
          p(classes: 'vd-source', [
            Component.text(
              'Sources: '
              '${detail.provenance.map((prov) => '${prov.sourceName}${prov.licence == null ? '' : ' (${prov.licence})'}').join(' · ')}',
            ),
          ]),
        if (!calculated)
          div(classes: 'vd-note vd-note--warning', [
            span(classes: 'vd-note__symbol', [Component.text('!')]),
            Component.text(
              'Not calculated for this property. New listings may not have '
              'analytical data yet — the property details can still be '
              'reviewed, and no competitor, population or accessibility '
              'figure is invented here.',
            ),
          ]),
        h4(classes: 'vd-group-title', [
          Component.text('PU location suitability'),
        ]),
        _researchAssociationPanel(location),
        _analysisContext(location),
        _expanded64Evidence(detail),
        _analysisReadiness(detail),
        h4(classes: 'vd-group-title', [Component.text('Property location')]),
        div(classes: 'vd-map-layout', [
          PropertyLeafletMap(property: _mapProperty(property), height: 260),
          div(classes: 'vd-info', [
            _infoRow(
              'City / state',
              [property.city, property.state]
                  .whereType<String>()
                  .where((part) => part.trim().isNotEmpty)
                  .join(' · '),
              fallback: 'Not provided',
            ),
            _infoRow(
              'Coordinates',
              property.hasCoordinates
                  ? '${_num(property.latitude)}, ${_num(property.longitude)}'
                  : 'Missing coordinates',
            ),
            _infoRow(
              'Address validation',
              switch (property.addressValidationStatus) {
                'validated' => 'Validated by the provider',
                final other? => other.replaceAll('_', ' '),
                _ => 'Not validated',
              },
            ),
            _infoRow('Market segment', _orNotProvided(geo?.marketSegment)),
          ]),
        ]),
        if (location.calculatedFeatures == 0) ...[
          h4(classes: 'vd-group-title', [
            Component.text('Market and catchment indicators'),
          ]),
          p(classes: 'small muted', [
            Component.text(
              calculated
                  ? 'Measured for this property in straight-line radii.'
                  : 'No verified analytical feature snapshot for this listing.',
            ),
          ]),
          div(classes: 'vd-metrics', [
            _metric(
              'F&B competitors · 500 m',
              geo?.competitorCount500m,
              _countNote(
                geo,
                'competitor_status',
                'Straight-line research radius',
              ),
            ),
            _metric(
              'F&B competitors · 1 km',
              geo?.competitorCount1km,
              _countNote(geo, 'competitor_status', 'The 500 m set is included'),
            ),
            _metric(
              'Population · 500 m',
              research?.pop500m ?? geo?.population500m,
              research != null
                  ? _populationNote(research)
                  : 'Modelled catchment estimate when sourced',
            ),
            _metric(
              'Population · 1 km',
              research?.pop1km ?? geo?.population1km,
              research != null
                  ? _populationNote(research)
                  : 'Modelled catchment estimate when sourced',
            ),
            _metric(
              'Demand generators · 500 m',
              geo?.demandGeneratorCount500m,
              _countNote(geo, 'demand_status', 'Nearby activity destinations'),
            ),
            _metric(
              'Demand generators · 1 km',
              geo?.demandGeneratorCount1km,
              _countNote(geo, 'demand_status', 'Nearby activity destinations'),
            ),
            _metric(
              'Accessibility score',
              geo?.accessibilityScore,
              _countNote(
                geo,
                'accessibility_status',
                'Backend-calculated index',
              ),
            ),
            _metric(
              'Nearest major road',
              geo?.nearestMajorRoadM,
              'Straight-line distance in metres',
              suffix: ' m',
            ),
            _metric(
              'District income',
              geo?.incomeMedian,
              'District median (RM); source and period vary',
              prefix: 'RM ',
            ),
          ]),
        ],
        if (research != null) ...[
          h4(classes: 'vd-group-title', [
            Component.text('Research population snapshot'),
          ]),
          p(classes: 'small muted', [
            Component.text(
              'Resolved through the verified research subject link — not a '
              'live raster measurement of this listing.',
            ),
          ]),
          div(classes: 'vd-info vd-info--two', [
            _infoRow(
              'Population within 500 m ring',
              _orNotCalculated(research.pop500m),
            ),
            _infoRow(
              'Population within 1 km',
              _orNotCalculated(research.pop1km),
            ),
            _infoRow(
              'Density (per km²)',
              _orNotCalculated(research.popDensityKm2),
            ),
            _infoRow(
              'Estimated households · 1 km',
              _orNotCalculated(research.estimatedHouseholds1km),
            ),
            _infoRow(
              'Population source',
              [
                if (research.source != null && research.source!.isNotEmpty)
                  research.source!,
                if (research.sourceYear != null &&
                    research.sourceYear!.isNotEmpty)
                  '(${research.sourceYear})',
              ].join(' ').trim(),
              fallback: 'Not recorded',
            ),
            _infoRow('Quality flag', _orNotProvided(research.qualityFlag)),
          ]),
        ],
        h4(classes: 'vd-group-title', [
          Component.text('Nearby demand generators · within 1 km'),
        ]),
        _demandGenerators(detail),
        h4(classes: 'vd-group-title', [
          Component.text('Surrounding amenities'),
        ]),
        _amenities(detail.amenities),
        _analysisIntelligence(detail),
        _analysisReliability(detail),
        _analysisRecommendation(detail),
        p(classes: 'vd-notes', [
          Component.text(
            'Competition counts represent F&B outlets from the research '
            'datasets, not the number of available rental units. Population '
            'estimates and density are distinct measurements. All distances '
            'and radii are straight-line (geodesic) measurements — they are '
            'not walking or driving distances.',
          ),
        ]),
      ],
    );
  }

  Component _demandGenerators(VerificationDetail detail) {
    final generators = detail.demandGenerators;
    if (generators.isEmpty) {
      return EmptyState(
        title: 'No demand generators listed',
        body: component.detail.property.hasCoordinates
            ? 'No demand-generator records fall within 1 km of this listing.'
            : 'The listing has no usable coordinates, so no nearby search '
                  'can be performed.',
      );
    }
    return div(classes: 'vd-demand', [
      for (final generator in generators)
        div(classes: 'vd-demand__row', [
          div(classes: 'grow', [
            strong([Component.text(generator.name)]),
            if ((generator.category ?? '').trim().isNotEmpty)
              span(classes: 'small muted', [
                Component.text(' · ${generator.category}'),
              ]),
          ]),
          if (generator.distanceM != null)
            span(classes: 'vd-demand__distance', [
              Component.text('${generator.distanceM!.round()} m'),
            ]),
        ]),
    ]);
  }

  Component _amenities(VerificationAmenities? amenities) {
    if (amenities == null || amenities.isEmpty) {
      return p(classes: 'body muted', [
        Component.text('Not provided for this property.'),
      ]);
    }
    return div(classes: 'vd-info', [
      _infoRow('Suitable for', _orNotProvided(amenities.suitableFor)),
      _infoRow('Nearby landmarks', _orNotProvided(amenities.nearbyLandmarks)),
      _infoRow('Amenities', _orNotProvided(amenities.amenities)),
      _infoRow('Remarks', _orNotProvided(amenities.remarks)),
    ]);
  }

  // --- Structured location analysis (Parts A / B / C + recommendation) ----

  /// Part A: readiness banner with the server's evidence checks. Rendered
  /// even when the analysis is unavailable (then as a plain warning) so a
  /// broken analysis never looks like a decision input.
  Component _analysisReadiness(VerificationDetail detail) {
    final analysis = detail.locationAnalysis;
    if (!analysis.available) {
      final message = (analysis.error ?? '').trim();
      if (message.isEmpty) return Component.fragment([]);
      return div(classes: 'vd-note vd-note--warning', [
        span(classes: 'vd-note__symbol', [Component.text('!')]),
        Component.text('Location analysis could not be assembled: $message'),
      ]);
    }
    final partA = analysis.partA;
    final (label, tone) = switch (partA.state) {
      'ready_for_admin_review' => ('Ready for review', 'success'),
      'additional_information_required' => (
        'Additional information required',
        'warning',
      ),
      'analysis_incomplete' => ('Analysis incomplete', 'warning'),
      'validation_failed' => ('Validation failed', 'danger'),
      'not_submitted' => ('Not yet submitted', 'neutral'),
      final other => (other.replaceAll('_', ' '), 'neutral'),
    };
    return div(classes: 'stack', [
      h4(classes: 'vd-group-title', [Component.text('Review readiness')]),
      p(classes: 'small muted', [
        Component.text(
          'An automated check of what the listing already has on file. It '
          'describes readiness only — it never approves or rejects anything.',
        ),
      ]),
      div(classes: 'vd-freshness', [Pill(label, tone: tone)]),
      div(classes: 'vd-info', [
        for (final check in partA.checks)
          div(classes: 'vd-row', [
            span(classes: 'vd-row__label', [Component.text(check.label)]),
            strong(classes: 'vd-row__value', [Component.text(check.detail)]),
          ]),
      ]),
    ]);
  }

  /// Part B: the five measurement families with their method and an explicit
  /// unavailable reason when a family has no measurement. Rows with no value
  /// stay hidden rather than showing zeros.
  Component _analysisIntelligence(VerificationDetail detail) {
    final partB = detail.locationAnalysis.partB;
    return Component.fragment([
      h4(classes: 'vd-group-title', [
        Component.text('Population and catchment'),
      ]),
      p(classes: 'small muted', [Component.text(partB.population.method)]),
      partB.population.available
          ? div(classes: 'vd-info', [
              for (final row in [
                ('Population within 500 m', _num(partB.population.pop500m)),
                ('Population within 1 km', _num(partB.population.pop1km)),
                ('Population within 3 km', _num(partB.population.pop3km)),
                ('Density per km² (1 km)', _num(partB.population.density1km)),
                (
                  'Estimated households · 1 km',
                  _num(partB.population.estimatedHouseholds1km),
                ),
                (
                  'Young adults share · 1 km (20–34)',
                  partB.population.pctAge2034 == null
                      ? null
                      : '${_num(partB.population.pctAge2034)}%',
                ),
                (
                  'Working-age share · 1 km (15–64)',
                  partB.population.pctAge1564 == null
                      ? null
                      : '${_num(partB.population.pctAge1564)}%',
                ),
                ('Data source', partB.population.source),
                (
                  'Raster coverage of the area',
                  partB.population.rasterCoveragePct == null
                      ? null
                      : '${_num(partB.population.rasterCoveragePct)}% · '
                            'quality ${_orNotProvided(partB.population.qualityFlag)}',
                ),
                if (partB.population.landscanAmbient1km != null) ...[
                  (
                    'Ambient population · 1 km (LandScan '
                        '${_orNotProvided(partB.population.landscanSourceYear)})',
                    _num(partB.population.landscanAmbient1km),
                  ),
                  (
                    'Ambient-to-resident ratio · 1 km',
                    _num(partB.population.landscanAmbientRatio1km),
                  ),
                ],
              ])
                if (row.$2 != null) _infoRow(row.$1, row.$2!),
            ])
          : _unavailableNote(partB.population.unavailableReason),
      if (partB.population.available)
        p(classes: 'vd-source', [
          Component.text(
            'Resident estimates and the ambient (LandScan) figure are two '
            'different measurements and are never added together.',
          ),
        ]),
      h4(classes: 'vd-group-title', [Component.text('Income context')]),
      p(classes: 'small muted', [Component.text(partB.socioeconomic.method)]),
      partB.socioeconomic.available
          ? div(classes: 'vd-info', [
              _infoRow(
                'District median household income',
                'RM ${_num(partB.socioeconomic.incomeMedian)}',
              ),
              _infoRow(
                'Reference area',
                partB.socioeconomic.districtKey == null
                    ? 'The district containing this listing (key not recorded)'
                    : 'DOSM district · ${partB.socioeconomic.districtKey}',
              ),
            ])
          : _unavailableNote(partB.socioeconomic.unavailableReason),
      h4(classes: 'vd-group-title', [
        Component.text('Food & beverage surroundings'),
      ]),
      p(classes: 'small muted', [Component.text(partB.fnbEnvironment.method)]),
      partB.fnbEnvironment.available
          ? div(classes: 'vd-info', [
              for (final row in [
                (
                  'F&B competitors · 500 m',
                  _num(partB.fnbEnvironment.competitorCount500m),
                ),
                (
                  'F&B competitors · 1 km',
                  _num(partB.fnbEnvironment.competitorCount1km),
                ),
                (
                  'Cafés · 500 m',
                  _num(
                    partB.fnbEnvironment.competitorBreakdown500m['cafes_500m'],
                  ),
                ),
                (
                  'Restaurants · 500 m',
                  _num(
                    partB
                        .fnbEnvironment
                        .competitorBreakdown500m['restaurants_500m'],
                  ),
                ),
                (
                  'Fast food · 500 m',
                  _num(
                    partB
                        .fnbEnvironment
                        .competitorBreakdown500m['fast_food_500m'],
                  ),
                ),
                (
                  'Nearest competitor (straight line)',
                  partB.fnbEnvironment.nearestCompetitorM == null
                      ? null
                      : '${_num(partB.fnbEnvironment.nearestCompetitorM)} m',
                ),
                (
                  'Demand generators · 500 m',
                  _num(partB.fnbEnvironment.demandGeneratorCount500m),
                ),
                (
                  'Demand generators · 1 km',
                  _num(partB.fnbEnvironment.demandGeneratorCount1km),
                ),
                (
                  'Malls · 1 km',
                  _num(partB.fnbEnvironment.nearbyAnchors['malls_1km']),
                ),
                (
                  'Schools · 1 km',
                  _num(partB.fnbEnvironment.nearbyAnchors['schools_1km']),
                ),
                (
                  'Universities · 1 km',
                  _num(partB.fnbEnvironment.nearbyAnchors['universities_1km']),
                ),
                (
                  'Hospitals · 1 km',
                  _num(partB.fnbEnvironment.nearbyAnchors['hospitals_1km']),
                ),
                (
                  'Office premises · 500 m',
                  _num(partB.fnbEnvironment.nearbyAnchors['office_poi_500m']),
                ),
                (
                  'Owner declares the unit F&B-suitable',
                  partB.fnbEnvironment.ownerDeclaredFnbSuitable == null
                      ? null
                      : (partB.fnbEnvironment.ownerDeclaredFnbSuitable!
                            ? 'Yes'
                            : 'No'),
                ),
              ])
                if (row.$2 != null) _infoRow(row.$1, row.$2!),
            ])
          : _unavailableNote(partB.fnbEnvironment.unavailableReason),
      if (partB.fnbEnvironment.available)
        p(classes: 'vd-source', [
          Component.text(
            'Competitor counts describe how busy the area already is — '
            'established food streets also draw customers. They are context '
            'for your judgement, never a verdict on their own.',
          ),
        ]),
      h4(classes: 'vd-group-title', [
        Component.text('Getting there: roads, transit and parking'),
      ]),
      p(classes: 'small muted', [Component.text(partB.accessibility.method)]),
      partB.accessibility.available
          ? div(classes: 'vd-info', [
              for (final row in [
                (
                  'Accessibility index',
                  _num(partB.accessibility.accessibilityScore),
                ),
                (
                  'Road length within 1 km',
                  partB.accessibility.roadKm1km == null
                      ? null
                      : '${_num(partB.accessibility.roadKm1km)} km',
                ),
                (
                  'Nearest major road (straight line)',
                  partB.accessibility.nearestMajorRoadM == null
                      ? null
                      : '${_num(partB.accessibility.nearestMajorRoadM)} m',
                ),
                (
                  'Bus stops within a 500 m walk',
                  _num(partB.accessibility.transit['bus_stops_500m_walk']),
                ),
                (
                  'Rail stations within a 1 km walk',
                  _num(partB.accessibility.transit['rail_stations_1km_walk']),
                ),
                (
                  'Nearest transit stop (walking distance)',
                  partB.accessibility.transit['nearest_transit_walk_m'] == null
                      ? null
                      : '${_num(partB.accessibility.transit['nearest_transit_walk_m'])} m',
                ),
                (
                  'Parking facilities · 500 m',
                  _num(partB.accessibility.parking['facilities_500m']),
                ),
                (
                  'Nearest parking (straight line)',
                  partB.accessibility.parking['nearest_parking_m'] == null
                      ? null
                      : '${_num(partB.accessibility.parking['nearest_parking_m'])} m',
                ),
                (
                  'Owner declares on-site parking',
                  partB.accessibility.ownerDeclaredParking == null
                      ? null
                      : (partB.accessibility.ownerDeclaredParking!
                            ? 'Yes'
                            : 'No'),
                ),
              ])
                if (row.$2 != null) _infoRow(row.$1, row.$2!),
            ])
          : _unavailableNote(partB.accessibility.unavailableReason),
    ]);
  }

  // SITEWISE_ADMIN_EXPANDED64_V1
  LocationResearchAssociation? _liveLocation;
  Timer? _locationTimer;
  bool _locationRequest = false;
  String? _locationError;
  String? _locationNotice;

  bool _locationActive(LocationResearchAssociation value) =>
      value.predictionPending ||
      value.calculationStatus == 'pending' ||
      value.calculationStatus == 'running';

  /// Whether an analysis action can do real work for this listing.
  ///
  /// Stored coordinates are the direct case. A listing with a saved street,
  /// city and state is the indirect one: the backend geocodes it before
  /// queueing, so disabling the action on `hasCoordinates` alone made a
  /// perfectly analysable listing unreachable. Only a listing with neither
  /// coordinates nor a geocodable address is genuinely blocked.
  bool _canAnalyse(LocationResearchAssociation value) =>
      value.hasCoordinates || value.addressGeocodable;

  void _scheduleLocationRefresh() {
    if (_tab != 'intelligence' ||
        _locationTimer?.isActive == true ||
        _locationRequest) {
      return;
    }
    _locationTimer = Timer(const Duration(seconds: 2), _refreshLocation);
  }

  Future<void> _refreshLocation() async {
    if (!mounted || _locationRequest) return;
    _locationRequest = true;
    try {
      final value = await AppLocator.propertyVerificationRepo
          .locationIntelligence(
            component.detail.property.propertyId.toString(),
          );
      if (mounted) {
        setState(() {
          _liveLocation = value;
          _locationError = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _locationError = 'Could not refresh measurements. Try again.',
        );
      }
    } finally {
      _locationRequest = false;
      if (mounted &&
          _locationError == null &&
          _liveLocation != null &&
          _locationActive(_liveLocation!)) {
        _scheduleLocationRefresh();
      }
    }
  }

  /// Runs only the categories that are missing, failed or stale for the
  /// current coordinates. [full] is the explicit full recalculation.
  Future<void> _runAnalysis({bool full = false}) async {
    if (_locationRequest) return;
    setState(() {
      _locationRequest = true;
      _locationError = null;
      _locationNotice = null;
    });
    try {
      final notice = await AppLocator.propertyVerificationRepo
          .analyzeLocationIntelligence(
            component.detail.property.propertyId.toString(),
            full: full,
          );
      if (mounted && notice != null) setState(() => _locationNotice = notice);
    } catch (_) {
      if (mounted) {
        setState(
          () => _locationError = 'Could not queue the calculation. Try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _locationRequest = false);
    }
    if (mounted && _locationError == null) await _refreshLocation();
  }

  Future<void> _queueLocation([String? category]) async {
    if (_locationRequest) return;
    setState(() {
      _locationRequest = true;
      _locationError = null;
      _locationNotice = null;
    });
    try {
      final notice = await AppLocator.propertyVerificationRepo
          .queueLocationIntelligence(
            component.detail.property.propertyId.toString(),
            category: category,
          );
      if (mounted && notice != null) setState(() => _locationNotice = notice);
    } catch (_) {
      if (mounted) {
        setState(
          () => _locationError = 'Could not queue the calculation. Try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _locationRequest = false);
    }
    if (mounted && _locationError == null) await _refreshLocation();
  }

  Component _analysisContext(LocationResearchAssociation location) {
    final context = location.districtContext;
    return div(classes: 'vd-info', [
      h4([Component.text('Household and income')]),
      if (context['district'] != null)
        _infoRow(
          'DOSM district and release',
          "${context['district']}, ${context['state']} · ${context['date'] ?? 'Release unavailable'}",
        ),
      _infoRow(
        'Median household income · RM/month',
        _num(context['income_median'] as num?),
      ),
      _infoRow(
        'Mean household income · RM/month',
        _num(context['income_mean'] as num?),
      ),
      h4([Component.text('Environmental and disaster information')]),
      _infoRow(
        'Flood and disaster evidence',
        'Not available — no verified flood or disaster dataset is integrated, '
            'so no value is inferred',
      ),
    ]);
  }

  String _addressVerdict(String? status) => switch (status) {
    'validated' =>
      'Location confirmed by the address check (precise premise-level match).',
    'partially_validated' =>
      'Location obtained from an approximate or ambiguous provider match. '
          'Measurements use these coordinates; the pin may need confirming.',
    'invalid' || 'invalidated' =>
      'The stored location is no longer confirmed. Re-verify the address before '
          'relying on these measurements.',
    _ =>
      'The stored coordinates were entered without a provider verdict, so they '
          'are measured but not described as confirmed.',
  };

  String _measurementStatus(String state) => switch (state) {
    'pending' => 'Queued',
    'running' => 'Calculating',
    'current' => 'Calculated',
    'validated' => 'Validated',
    'calculated_unvalidated' => 'Calculated · parity unverified',
    'stale' => 'Stale',
    'failed' => 'Failed',
    'unavailable' => 'Source unavailable',
    _ => 'Not calculated',
  };

  final Set<String> _expanded64Groups = {'Nearby population'};

  static const _locationGroups = <String, List<(String, String, String)>>{
    'Nearby population': [
      ('pop_500m', 'Population · 500 m', 'people'),
      ('pop_1000m', 'Population · 1 km', 'people'),
      ('pop_2000m', 'Population · 2 km', 'people'),
      ('pop_3000m', 'Population · 3 km', 'people'),
    ],
    'Population by age': [
      ('pop_age_0_14_500m', 'Age 0–14 · 500 m', 'people'),
      ('pop_age_15_24_500m', 'Age 15–24 · 500 m', 'people'),
      ('pop_age_25_34_500m', 'Age 25–34 · 500 m', 'people'),
      ('pop_age_35_49_500m', 'Age 35–49 · 500 m', 'people'),
      ('pop_age_50_64_500m', 'Age 50–64 · 500 m', 'people'),
      ('pop_age_65_plus_500m', 'Age 65+ · 500 m', 'people'),
      ('pop_age_0_14_1km', 'Age 0–14 · 1 km', 'people'),
      ('pop_age_15_24_1km', 'Age 15–24 · 1 km', 'people'),
      ('pop_age_25_34_1km', 'Age 25–34 · 1 km', 'people'),
      ('pop_age_35_49_1km', 'Age 35–49 · 1 km', 'people'),
      ('pop_age_50_64_1km', 'Age 50–64 · 1 km', 'people'),
      ('pop_age_65_plus_1km', 'Age 65+ · 1 km', 'people'),
    ],
    'Residential surroundings': [
      ('residential_building_count_500m', 'Residential building · 500 m', ''),
      ('residential_building_count_1000m', 'Residential building · 1 km', ''),
      (
        'residential_building_density_500m_km2',
        'Residential building density · 500 m',
        'buildings/km²',
      ),
      (
        'residential_building_density_1000m_km2',
        'Residential building density · 1 km',
        'buildings/km²',
      ),
      (
        'residential_footprint_coverage_500m_pct',
        'Residential footprint coverage · 500 m',
        '%',
      ),
      (
        'residential_footprint_coverage_1000m_pct',
        'Residential footprint coverage · 1 km',
        '%',
      ),
      (
        'residential_landuse_coverage_500m_pct',
        'Residential landuse coverage · 500 m',
        '%',
      ),
      (
        'residential_landuse_coverage_1000m_pct',
        'Residential landuse coverage · 1 km',
        '%',
      ),
    ],
    'Nearby demand generators': [
      ('office_pois_500m', 'Offices · 500 m', ''),
      ('office_pois_1000m', 'Offices · 1 km', ''),
      ('schools_count_500m', 'Schools · 500 m', ''),
      ('schools_count_1000m', 'Schools · 1 km', ''),
      (
        'universities_colleges_count_500m',
        'Universities and colleges · 500 m',
        '',
      ),
      (
        'universities_colleges_count_1000m',
        'Universities and colleges · 1 km',
        '',
      ),
      ('retail_pois_500m', 'Retail outlets · 500 m', ''),
      ('retail_pois_1000m', 'Retail outlets · 1 km', ''),
      ('malls_count_500m', 'Malls · 500 m', ''),
      ('malls_count_1000m', 'Malls · 1 km', ''),
      ('hospitals_count_500m', 'Hospitals · 500 m', ''),
      ('hospitals_count_1000m', 'Hospitals · 1 km', ''),
      ('supermarkets_count_500m', 'Supermarkets · 500 m', ''),
      ('supermarkets_count_1000m', 'Supermarkets · 1 km', ''),
    ],
    'Food and beverage competition': [
      ('fnb_competitors_500m', 'F&B competitors · 500 m', ''),
      ('fnb_competitors_1000m', 'F&B competitors · 1 km', ''),
      ('cafe_count_500m', 'Cafe · 500 m', ''),
      ('cafe_count_1000m', 'Cafe · 1 km', ''),
      ('restaurant_count_500m', 'Restaurant · 500 m', ''),
      ('restaurant_count_1000m', 'Restaurant · 1 km', ''),
      ('fast_food_count_500m', 'Fast food · 500 m', ''),
      ('fast_food_count_1000m', 'Fast food · 1 km', ''),
      (
        'bakery_dessert_beverage_count_500m',
        'Bakery, dessert and beverage outlets · 500 m',
        '',
      ),
      (
        'bakery_dessert_beverage_count_1000m',
        'Bakery, dessert and beverage outlets · 1 km',
        '',
      ),
    ],
    'Public transport': [
      ('nearest_transit_walk_m', 'Nearest transit stop (walking)', 'm'),
      ('transit_stops_500m_walk', 'Transit stops · 500 m (walking)', ''),
      ('transit_stops_1km_walk', 'Transit stops · 1 km (walking)', ''),
      (
        'weekday_transit_routes_1km_walk',
        'Weekday transit routes · 1 km (walking)',
        '',
      ),
      (
        'weekday_departures_500m_walk_am',
        'Weekday morning departures · 500 m (walking, AM)',
        '',
      ),
    ],
    'Road and network accessibility': [
      ('nearest_major_road_m', 'Nearest major road', 'm'),
      (
        'road_intersection_density_500m_km2',
        'Road intersection density · 500 m',
        'intersections/km²',
      ),
      (
        'road_length_density_500m_km_km2',
        'Road length density · 500 m',
        'km/km²',
      ),
      (
        'osm_walkway_length_density_500m_km_km2',
        'Walkway length density · 500 m',
        'km/km²',
      ),
      (
        'road_length_density_1km_km_km2',
        'Road length density · 1 km',
        'km/km²',
      ),
      (
        'walk_isochrone_area_10min_km2',
        'Walkable catchment area · 10 min',
        'km²',
      ),
      (
        'worldpop_walk_reachable_10min',
        'Population reachable on foot · 10 min',
        'people',
      ),
      (
        'drive_isochrone_area_10min_km2',
        'Drivable catchment area · 10 min',
        'km²',
      ),
    ],
    'Parking access': [
      ('parking_facilities_500m', 'Parking facilities · 500 m', ''),
      ('parking_facilities_1km', 'Parking facilities · 1 km', ''),
      ('nearest_parking_distance_m', 'Nearest parking', 'm'),
    ],
  };

  Component _expanded64Evidence(VerificationDetail detail) {
    final research =
        _liveLocation ?? detail.locationAnalysis.partB.researchAssociation;
    final active = _locationActive(research);
    if (active && _locationError == null) _scheduleLocationRefresh();
    final observed = research.calculatedFeatures;
    final coverageKnown = research.featureCount == 64;
    const groups = _locationGroups;
    const categoryKeys = [
      'population',
      'age',
      'residential',
      'demand',
      'competition',
      'transit',
      'network',
      'parking',
    ];
    final categories = Map.fromIterables(groups.keys, categoryKeys);
    return div(classes: 'sw64-evidence', [
      div(classes: 'sw64-head', [
        div([
          h3([Component.text('64 location features')]),
          p(classes: 'small muted', [
            Component.text(
              'Measured from this listing\'s own coordinates at review time — '
              'never carried over from the historical research dataset. '
              'This evidence does not determine approval.',
            ),
          ]),
        ]),
        span(classes: 'sw64-count', [
          Component.text(
            coverageKnown
                ? '$observed / 64 calculated · ${research.availableFeatures ?? 0} / 64 validated'
                : 'Coverage unavailable',
          ),
        ]),
      ]),
      p(classes: 'small muted', [
        Component.text(_measurementStatus(research.calculationStatus)),
      ]),
      if (!_canAnalyse(research))
        p(classes: 'small muted', [
          Component.text(
            research.addressMissingFields.isEmpty
                ? 'Save a valid property location before calculating.'
                : 'Save the ${research.addressMissingFields.join(', ')} on the '
                      'listing before calculating — a location is never '
                      'inferred from a partial address.',
          ),
        ]),
      if (!research.hasCoordinates && research.addressGeocodable)
        p(classes: 'small muted', [
          Component.text(
            'No coordinates are stored yet. Running the analysis resolves them '
            'from the saved address first, then measures the result.',
          ),
        ]),
      if (research.hasCoordinates)
        p(classes: 'small muted', [
          Component.text(_addressVerdict(research.addressValidationStatus)),
        ]),
      if (_locationError != null)
        p(classes: 'small muted', [Component.text(_locationError!)]),
      if (_locationError == null && _locationNotice != null)
        p(classes: 'small muted', [Component.text(_locationNotice!)]),
      button(
        attributes: {
          'type': 'button',
          if (active || _locationRequest || !_canAnalyse(research))
            'disabled': '',
        },
        events: events(onClick: () => unawaited(_runAnalysis())),
        [
          Component.text(
            active
                ? 'Analysis in progress'
                : research.calculationStatus == 'failed'
                ? 'Retry analysis'
                : research.calculatedFeatures == 0
                ? 'Run location analysis'
                : 'Run missing measurements',
          ),
        ],
      ),
      button(
        attributes: {
          'type': 'button',
          if (active || _locationRequest || !_canAnalyse(research))
            'disabled': '',
        },
        events: events(onClick: () => unawaited(_runAnalysis(full: true))),
        [Component.text('Recalculate everything')],
      ),
      button(events: events(onClick: () => unawaited(_refreshLocation())), [
        Component.text('Refresh results'),
      ]),
      if (coverageKnown)
        div(
          classes: 'sw64-track',
          attributes: {
            'role': 'progressbar',
            'aria-label': 'Calculated location features',
            'aria-valuemin': '0',
            'aria-valuemax': '64',
            'aria-valuenow': '$observed',
          },
          [
            div(attributes: {'style': 'width:${observed * 100 / 64}%'}, []),
          ],
        ),
      if (!coverageKnown)
        p(classes: 'small muted', [
          Component.text(
            'Measurements could not be resolved. Missing coordinates or unavailable sources may prevent analysis.',
          ),
        ]),
      p(classes: 'small muted', [
        Component.text(
          'Zero is a measured value; unavailable and unvalidated inputs are never replaced with zero. '
          'Open a group to view values, units and available source details.',
        ),
      ]),
      for (final group in groups.entries) ...[
        button(
          classes: 'sw64-group',
          attributes: {
            'type': 'button',
            'aria-expanded': '${_expanded64Groups.contains(group.key)}',
          },
          events: events(
            onClick: () => setState(() {
              if (!_expanded64Groups.remove(group.key)) {
                _expanded64Groups.add(group.key);
              }
            }),
          ),
          [
            span([Component.text(group.key)]),
            span(classes: 'sw64-group-count', [
              Component.text(
                '${_measurementStatus(research.measurementCategories[categories[group.key]]?['status']?.toString() ?? '')} · '
                '${group.value.where((row) => research.featureValues.containsKey(row.$1)).length}/${group.value.length} '
                '${_expanded64Groups.contains(group.key) ? "−" : "+"}',
              ),
            ]),
          ],
        ),
        if (_expanded64Groups.contains(group.key))
          div(classes: 'sw64-rows', [
            if (research.measurementCategories[categories[group.key]]
                case final status?) ...[
              if (status['last_success_at'] case final String timestamp)
                p(classes: 'small muted', [
                  Component.text(
                    'Last successful calculation ${DateTime.tryParse(timestamp)?.toLocal() ?? timestamp}',
                  ),
                ]),
              if (status['reason'] case final String reason)
                p(classes: 'small muted', [Component.text(reason)]),
              if (status['status'] == 'failed' ||
                  status['status'] == 'unavailable' ||
                  ((status['calculated'] as int? ?? 0) < group.value.length &&
                      status['status'] == 'current'))
                button(
                  attributes: {
                    'type': 'button',
                    if (active || _locationRequest || !_canAnalyse(research))
                      'disabled': '',
                  },
                  events: events(
                    onClick: () =>
                        unawaited(_queueLocation(categories[group.key])),
                  ),
                  [Component.text('Retry category')],
                ),
            ],
            for (final row in group.value) _expanded64Row(research, row),
          ]),
      ],
    ]);
  }

  Component _expanded64Row(
    LocationResearchAssociation research,
    (String, String, String) row,
  ) {
    final (key, label, unit) = row;
    final value = research.featureValues[key];
    final source = research.featureSources[key];
    final method = research.featureMethods[key];
    final status = _measurementStatus(research.featureStates[key] ?? '');
    final imputable = research.imputableFeatures.contains(key);
    final shown = value == null
        ? status
        : '${value == value.roundToDouble() ? value.toStringAsFixed(0) : value.toStringAsFixed(2)}${unit.isEmpty ? '' : ' $unit'}';
    return div(classes: 'sw64-row', [
      div([
        span([Component.text(label)]),
        if (source != null && source.isNotEmpty && value != null)
          p(classes: 'sw64-source', [Component.text(source)]),
        if (value != null && method != null)
          p(classes: 'sw64-source', [Component.text(method)]),
        if (value != null) p(classes: 'sw64-source', [Component.text(status)]),
        if (value == null && imputable)
          p(classes: 'sw64-source', [
            Component.text('Model may impute; not measured'),
          ]),
      ]),
      strong(classes: value == null ? 'sw64-missing' : 'sw64-value', [
        Component.text(shown),
      ]),
    ]);
  }

  Component _researchAssociationPanel(LocationResearchAssociation research) {
    if (!research.available) {
      return Component.fragment([
        _unavailableNote(research.unavailableReason),
        p(classes: 'vd-source', [
          Component.text(
            'No score was generated. Missing features are never substituted '
            'with another property\'s values or with zeros.',
          ),
        ]),
      ]);
    }
    final labels = {
      for (final entries in _locationGroups.values)
        for (final (key, label, _) in entries) key: label,
    };
    final contributions =
        (research.explanation['contributions'] as Map? ?? const {}).entries
            .where((entry) => entry.value is num)
            .toList()
          ..sort(
            (left, right) =>
                (right.value as num).abs().compareTo((left.value as num).abs()),
          );
    return div(classes: 'stack', [
      div(classes: 'vd-info', [
        _infoRow(
          'PU location suitability · association score',
          _num(research.score),
        ),
        h4([Component.text('Explainable AI')]),
        if (contributions.isEmpty)
          _unavailableNote(
            research.explanationUnavailableReason ??
                'No persisted SHAP explanation is available.',
          ),
        for (final feature in contributions.take(8))
          _infoRow(
            labels[feature.key] ?? feature.key.toString().replaceAll('_', ' '),
            (feature.value as num).toStringAsFixed(4),
          ),

        if ((research.label ?? '').trim().isNotEmpty)
          _infoRow('Model band', research.label!),
        _infoRow(
          'Model features available',
          research.modelAvailableFeatures != null &&
                  research.modelFeatureCount != null
              ? '${research.modelAvailableFeatures} of ${research.modelFeatureCount}'
              : 'Coverage unavailable',
        ),
        if ((research.modelVersion ?? '').trim().isNotEmpty)
          _infoRow('Model version', research.modelVersion!),
      ]),
      if (research.modelFeatureCount == research.featureCount &&
          research.missingFeatures.isNotEmpty)
        div(classes: 'vd-note vd-note--warning', [
          span(classes: 'vd-note__symbol', [Component.text('!')]),
          Component.text(
            '${research.missingFeatures.length} model feature(s) were not '
            'available for this listing: '
            '${research.missingFeatures.join(', ')}.',
          ),
        ]),
      p(classes: 'vd-source', [
        Component.text(
          'What this score means: ${research.scoreMeaning.isEmpty ? 'a '
                    'statistical association with positive examples in the research '
                    'dataset' : research.scoreMeaning}. It is not a probability of '
          'business success.',
        ),
      ]),
    ]);
  }

  /// Part C: data confidence — what is available, what is missing, what is
  /// outdated, and which licences apply.
  Component _analysisReliability(VerificationDetail detail) {
    final partC = detail.locationAnalysis.partC;
    return div(classes: 'stack', [
      h4(classes: 'vd-group-title', [Component.text('Data reliability')]),
      p(classes: 'small muted', [
        Component.text(
          '${partC.familiesAvailable} of ${partC.familiesTotal} measurement '
          'families have data for this listing. A missing measurement is '
          'reported as unavailable — it is never filled in with a zero.',
        ),
      ]),
      if (partC.missing.isNotEmpty)
        div(classes: 'vd-info', [
          for (final gap in partC.missing)
            div(classes: 'vd-row', [
              span(classes: 'vd-row__label', [
                Component.text(_familyLabel(gap.family)),
              ]),
              strong(classes: 'vd-row__value', [
                Component.text(_orNotProvided(gap.reason)),
              ]),
            ]),
        ]),
      for (final gap in partC.outdated)
        div(classes: 'vd-note vd-note--warning', [
          span(classes: 'vd-note__symbol', [Component.text('!')]),
          Component.text(
            '${_familyLabel(gap.family)} is ${gap.status ?? 'outdated'}'
            '${gap.detail == null || gap.detail!.isEmpty ? '' : ': ${gap.detail}'}',
          ),
        ]),
      if (partC.licences.isNotEmpty)
        p(classes: 'vd-source', [
          Component.text(
            'Sources: ${partC.licences.map((licence) => licence.licence == null || licence.licence!.isEmpty ? licence.source : '${licence.source} (${licence.licence})').join(' · ')}',
          ),
        ]),
      for (final note in partC.resolutionNotes)
        p(classes: 'vd-notes', [Component.text(note)]),
    ]);
  }

  /// Recommendation (decision support). The policy rows state explicitly
  /// that every status stays an administrator decision.
  Component _analysisRecommendation(VerificationDetail detail) {
    final recommendation = detail.locationAnalysis.recommendation;
    if (recommendation.text.isEmpty) return Component.fragment([]);
    return div(classes: 'stack', [
      h4(classes: 'vd-group-title', [
        Component.text('Automated summary for the reviewer'),
      ]),
      p(classes: 'body', [Component.text(recommendation.text)]),
      if (recommendation.suggestedFocus.isNotEmpty)
        div(classes: 'stack', [
          for (final item in recommendation.suggestedFocus)
            p(classes: 'small muted', [Component.text('• $item')]),
        ]),
      div(classes: 'vd-info', [
        for (final policy in recommendation.policySeparation)
          div(classes: 'vd-row', [
            span(classes: 'vd-row__label', [
              Component.text(_policyLabel(policy.domain)),
            ]),
            strong(classes: 'vd-row__value', [Component.text(policy.note)]),
          ]),
      ]),
    ]);
  }

  Component _unavailableNote(String? reason) {
    return div(classes: 'vd-note vd-note--warning', [
      span(classes: 'vd-note__symbol', [Component.text('!')]),
      Component.text(
        'Not available — ${_orNotProvided(reason)}. '
        'The figure is reported as unavailable, not as zero.',
      ),
    ]);
  }

  static String _familyLabel(String family) => switch (family) {
    'population' => 'Population',
    'socioeconomic' => 'Income context',
    'fnb_environment' => 'F&B surroundings',
    'accessibility' => 'Accessibility',
    'research_association' => 'AI research assessment',
    'feature snapshot' => 'The feature snapshot',
    final other =>
      other.startsWith('measurement: ')
          ? 'The ${other.substring('measurement: '.length).replaceAll('_', ' ')} measurement'
          : other.replaceAll('_', ' '),
  };

  static String _policyLabel(String domain) => switch (domain) {
    'listing_accuracy' => 'Listing accuracy',
    'ownership' => 'Ownership',
    'location_suitability' => 'Location suitability',
    'publication_eligibility' => 'Publication eligibility',
    final other => other.replaceAll('_', ' '),
  };

  // --- Review sidebar (OUTSIDE the tabs) -----------------------------------------

  Future<void> _finalDecision(String action) async {
    if (_decisionBusy) return;
    final detail = component.detail;
    final token = detail.finalReview['token'];
    if (token is! String) return;
    final notifier = context.read(adminNotifierProvider.notifier);
    setState(() => _decisionBusy = true);
    try {
      await notifier.finalDecision('${detail.property.propertyId}', {
        'action': action,
        'token': token,
        'reviewed': _checks.toList(),
        if (action == 'reject' || action == 'information') ...{
          'component': _affectedComponent,
          'reason': _note.trim(),
        },
      });
    } finally {
      if (mounted) setState(() => _decisionBusy = false);
    }
  }

  Component _reviewSidebar(VerificationDetail detail) {
    final review = detail.finalReview;
    final blockers =
        (review['blockers'] as List?)?.whereType<String>() ?? const <String>[];
    final enabled = !_decisionBusy && review['token'] is String;
    final published = review['published'] == true;
    final approved = review['approved'] == true;
    final ready = blockers.isEmpty && _checks.length == 3;
    return aside(classes: 'card vd-side', [
      div(classes: 'vd-side__top', [
        h3([Component.text('Property decision')]),
      ]),
      div(classes: 'vd-side__body', [
        if (!approved) ...[
          for (final (id, tab, title) in const [
            ('property', 'overview', 'Property information reviewed'),
            ('ownership', 'ownership', 'Ownership evidence reviewed'),
            ('panorama', 'panorama', '360-degree panorama reviewed'),
          ])
            label(classes: 'vd-check', [
              input(
                type: InputType.checkbox,
                checked: _checks.contains(id),
                disabled:
                    !enabled ||
                    _tab != tab ||
                    (id == 'panorama' && !_panoramaReady),
                events: events(
                  onClick: () => setState(() {
                    if (!_checks.add(id)) _checks.remove(id);
                  }),
                ),
              ),
              span([Component.text(title)]),
            ]),
          for (final blocker in blockers)
            p(classes: 'small muted', [Component.text(blocker)]),
          ActionButton(
            'Approve & Publish Property',
            onClick: enabled && ready
                ? () => unawaited(_finalDecision('approve'))
                : null,
          ),
        ],
        if (approved || published)
          ActionButton(
            published ? 'Unpublish Property' : 'Publish Property',
            onClick: enabled && (published || blockers.isEmpty)
                ? () => unawaited(
                    _finalDecision(published ? 'unpublish' : 'publish'),
                  )
                : null,
          ),
        ActionButton(
          'Reject Property',
          variant: 'secondary',
          onClick: enabled
              ? () => setState(() => _decisionForm = 'reject')
              : null,
        ),
        ActionButton(
          'Request Additional Information',
          variant: 'secondary',
          onClick: enabled
              ? () => setState(() => _decisionForm = 'information')
              : null,
        ),
        if (_decisionForm != null) ...[
          label([
            Component.text('Affected evidence'),
            select(
              events: events<List<String>>(
                onChange: (value) {
                  if (value.isNotEmpty) {
                    setState(() => _affectedComponent = value.first);
                  }
                },
              ),
              [
                for (final (id, name) in const [
                  ('property', 'Property information'),
                  ('ownership', 'Ownership evidence'),
                  ('inspection', 'Agent inspection'),
                  ('panorama', '360-degree panorama'),
                ])
                  option(
                    value: id,
                    attributes: id == _affectedComponent
                        ? {'selected': ''}
                        : {},
                    [Component.text(name)],
                  ),
              ],
            ),
          ]),
          label([
            Component.text('Reason'),
            textarea(
              events: events<String>(
                onInput: (value) => setState(() => _note = value),
              ),
              [],
            ),
          ]),
          ActionButton(
            'Record decision',
            onClick: enabled && _note.trim().isNotEmpty
                ? () => unawaited(_finalDecision(_decisionForm!))
                : null,
          ),
          ActionButton(
            'Cancel',
            variant: 'secondary',
            onClick: _decisionBusy
                ? null
                : () => setState(() {
                    _decisionForm = null;
                    _note = '';
                  }),
          ),
        ],
      ]),
      _activity(detail),
    ]);
  }

  Component _documents(VerificationDetail detail) {
    final documents = detail.documents;
    return div(classes: 'stack', [
      h4(classes: 'vd-group-title', [Component.text('Evidence documents')]),
      if (documents.isEmpty)
        p(classes: 'small muted', [
          Component.text(
            'No ownership or listing documents attached. Submitters upload '
            'deeds, letters and photos from their workspace.',
          ),
        ])
      else
        div(classes: 'stack', [for (final doc in documents) _documentRow(doc)]),
      if (_downloadError != null)
        p(classes: 'field__error', [Component.text(_downloadError!)]),
    ]);
  }

  Component _documentRow(VerificationDocument doc) {
    final busy = _busyDocs.contains(doc.documentId);
    final dimension = doc.verificationType?.label ?? 'General';
    return div(classes: 'vd-doc', [
      span([const Icon('description', size: 'sm')]),
      div(classes: 'grow', [
        strong([Component.text(doc.originalFilename)]),
        p(classes: 'small muted', [
          Component.text(
            '$dimension · ${doc.documentType} · ${_fmtSize(doc.fileSize)}'
            '${doc.uploadedAt == null ? '' : ' · ${_fmtDate(doc.uploadedAt)}'}',
          ),
        ]),
      ]),
      if (!doc.isActive)
        const Pill('Superseded', tone: 'neutral')
      else
        ActionButton(
          busy ? 'Fetching…' : 'Download',
          onClick: busy ? null : () => unawaited(_download(doc)),
          variant: 'secondary',
          icon: 'download',
        ),
    ]);
  }

  Component _activity(VerificationDetail detail) {
    final recentEvents = detail.history.reversed.take(8).toList();
    return div(classes: 'vd-activity', [
      if (component.showPanorama)
        button(
          classes: 'vd-history-toggle',
          attributes: {
            'type': 'button',
            'aria-expanded': '$_activityExpanded',
            'aria-controls': 'vd-review-history',
          },
          events: events(
            onClick: () =>
                setState(() => _activityExpanded = !_activityExpanded),
          ),
          [
            Component.text('Review activity (${recentEvents.length} recent)'),
            Icon(_activityExpanded ? 'expand_less' : 'expand_more', size: 'sm'),
          ],
        )
      else
        h4(classes: 'vd-group-title', [Component.text('Review activity')]),
      div(
        id: 'vd-review-history',
        attributes: {
          if (component.showPanorama && !_activityExpanded) 'hidden': '',
        },
        [
          if (recentEvents.isEmpty)
            p(classes: 'small muted', [
              Component.text(
                'No events yet — submissions, decisions and evidence uploads appear here.',
              ),
            ])
          else
            div(classes: 'stack', [
              for (final event in recentEvents) _eventRow(event),
            ]),
        ],
      ),
    ]);
  }

  Component _eventRow(VerificationReviewEvent event) {
    final decision =
        (event.previousStatus ?? '—') != (event.newStatus ?? '—') &&
        event.newStatus != null;
    return div(classes: 'vd-event', [
      div(classes: 'grow', [
        strong([Component.text(event.label)]),
        p(classes: 'small muted', [
          Component.text(
            [
              if (event.verificationType != null) event.verificationType!.label,
              if (event.createdAt != null) _fmtDate(event.createdAt),
              if (decision)
                '${event.previousStatus?.replaceAll('_', ' ')} → '
                    '${event.newStatus!.replaceAll('_', ' ')}',
              if (event.adminUserId != null) 'by ${event.adminUserId}',
            ].join(' · '),
          ),
        ]),
        if (event.reason != null && event.reason!.isNotEmpty)
          p(classes: 'vd-event__reason', [Component.text(event.reason!)]),
      ]),
    ]);
  }

  // --- Helpers -----------------------------------------------------------------

  /// A minimal [CommercialProperty] adapter so the existing first-party
  /// Leaflet map renders for this listing (no coordinates → the map's own
  /// labelled empty state).
  CommercialProperty _mapProperty(VerificationProperty property) =>
      CommercialProperty(
        id: '${property.propertyId}',
        title: property.displayName,
        address: property.address ?? '',
        city: property.city ?? '',
        state: property.state ?? '',
        postcode: property.postcode ?? '',
        rentalRm: property.monthlyRent ?? 0,
        sizeSqft: property.builtUpAreaSqft ?? 0,
        latitude: property.latitude ?? 0,
        longitude: property.longitude ?? 0,
        propertyType: property.propertyType ?? '',
        verification: VerificationStatus.pending,
        suitabilityScore: 0,
        ownerId: property.userId ?? '',
        hasTour: false,
      );

  static String _parkingLabel(bool? hasParking) => switch (hasParking) {
    true => 'Claimed available',
    false => 'Declared unavailable',
    null => 'Not provided',
  };

  static String _fnbLabel(bool? isFnbSuitable) => switch (isFnbSuitable) {
    true => 'Self-declared suitable',
    false => 'Declared unsuitable',
    null => 'Not provided',
  };

  /// The method note for a count metric, surfacing the backend's own status
  /// flag when the value could not be computed cleanly.
  static String _countNote(
    VerificationGeoFeatures? geo,
    String key,
    String fallback,
  ) {
    if (geo == null) return 'Not calculated for this property';
    final status = switch (key) {
      'competitor_status' => geo.competitorStatus,
      'demand_status' => geo.demandStatus,
      'accessibility_status' => geo.accessibilityStatus,
      _ => null,
    };
    if (status == null || status == 'ok') return fallback;
    return 'Status: ${status.replaceAll('_', ' ')}';
  }

  static String _populationNote(VerificationPopulation research) {
    final source = research.source;
    final year = research.sourceYear;
    if (source == null || source.isEmpty) {
      return 'Research snapshot via verified subject link';
    }
    return 'Research snapshot · $source${year == null || year.isEmpty ? '' : ' $year'}';
  }

  Component _metric(
    String label,
    num? value,
    String note, {
    String prefix = '',
    String suffix = '',
  }) {
    final missing = value == null;
    final text = missing
        ? 'Not calculated'
        : '$prefix${value == value.roundToDouble() ? value.toStringAsFixed(0) : value.toStringAsFixed(2)}$suffix';
    return div(classes: 'vd-metric${missing ? ' vd-metric--missing' : ''}', [
      span(classes: 'vd-metric__label', [Component.text(label)]),
      strong(classes: 'vd-metric__value', [Component.text(text)]),
      span(classes: 'vd-metric__note', [Component.text(note)]),
    ]);
  }

  Component _infoRow(String label, String value, {String? fallback}) =>
      div(classes: 'vd-row', [
        span(classes: 'vd-row__label', [Component.text(label)]),
        strong(classes: 'vd-row__value', [
          Component.text(
            value.trim().isEmpty ? (fallback ?? 'Not provided') : value,
          ),
        ]),
      ]);

  Component _statusPill(PropertyVerificationStatus status) => Pill(
    status.label,
    tone: switch (status) {
      PropertyVerificationStatus.verified => 'success',
      PropertyVerificationStatus.pending => 'warning',
      PropertyVerificationStatus.underReview => 'action',
      PropertyVerificationStatus.rejected => 'danger',
      PropertyVerificationStatus.informationRequested => 'warning',
      PropertyVerificationStatus.notSubmitted => 'neutral',
    },
  );

  static String _orNotProvided(String? value) {
    final trimmed = value?.trim() ?? '';
    return trimmed.isEmpty ? 'Not provided' : trimmed;
  }

  static String _orNotCalculated(num? value) =>
      value == null ? 'Not calculated' : _num(value);

  static String _num(num? value) {
    if (value == null) return '—';
    return value == value.roundToDouble()
        ? value.toStringAsFixed(0)
        : value.toStringAsFixed(5);
  }

  static String _fullAddress(VerificationProperty property) {
    final parts =
        [property.address, property.city, property.state, property.postcode]
            .whereType<String>()
            .map((part) => part.trim())
            .where((part) => part.isNotEmpty);
    return parts.isEmpty ? 'No address provided' : parts.join(', ');
  }

  static String _fmtSize(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '$bytes B';
  }

  static String _fmtDate(String? iso) {
    if (iso == null || iso.isEmpty) return '—';
    final flat = iso.replaceFirst('T', ' ');
    return flat.length > 16 ? flat.substring(0, 16) : flat;
  }

  Future<void> _download(VerificationDocument doc) async {
    setState(() {
      _busyDocs.add(doc.documentId);
      _downloadError = null;
    });
    try {
      final bytes = await AppLocator.propertyVerificationRepo.downloadDocument(
        doc.documentId,
      );
      if (!mounted) return;
      _saveBytes(Uint8List.fromList(bytes), doc.originalFilename, doc.mimeType);
    } on StateError catch (error) {
      if (mounted) {
        setState(() {
          _downloadError = error.message.isNotEmpty
              ? error.message
              : 'The document could not be downloaded.';
        });
      }
    } on Object {
      if (mounted) {
        setState(() {
          _downloadError = 'The document could not be downloaded.';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _busyDocs.remove(doc.documentId);
        });
      }
    }
  }

  /// Hands the received bytes to the browser's download flow. Runs on the
  /// client only — the component is `@client` and this is called from a click
  /// handler.
  void _saveBytes(Uint8List bytes, String filename, String mime) {
    final blob = web.Blob([bytes.toJS].toJS, web.BlobPropertyBag(type: mime));
    final url = web.URL.createObjectURL(blob);
    web.HTMLAnchorElement()
      ..href = url
      ..download = filename
      ..click();
    web.URL.revokeObjectURL(url);
  }
}
