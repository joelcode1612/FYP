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
import 'package:sitewise_jaspr_web/features/administration/presentation/components/agent_assignment_control.dart';
import 'package:sitewise_jaspr_web/shared/presentation/components/property_leaflet_map.dart';
import 'package:sitewise_jaspr_web/features/property_verification/presentation/components/location_intelligence_panel.dart';
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
  bool _activityExpanded = true;
  int _referencePhotoIndex = 0; // SITEWISE_LISTING_REFERENCE_V4

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
      ? const ['overview', 'ownership', 'panorama', 'intelligence']
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
    // A property that was never submitted has no verification record. The
    // page still renders: the axes below are reported independently so the
    // reviewer can tell "not submitted" from "unpublished" from "rejected".
    final statuses = detail.statuses;
    final psf = property.rentPerSqft;
    final photos = detail.photos.where((photo) => photo.isUsable).toList();
    return section(classes: 'card vd-hero', [
      if (component.showPanorama)
        div(classes: 'sw-r4-hero-photo', [
          if (photos.isNotEmpty)
            img(src: photos.first.url, alt: 'Photo of ${property.displayName}')
          else
            const Icon('image', size: 'lg'),
        ]),
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
        if (!component.showPanorama && detail.owner != null)
          p(classes: 'small muted', [Component.text('Submitted by ${detail.owner!.displayName}')]),
        div(classes: 'vd-hero__chips', [
          _lifecyclePill(statuses),
          _statusPill(
            detail.verification?.listingStatus ??
                PropertyVerificationStatus.notSubmitted,
          ),
          if ((property.propertyType ?? '').trim().isNotEmpty)
            span(classes: 'chip', [Component.text(property.propertyType!)]),
          // Publication comes from is_published only — an approved listing
          // that was never published is NOT live.
          Pill(
            statuses.isLive ? 'Published' : 'Unpublished',
            tone: statuses.isLive ? 'success' : 'neutral',
          ),
          if (property.addressValidationStatus == 'validated')
            const Pill('Address validated', tone: 'action'),
        ]),
        if (!detail.workflow.available)
          p(classes: 'small muted', [
            Component.text(
              detail.workflow.reason ??
                  'No verification submission exists for this property.',
            ),
          ]),
      ]),
      if (component.showPanorama)
        div(classes: property.isPublished == true || detail.finalReview['approved'] == true
            ? 'sw-r4-people sw-r4-locked' : 'sw-r4-people', [
          div(classes: 'sw-r4-person', [
            const Icon('person', size: 'sm'),
            div([span(classes: 'small muted', [Component.text('Owner')]),
              strong([Component.text(detail.owner?.displayName ?? 'Owner not reported')])]),
          ]),
          AgentAssignmentControl(key: ValueKey('review-agent-${property.propertyId}'),
              propertyId: '${property.propertyId}'),
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
        _tabButton('overview', 'Overview'),
        _tabButton('ownership', 'Ownership Evidence'),
        if (component.showPanorama) _tabButton('panorama', '360° Inspection'),
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
        if (component.showPanorama) ...[
          div(classes: 'vd-overview-grid sw-r4-overview-top', [
            _referenceGallery(detail),
            div(classes: 'sw-r4-facts', [
              h3([Component.text('Property facts')]),
              div(classes: 'vd-info', [
                _infoRow('Property type', _orNotProvided(property.propertyType)),
                _infoRow('Floor', _orNotProvided(property.floorLevel)),
                _infoRow('Unit position', _orNotProvided(property.unitPosition)),
                _infoRow('Furnishing', _orNotProvided(property.furnishing)),
                _infoRow('Frontage', property.frontageFt == null ? 'Not provided' : '${_num(property.frontageFt)} ft'),
                _infoRow('Parking', _parkingLabel(property.hasParking)),
              ]),
            ]),
          ]),
          _referenceInspection(inspection, inspectionNotes),
        ],
        div(classes: 'vd-overview-grid sw-r4-detail-facts', [
          if (!component.showPanorama) ...[
_statusAxesBlock(detail),
          _agentBlock(detail),
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
          ],
          div(classes: 'stack sw-r4-all-facts', [
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

  Component _referenceGallery(VerificationDetail detail) {
    final photos = detail.photos.where((photo) => photo.isUsable).toList();
    if (photos.isEmpty) return _photos(detail);
    final index = _referencePhotoIndex.clamp(0, photos.length - 1).toInt();
    final photo = photos[index];
    return div(classes: 'sw-r4-gallery', [
      div(classes: 'sw-r4-gallery-stage', [
        img(src: photo.url,
            alt: photo.caption ?? 'Property photo ${index + 1}',
            classes: 'sw-r4-gallery-image'),
        if (photos.length > 1) ...[
          button(classes: 'sw-r4-gallery-arrow sw-r4-prev',
            attributes: {'type': 'button', 'aria-label': 'Previous photo'},
            events: events(onClick: () => setState(() =>
                _referencePhotoIndex = (index + photos.length - 1) % photos.length)),
            [const Icon('chevron_left')]),
          button(classes: 'sw-r4-gallery-arrow sw-r4-next',
            attributes: {'type': 'button', 'aria-label': 'Next photo'},
            events: events(onClick: () => setState(() =>
                _referencePhotoIndex = (index + 1) % photos.length)),
            [const Icon('chevron_right')]),
        ],
        span(classes: 'sw-r4-photo-count', [Component.text('${index + 1} / ${photos.length}')]),
      ]),
      if (photos.length > 1)
        div(classes: 'sw-r4-thumbnails', [
          for (final (i, item) in photos.indexed)
            button(classes: 'sw-r4-thumb${i == index ? ' is-active' : ''}',
              attributes: {'type': 'button', 'aria-label': 'Show property photo ${i + 1}', 'aria-pressed': '${i == index}'},
              events: events(onClick: () => setState(() => _referencePhotoIndex = i)),
              [img(src: item.url, alt: '')]),
        ]),
    ]);
  }

  Component _referenceInspection(Map inspection, Map notes) {
    return section(classes: 'sw-r4-inspection', [
      h3([const Icon('fact_check', size: 'sm'), Component.text('Submitted agent inspection')]),
      if (inspection.isEmpty)
        p(classes: 'small muted', [Component.text('No submitted agent inspection is available.')])
      else
        div(classes: 'sw-r4-inspection-rows', [
          for (final (key, label, noteKey) in const [
            ('floor_area_verified', 'Floor area', ''),
            ('condition_verified', 'Condition', 'condition_notes'),
            ('parking_verified', 'Parking', 'parking_notes'),
            ('accessibility_verified', 'Accessibility', 'accessibility_notes'),
          ])
            div(classes: 'sw-r4-inspection-row', [
              strong([Component.text(label)]),
              span(classes: inspection[key] == true ? 'sw-r4-verified' : 'sw-r4-unconfirmed', [
                Icon(inspection[key] == true ? 'check' : 'info', size: 'sm'),
                Component.text(inspection[key] == true ? 'Verified on site' : 'Not confirmed'),
              ]),
              span(classes: 'small muted', [Component.text(notes[noteKey]?.toString() ?? '—')]),
            ]),
        ]),
    ]);
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
    final location =
        _liveLocation ?? detail.locationAnalysis.partB.researchAssociation;
    final active = _locationActive(location);
    if (active) _scheduleLocationRefresh();

    return LocationIntelligencePanel(
      detail: detail,
      location: location,
      map: PropertyLeafletMap(
        property: _mapProperty(detail.property),
        height: 260,
      ),
      inProgress: active,
    );
  }

  LocationResearchAssociation? _liveLocation;
  Timer? _locationTimer;
  bool _locationRequest = false;
  bool _locationActive(LocationResearchAssociation value) =>
      value.predictionPending ||
      value.calculationStatus == 'pending' ||
      value.calculationStatus == 'running';

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
      if (mounted) setState(() => _liveLocation = value);
    } catch (_) {
      // Keep the last saved result available if a scheduled read fails.
    } finally {
      _locationRequest = false;
      if (mounted && _locationActive(
        _liveLocation ?? component.detail.locationAnalysis.partB.researchAssociation,
      )) {
        _scheduleLocationRefresh();
      }
    }
  }

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

    // No submission means no reviewable evidence: the decisions are not just
    // disabled, they are absent, and the reason is stated.
    if (!detail.workflow.available) {
      return aside(classes: 'card vd-side', [
        div(classes: 'vd-side__top', [
          h3([Component.text('Property decision')]),
        ]),
        div(classes: 'vd-side__body', [
          p(classes: 'small muted', [
            Component.text(
              detail.workflow.reason ??
                  'No verification submission exists for this property, so '
                      'there is nothing to approve or reject.',
            ),
          ]),
          p(classes: 'small muted', [
            Component.text(
              'Publication state: '
              '${detail.statuses.isLive ? 'published' : 'unpublished'}. '
              'This property is listed for reference only.',
            ),
          ]),
        ]),
      ]);
    }

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

  /// The six status axes, reported separately.
  ///
  /// They are never collapsed: "approved but unpublished" and "not submitted
  /// but published" are real states, and the reviewer must be able to tell
  /// them apart at a glance.
  Component _statusAxesBlock(VerificationDetail detail) {
    final axes = detail.statuses;
    return section(classes: 'vd-panel', [
      h3([Component.text('Statuses')]),
      div(classes: 'vd-info', [
        _infoRow('Property lifecycle', axes.lifecycleLabel),
        _infoRow('Listing verification', axes.listingVerification.replaceAll('_', ' ')),
        _infoRow(
          'Ownership verification',
          axes.ownershipVerification.replaceAll('_', ' '),
        ),
        _infoRow('Agent inspection', axes.agentInspectionLabel),
        _infoRow('360° panorama', axes.panoramaLabel),
        _infoRow(
          'Publication',
          axes.isLive ? 'Published' : 'Not published',
        ),
      ]),
    ]);
  }

  /// Agent assignment and inspection progress, or an explicit "not assigned".
  Component _agentBlock(VerificationDetail detail) {
    final agent = detail.agentAssignment;
    return section(classes: 'vd-panel', [
      h3([Component.text('Agent inspection')]),
      div(classes: 'vd-info', [
        _infoRow('Progress', agent.stageLabel),
        if (agent.assigned) _infoRow('Agent', agent.displayName),
        if (agent.assignedAt != null) _infoRow('Assigned', _when(agent.assignedAt!)),
        if (agent.submittedAt != null)
          _infoRow('Submitted', _when(agent.submittedAt!)),
        if (agent.declineReason != null)
          _infoRow('Decline reason', agent.declineReason!),
        if (agent.assigned)
          _infoRow(
            'Checklist',
            agent.inspectionComplete ? 'Complete' : 'Incomplete',
          ),
      ]),
    ]);
  }

  /// Compact, timezone-local timestamp; the raw value is kept on failure.
  static String _when(String value) {
    final parsed = DateTime.tryParse(value);
    if (parsed == null) return value;
    final local = parsed.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
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

  /// The property's own lifecycle, kept visually distinct from the two
  /// verification dimensions so "approved but not published" is never read
  /// as "live".
  Component _lifecyclePill(PropertyStatusAxes statuses) => Pill(
    statuses.lifecycleLabel,
    tone: switch (statuses.lifecycle) {
      'published' => 'success',
      'approved' => 'action',
      'rejected' => 'danger',
      'pending' => 'warning',
      _ => 'neutral',
    },
  );

  static String _orNotProvided(String? value) {
    final trimmed = value?.trim() ?? '';
    return trimmed.isEmpty ? 'Not provided' : trimmed;
  }

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
