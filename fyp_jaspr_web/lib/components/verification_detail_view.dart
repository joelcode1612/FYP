import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';
import 'package:universal_web/web.dart' as web;

import '../data/app_locator.dart';
import 'property_leaflet_map.dart';
import 'ui.dart';

/// The review workspace's right-hand content: everything the backend's
/// `/staff/properties/{id}/verification` detail returns, rendered once and
/// reused by both surfaces that load it — the review split's detail column
/// (`/admin/listings`) and the standalone `/admin/listing-detail` page.
///
/// Layout (converted from the `sitewise_admin_two_tab_review.html`
/// prototype, themed with the Admin Blue Edition tokens): a property hero,
/// EXACTLY TWO content tabs — Property Overview and Location Intelligence —
/// and a decision sidebar that sits OUTSIDE the tabs. Decisions dispatch
/// through [adminNotifierProvider] so the busy flag, the success notice and
/// the automatic queue/detail refresh stay in the shared controller.
/// Documents stream through the authenticated download endpoint
/// (`AppLocator.propertyVerificationRepo`) — never a public URL. Display
/// photos render from their permanent bucket URLs.
/// Param-less shell so the `@client` codegen accepts this component (it only
/// supports primitive constructor params); the detail arrives through
/// [adminNotifierProvider] and renders via [_VerificationDetailBody].
@client
class VerificationDetailView extends StatefulComponent {
  const VerificationDetailView({super.key});

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
    );
  }
}

/// The rendering body. Not `@client` — it is instantiated by the shell above
/// with the already-loaded [VerificationDetail]; the [ValueKey] resets its
/// tab/checklist/note-form state whenever a different property is opened.
class _VerificationDetailBody extends StatefulComponent {
  final VerificationDetail detail;

  const _VerificationDetailBody({super.key, required this.detail});

  @override
  State<_VerificationDetailBody> createState() =>
      _VerificationDetailBodyState();
}

class _VerificationDetailBodyState extends State<_VerificationDetailBody> {
  /// The selected content tab — `'overview'` or `'intelligence'`. Held in
  /// state so normal state refreshes (busy flags, notices, detail reloads)
  /// never bounce the admin back to the first tab.
  String _tab = 'overview';

  /// The reviewer confirmations of the listing checklist (under review).
  final Set<String> _checks = {};

  /// The dimension whose reject / request-information form is open, if any.
  VerificationDimension? _formFor;

  /// `'reject'` or `'information'` — the two note-taking decisions.
  String _formMode = 'reject';
  String _note = '';
  final Set<String> _busyDocs = {};
  String? _downloadError;

  /// DOM-level keyboard handler for the tablist (roving tabindex, per the
  /// prototype's WAI-ARIA tabs pattern). Jaspr's `events()` helper exposes
  /// only click/input/change, so the keydown listener attaches to the
  /// rendered tablist element directly and detaches on dispose.
  web.EventListener? _tabKeyListener;
  web.Element? _tabListEl;

  static const _tabIds = ['overview', 'intelligence'];

  @override
  void initState() {
    super.initState();
    Future.microtask(_attachTabKeys);
  }

  @override
  void dispose() {
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
    final verification = detail.verification;
    final notice = context.watch(
      adminNotifierProvider.select((state) => state.reviewNotice),
    );
    final error = context.watch(
      adminNotifierProvider.select((state) => state.error),
    );

    return div(classes: 'vd stack', [
      if (notice != null)
        div(classes: 'notice notice-info row', [
          span(classes: 'grow', [Component.text(notice)]),
          ActionButton(
            'Dismiss',
            variant: 'ghost',
            onClick: () =>
                context.read(adminNotifierProvider.notifier).clearReviewNotice(),
          ),
        ]),
      if (error != null)
        div(classes: 'notice notice-danger', [Component.text(error)]),
      div(classes: 'vd-layout', [
        div(classes: 'vd-main stack', [
          _hero(detail),
          _tabShell(),
          if (_tab == 'overview')
            _overviewPanel(detail)
          else
            _intelligencePanel(detail),
        ]),
        _reviewSidebar(detail, verification),
      ]),
    ]);
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
            'Entrepreneur submission · Property #${property.propertyId}',
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
          _statusPill(verification.statuses.statusOf(VerificationDimension.listing)),
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

  Component _tabShell() {
    return div(
      classes: 'vd-tabs',
      attributes: {'role': 'tablist', 'aria-label': 'Property review detail'},
      [
        _tabButton('overview', 'Property Overview'),
        _tabButton('intelligence', 'Location Intelligence'),
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
      events: events(onClick: () => setState(() => _tab = id)),
      [Component.text(label)],
    );
  }

  // --- Tab 1: Property Overview -------------------------------------------------

  Component _overviewPanel(VerificationDetail detail) {
    final property = detail.property;
    return section(
      id: 'vd-panel-overview',
      classes: 'card card-pad vd-panel',
      attributes: {
        'role': 'tabpanel',
        'aria-labelledby': 'vd-tab-overview',
      },
      [
        div(classes: 'vd-section-head', [
          div(classes: 'stack', [
            h3([Component.text('Property overview')]),
            p(classes: 'small muted', [
              Component.text(
                'Property-detail information submitted by the entrepreneur.',
              ),
            ]),
          ]),
          span(classes: 'chip', [Component.text('Owner-provided')]),
        ]),
        div(classes: 'vd-overview-grid', [
          _photos(detail),
          div(classes: 'stack', [
            h4(classes: 'vd-group-title', [
              Component.text('Listing information'),
            ]),
            div(classes: 'vd-info', [
              _infoRow('Property ID', '${property.propertyId}'),
              _infoRow('Property type', _orNotProvided(property.propertyType)),
              _infoRow('Floor level', _orNotProvided(property.floorLevel)),
              _infoRow(
                'Frontage',
                property.frontageFt == null
                    ? 'Not provided'
                    : '${_num(property.frontageFt)} ft · owner-entered',
              ),
              _infoRow('Parking', _parkingLabel(property.hasParking)),
              _infoRow('F&B suitability', _fnbLabel(property.isFnbSuitable)),
              _infoRow('Availability', _orNotProvided(property.availability)),
            ]),
          ]),
        ]),
        div(classes: 'vd-divider', []),
        h4(classes: 'vd-group-title', [Component.text('Address & property facts')]),
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
        p(
          classes: 'vd-description',
          [Component.text(_orNotProvided(property.description))],
        ),
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

  Component _intelligencePanel(VerificationDetail detail) {
    final property = detail.property;
    final geo = detail.geoFeatures;
    final research = detail.population;
    final calculated = geo != null;

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
            p(classes: 'small muted', [
              Component.text(
                'Evidence from SiteWise geospatial features when this '
                'property has been analysed.',
              ),
            ]),
          ]),
          Pill(
            calculated ? 'Calculated' : 'Not calculated',
            tone: calculated ? 'action' : 'neutral',
          ),
        ]),
        p(classes: 'vd-source', [
          Component.text(
            calculated
                ? 'fyp.property_geospatial_features · calculated '
                    '${_fmtDate(geo.calculatedAt)}'
                : 'fyp.property_geospatial_features · No matched record',
          ),
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
            _countNote(geo, 'competitor_status', 'Straight-line research radius'),
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
            _countNote(geo, 'accessibility_status', 'Backend-calculated index'),
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
            _infoRow('Population within 1 km', _orNotCalculated(research.pop1km)),
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
                if (research.sourceYear != null && research.sourceYear!.isNotEmpty)
                  '(${research.sourceYear})',
              ].join(' ').trim(),
              fallback: 'Not recorded',
            ),
            _infoRow(
              'Quality flag',
              _orNotProvided(research.qualityFlag),
            ),
          ]),
        ],
        h4(classes: 'vd-group-title', [
          Component.text('Nearby demand generators · within 1 km'),
        ]),
        _demandGenerators(detail),
        h4(classes: 'vd-group-title', [Component.text('Surrounding amenities')]),
        _amenities(detail.amenities),
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

  // --- Review sidebar (OUTSIDE the tabs) -----------------------------------------

  Component _reviewSidebar(
    VerificationDetail detail,
    PropertyVerification verification,
  ) {
    final busy = context.watch(
      adminNotifierProvider.select((state) => state.busyAction),
    );
    final listingStatus =
        verification.statuses.statusOf(VerificationDimension.listing);
    final ownershipStatus =
        verification.statuses.statusOf(VerificationDimension.ownership);
    final hasOwnershipEvidence = detail.documents.any(
      (doc) => doc.isActive && doc.verificationType == VerificationDimension.ownership,
    );

    return aside(classes: 'card vd-side', [
      div(classes: 'vd-side__top', [
        span(classes: 'eyebrow', [Component.text('Decision workspace')]),
        h3([Component.text('Review listing details')]),
        p(classes: 'small muted', [
          Component.text(
            'Evaluate the submitted listing information. Ownership '
            'validation remains a separate, independent requirement.',
          ),
        ]),
        div(classes: 'vd-steps', [
          span(classes: 'vd-step is-active', []),
          span(
            classes:
                'vd-step${listingStatus != PropertyVerificationStatus.pending ? ' is-active' : ''}',
            [],
          ),
          span(
            classes:
                'vd-step${_isTerminal(listingStatus) ? ' is-active' : ''}',
            [],
          ),
        ]),
      ]),
      div(classes: 'vd-side__body', [
        _dimensionPanel(
          dimension: VerificationDimension.listing,
          status: listingStatus,
          busy: busy,
        ),
      ]),
      div(classes: 'vd-side__body vd-side__body--bordered', [
        _dimensionPanel(
          dimension: VerificationDimension.ownership,
          status: ownershipStatus,
          busy: busy,
          hasEvidence: hasOwnershipEvidence,
        ),
        _documents(detail),
      ]),
      div(classes: 'vd-publication', [
        strong([
          Component.text(
            verification.publicationEligible
                ? 'Publication-eligible'
                : 'Publication blocked',
          ),
        ]),
        p([
          Component.text(
            verification.publicationEligible
                ? 'Both dimensions are verified. Publishing remains a '
                    'separate administrative action.'
                : 'Listing review and ownership verification are not both '
                    'complete. Do not publish the property.',
          ),
        ]),
      ]),
      _activity(detail),
    ]);
  }

  bool _isTerminal(PropertyVerificationStatus status) =>
      status == PropertyVerificationStatus.verified ||
      status == PropertyVerificationStatus.rejected ||
      status == PropertyVerificationStatus.informationRequested;

  /// One dimension's decision panel: status line, guidance, (for listing)
  /// the reviewer checklist, and the action bar. Both dimensions render here
  /// in the sidebar — never inside the content tabs.
  Component _dimensionPanel({
    required VerificationDimension dimension,
    required PropertyVerificationStatus status,
    required String? busy,
    bool hasEvidence = true,
  }) {
    final propertyId = '${component.detail.verification.propertyId}';
    final listing = dimension == VerificationDimension.listing;
    final note = _latestReason(
      dimension,
      status,
      component.detail.history,
    );
    final checksReady =
        listing && _checks.length == _checkItems.length && _checkItems.isNotEmpty;

    final actions = switch (status) {
      // Nothing is actionable while a dimension has not been submitted; the
      // guidance line below explains why.
      PropertyVerificationStatus.notSubmitted => <Component>[],
      PropertyVerificationStatus.pending => <Component>[
          ActionButton(
            busy != null ? 'Starting…' : 'Start review',
            onClick: busy != null ? null : () => _dispatch('start', dimension, propertyId),
            icon: 'visibility',
          ),
        ],
      PropertyVerificationStatus.underReview => <Component>[
          if (listing) _checklist(),
          ActionButton(
            busy != null ? 'Approving…' : 'Approve',
            onClick: busy != null || (listing && !checksReady)
                ? null
                : () => _dispatch('approve', dimension, propertyId),
            icon: 'check',
          ),
          div(classes: 'vd-action-row', [
            ActionButton(
              'Request corrections',
              variant: 'secondary',
              onClick: busy != null
                  ? null
                  : () => setState(() {
                      _formFor = dimension;
                      _formMode = 'information';
                      _note = '';
                    }),
            ),
            ActionButton(
              'Reject',
              variant: 'secondary',
              onClick: busy != null
                  ? null
                  : () => setState(() {
                      _formFor = dimension;
                      _formMode = 'reject';
                      _note = '';
                    }),
            ),
          ]),
        ],
      _ => <Component>[],
    };

    // Ownership may only be APPROVED with evidence on file — approving
    // listing facts never verifies ownership, and this surface must not let
    // a click imply it did. Reject / request-information stay available.
    final ownershipBlocked =
        !listing &&
        status == PropertyVerificationStatus.underReview &&
        !hasEvidence;

    return div(classes: 'stack', [
      div(classes: 'vd-decision-line', [
        h4([Component.text(dimension.label)]),
        _statusPill(status),
      ]),
      p(classes: 'small muted', [Component.text(_dimensionMessage(status, listing))]),
      if (ownershipBlocked)
        div(classes: 'vd-authority', [
          span(classes: 'vd-authority__icon', [Component.text('!')]),
          div([
            strong([Component.text('No authorization evidence')]),
            p([
              Component.text(
                'No ownership or agency document is on file. Approval stays '
                'unavailable — request the document or reject the claim.',
              ),
            ]),
          ]),
        ]),
      if (note != null) div(classes: 'owner-note', [Component.text(note)]),
      if (_formFor == dimension)
        _noteForm(dimension)
      else
        ...actions,
      if (listing && status == PropertyVerificationStatus.underReview)
        p(classes: 'small muted', [
          Component.text(
            'These checks are reviewer confirmations, not proof of ownership '
            'or a physical inspection.',
          ),
        ]),
    ]);
  }

  static const _checkItems = <(String, String)>[
    (
      'completeness',
      'Property information reviewed for completeness and consistency',
    ),
    (
      'address',
      'Address and coordinates reviewed against available evidence',
    ),
    (
      'media',
      'Photos, facilities and any unknowns are acknowledged',
    ),
  ];

  Component _checklist() {
    return div(classes: 'vd-checks', [
      for (final (id, checkLabel) in _checkItems)
        label(classes: 'vd-check', [
          input(
            type: InputType.checkbox,
            checked: _checks.contains(id),
            events: events(
              onClick: () => setState(() {
                _checks.contains(id) ? _checks.remove(id) : _checks.add(id);
              }),
            ),
          ),
          span([Component.text(checkLabel)]),
        ]),
    ]);
  }

  String _dimensionMessage(PropertyVerificationStatus status, bool listing) {
    final what = listing ? 'listing' : 'ownership dimension';
    return switch (status) {
      PropertyVerificationStatus.notSubmitted => listing
          ? 'No listing submission is recorded for this property yet.'
          : 'Ownership has not been submitted. It stays unverified until '
              'evidence exists and a submission arrives.',
      PropertyVerificationStatus.pending =>
        'Submitted and waiting. Start the review to record that this '
        '$what is being examined.',
      PropertyVerificationStatus.underReview => listing
          ? 'Confirm the checklist, then approve the listing details or '
              'request changes.'
          : 'Under review. Approval requires evidence on file.',
      PropertyVerificationStatus.verified => listing
          ? 'Listing information reviewed. Authorization remains a separate '
              'requirement and publication stays blocked until both are '
              'verified.'
          : 'Ownership verified on the strength of the submitted evidence.',
      PropertyVerificationStatus.rejected =>
        'Rejected. The submitter must correct and resubmit.',
      PropertyVerificationStatus.informationRequested =>
        'Information requested. The submitter must respond and resubmit.',
    };
  }

  void _dispatch(String kind, VerificationDimension dimension, String propertyId) {
    final notifier = context.read(adminNotifierProvider.notifier);
    switch (kind) {
      case 'start':
        unawaited(notifier.startDimensionReview(propertyId, dimension));
      case 'approve':
        unawaited(notifier.approveDimension(propertyId, dimension));
    }
  }

  Component _noteForm(VerificationDimension dimension) {
    final rejecting = _formMode == 'reject';
    final tooShort = rejecting && _note.trim().length < 8;
    final empty = _note.trim().isEmpty;
    final invalid = rejecting ? tooShort : empty;
    final notifier = context.read(adminNotifierProvider.notifier);
    final propertyId = '${component.detail.property.propertyId}';

    return div(classes: 'reject-form stack', [
      Field(
        labelText: rejecting
            ? 'Reason shown to the submitter'
            : 'What the submitter must provide',
        hint: rejecting ? 'Minimum 8 characters.' : 'Be specific and actionable.',
        child: textarea(
          [],
          attributes: {
            'rows': '3',
            'placeholder': rejecting
                ? 'Why is this being rejected?'
                : 'What evidence or correction is needed?',
            'aria-label': rejecting ? 'Rejection reason' : 'Information request',
          },
          // Rebuild on every keystroke so the confirm action's enabled state
          // tracks the note (an untracked mutation left the button stuck on
          // its stale disabled state).
          events: events<String>(onInput: (v) => setState(() => _note = v)),
        ),
      ),
      div(classes: 'vd-action-row', [
        ActionButton(
          rejecting ? 'Confirm reject' : 'Send request',
          onClick: invalid
              ? null
              : () {
                final note = _note.trim();
                unawaited(
                  (rejecting
                          ? notifier.rejectDimension(propertyId, dimension, note)
                          : notifier.requestInformation(
                              propertyId,
                              dimension,
                              note,
                            ))
                      .whenComplete(() {
                    if (mounted) {
                      setState(() {
                        _formFor = null;
                        _note = '';
                      });
                    }
                  }),
                );
              },
        ),
        ActionButton(
          'Cancel',
          variant: 'secondary',
          onClick: () => setState(() {
            _formFor = null;
            _note = '';
          }),
        ),
      ]),
      if (invalid)
        p(classes: 'field__error', [
          Component.text(
            rejecting
                ? 'Add at least 8 characters before rejecting.'
                : 'Describe what the submitter must provide.',
          ),
        ]),
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
        div(classes: 'stack', [
          for (final doc in documents) _documentRow(doc),
        ]),
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
    final events = detail.history.reversed.take(8).toList();
    return div(classes: 'vd-activity', [
      h4(classes: 'vd-group-title', [Component.text('Review activity')]),
      if (events.isEmpty)
        p(classes: 'small muted', [
          Component.text(
            'No events yet — submissions, decisions and evidence uploads '
            'appear here.',
          ),
        ])
      else
        div(classes: 'stack', [
          for (final event in events) _eventRow(event),
        ]),
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
  static String _countNote(VerificationGeoFeatures? geo, String key, String fallback) {
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
        strong(
          classes: 'vd-row__value',
          [Component.text(value.trim().isEmpty ? (fallback ?? 'Not provided') : value)],
        ),
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
    final parts = [
      property.address,
      property.city,
      property.state,
      property.postcode,
    ]
        .whereType<String>()
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty);
    return parts.isEmpty ? 'No address provided' : parts.join(', ');
  }

  /// The note the dimension is currently sitting on: the latest reject reason
  /// or information request, surfaced only while the dimension still holds
  /// that state — mirrors the backend's `_requested_corrections` rule.
  String? _latestReason(
    VerificationDimension dimension,
    PropertyVerificationStatus status,
    List<VerificationReviewEvent> history,
  ) {
    if (status != PropertyVerificationStatus.rejected &&
        status != PropertyVerificationStatus.informationRequested) {
      return null;
    }
    for (final event in history.reversed) {
      if (event.verificationType != dimension) continue;
      final isNote = event.action.endsWith('_rejected') ||
          event.action.endsWith('_information_requested');
      if (isNote && event.reason != null && event.reason!.isNotEmpty) {
        return event.reason;
      }
    }
    return null;
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
    final blob = web.Blob(
      [bytes.toJS].toJS,
      web.BlobPropertyBag(type: mime),
    );
    final url = web.URL.createObjectURL(blob);
    web.HTMLAnchorElement()
      ..href = url
      ..download = filename
      ..click();
    web.URL.revokeObjectURL(url);
  }
}
