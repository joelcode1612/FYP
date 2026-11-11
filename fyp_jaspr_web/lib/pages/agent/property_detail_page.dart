import 'dart:async';
import 'dart:js_interop';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';
import 'package:universal_web/web.dart' as web;

import '../../components/dashboard_kit.dart';
import '../../components/ui.dart';
import '../../data/admin_api.dart';
import '../../data/app_locator.dart';
import '../../layouts/app_layout.dart';

/// Agent Property Management — the five-tab editing workspace for one
/// ASSIGNED listing (`/agent/property-detail?id={listingId}`).
///
/// Implements the DESIGN7 prototype as a native Jaspr page:
///
/// * **Overview** — current listing facts, agent-editable availability,
///   owner reference (when the backend resolved one) and completeness.
/// * **Listing details** — validated draft editing; the registered address
///   is read-only because location changes require the separate verified
///   workflow.
/// * **Photos & media** — the operational photo set with upload / remove /
///   set-primary through the assignment-checked staff endpoints.
/// * **Activity** — the preserved server history: change-request audit rows
///   and listing-verification findings, newest first.
/// * **Admin review** — review state, the ORIGINAL vs PROPOSED diff of the
///   open change request, and the Request-Admin-Review action.
///
/// Data comes from `AppLocator.agentListingRepo` (real assignments via
/// `GET /api/v1/staff/me/listings`); nothing on this page is demo data. The
/// draft lives only in this state until the server confirms a save — local
/// edits are never reported as persisted.
@client
class AgentPropertyDetailPage extends StatefulComponent {
  final String id;

  const AgentPropertyDetailPage({super.key, required this.id});

  @override
  State<AgentPropertyDetailPage> createState() =>
      _AgentPropertyDetailPageState();
}

class _AgentPropertyDetailPageState extends State<AgentPropertyDetailPage> {
  // --- Loaded data -----------------------------------------------------------
  AgentListingDetail? _detail;
  List<AgentAssignment> _assignments = const [];
  String? _loadError;
  bool _loading = true;

  // --- Draft editing ---------------------------------------------------------
  final Map<String, String> _draft = {};
  bool _draftParking = false;
  bool _draftFnb = false;
  bool _dirty = false;
  String? _saveNotice;

  // --- History ----------------------------------------------------------------
  bool _historyLoaded = false;
  List<AgentChangeRequest> _history = const [];
  List<AgentActivityEvent> _activity = const [];

  // --- UI state --------------------------------------------------------------
  String _tab = 'overview';
  String _selectorQuery = '';
  bool _previewOpen = false;
  bool _reviewDialogOpen = false;
  String _reviewReason = '';
  String? _reviewError;
  bool _submittingReview = false;
  bool _saving = false;
  bool _uploading = false;
  String? _mediaNotice;
  String _noteText = '';
  bool _savingNote = false;
  String? _noteError;

  /// Persists the current editor state so leaving the page (back to My
  /// Properties, another listing) and returning does not discard typed values.
  /// Only the SERVER draft is shared across devices; this is the local,
  /// not-yet-saved buffer and it is cleared once the draft is saved.
  void _rememberUnsaved() {
    final listingId = _detail?.assignment.listingId;
    if (listingId == null) return;
    if (!_dirty) {
      _UnsavedDraftStore.clear(listingId);
      return;
    }
    _UnsavedDraftStore.write(
      listingId,
      _UnsavedDraft(
        fields: Map<String, String>.from(_draft),
        parking: _draftParking,
        fnb: _draftFnb,
      ),
    );
  }

  static const _availabilityOptions = [
    'Available',
    'Under Offer',
    'Rented',
    'Viewing Paused',
  ];
  static const _propertyTypes = [
    'Shoplot',
    'Corner Shoplot',
    'Retail Space',
    'Ground Floor Shop',
    'Retail Unit',
    'Kiosk',
    'Commercial F&B Premise',
  ];

  AgentListingRepository get _repo => AppLocator.agentListingRepo;

  @override
  void initState() {
    super.initState();
    _refresh(assignmentsToo: true);
    _installUnloadGuard();
  }

  /// Warns before the browser unloads the page with unsaved edits (reload,
  /// close, external navigation). In-app navigation is safe: every keystroke is
  /// mirrored into [_UnsavedDraftStore] and restored by [_resetDraft].
  void _installUnloadGuard() {
    web.window.addEventListener(
      'beforeunload',
      ((web.Event event) {
        if (!_dirty) return;
        event.preventDefault();
        (event as web.BeforeUnloadEvent).returnValue = '';
      }).toJS,
    );
  }

  Future<void> _refresh({bool assignmentsToo = false}) async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    final listingId = int.tryParse(component.id);
    if (listingId == null || listingId <= 0) {
      setState(() {
        _loading = false;
        _loadError = 'invalid-id';
      });
      return;
    }
    try {
      if (assignmentsToo || _assignments.isEmpty) {
        _assignments = await _repo.assignedListings();
      }
      final detail = await _repo.listingDetail(listingId);
      if (!mounted) return;
      setState(() {
        _detail = detail;
        _loading = false;
        _historyLoaded = false;
        _history = const [];
        _activity = const [];
      });
      _resetDraft(detail);
      // Loaded eagerly (not on first tab visit) so the Overview review card
      // can show the latest administrator decision without the agent having
      // to hunt for the Admin review tab.
      unawaited(_loadHistory());
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = AdminApi.message(error);
      });
    }
  }

  /// Restores the editor from the LIVE listing values, then layers the agent's
  /// own persisted DRAFT on top. Reopening a property — or returning to it
  /// after navigating away — therefore shows the saved proposal instead of
  /// silently discarding it and presenting the published values.
  void _resetDraft(AgentListingDetail detail) {
    final facts = detail.facts;
    final open = detail.openRequest;
    final proposed =
        open != null && open.status == AgentChangeRequest.statusDraft
        ? open.changes
        : const <String, Map<String, dynamic>>{};

    String text(String field, String fallback) {
      final entry = proposed[field];
      if (entry == null || !entry.containsKey('to')) return fallback;
      final value = entry['to'];
      if (value == null) return '';
      if (value is num) return _numText(value.toDouble());
      return '$value';
    }

    bool flag(String field, bool fallback) {
      final value = proposed[field]?['to'];
      return value is bool ? value : fallback;
    }

    // Unsaved values typed earlier in this browser session win over the
    // server state: returning to the page must not silently lose them.
    final unsaved = _UnsavedDraftStore.read(detail.assignment.listingId);

    setState(() {
      _dirty = unsaved != null;
      _saveNotice = unsaved == null
          ? null
          : 'Restored unsaved edits from this session — save the draft to '
                'persist them.';
      _draftParking = unsaved?.parking ?? flag(
        'has_parking',
        facts?.hasParking ?? false,
      );
      _draftFnb = unsaved?.fnb ?? flag(
        'is_fnb_suitable',
        facts?.isFnbSuitable ?? false,
      );
      _draft
        ..clear()
        ..addAll(
          unsaved?.fields ??
              {
                'name': text('name', facts?.name ?? ''),
                'rental_price': text(
                  'rental_price',
                  _numText(facts?.rentalPrice),
                ),
                'size_sqft': text('size_sqft', _numText(facts?.sizeSqft)),
                'property_type': text(
                  'property_type',
                  facts?.propertyType ?? '',
                ),
                'floor_level': text(
                  'floor_level',
                  _numText(facts?.floorLevel),
                ),
                'availability': text(
                  'availability',
                  facts?.availability ?? '',
                ),
                'description': text(
                  'description',
                  facts?.description ?? '',
                ),
              },
        );
    });
  }

  static String _numText(double? value) => switch (value) {
    null => '',
    _ when value.round() == value => '${value.round()}',
    _ => '$value',
  };

  AgentListingFacts? get _facts => _detail?.facts;
  AgentChangeRequest? get _openRequest => _detail?.openRequest;
  bool get _hasPending => _openRequest?.isPending ?? false;

  // --- Draft mutations -------------------------------------------------------

  void _setField(String field, String value) {
    setState(() {
      _draft[field] = value;
      _dirty = true;
      _saveNotice = null;
    });
    _rememberUnsaved();
  }

  /// Availability is part of the PROPOSED listing state — it never touches
  /// the administrator's verification or publication status.
  void _setAvailability(String value) {
    setState(() {
      _draft['availability'] = value;
      _dirty = true;
      _saveNotice = null;
    });
    _rememberUnsaved();
  }

  String? _validate() {
    if (_draft['name']!.trim().length < 4) {
      return 'Property title must be at least 4 characters.';
    }
    final rent = double.tryParse(_draft['rental_price']!.trim());
    if (rent == null || rent <= 0) {
      return 'Monthly rental must be a positive number.';
    }
    final area = double.tryParse(_draft['size_sqft']!.trim());
    if (area == null || area <= 0) {
      return 'Built-up area must be a positive number.';
    }
    return null;
  }

  Future<void> _saveDraft() async {
    final detail = _detail;
    if (detail == null || _saving) return;
    final error = _validate();
    if (error != null) {
      setState(() {
        _tab = 'details';
        _saveNotice = error;
      });
      return;
    }
    setState(() {
      _saving = true;
      _saveNotice = null;
    });
    try {
      final result = await _repo.saveProposal(
        detail.assignment.listingId,
        AgentProposal(
          name: _draft['name']!.trim(),
          rentalPrice: double.tryParse(_draft['rental_price']!.trim()),
          sizeSqft: double.tryParse(_draft['size_sqft']!.trim()),
          propertyType: _draft['property_type']!.trim(),
          floorLevel: _draft['floor_level']!.trim(),
          availability: _draft['availability']!.trim(),
          description: _draft['description']!.trim(),
          hasParking: _draftParking,
          isFnbSuitable: _draftFnb,
        ),
      );
      if (!mounted) return;
      _UnsavedDraftStore.clear(detail.assignment.listingId);
      setState(() {
        _saving = false;
        _dirty = false;
        _saveNotice = result.updated
            ? 'Draft saved on the server. The published listing is unchanged '
                  'until an administrator approves the change.'
            : 'No differences from the current listing values — nothing was '
                  'saved.';
        if (result.request != null) _replaceOpenRequest(result.request);
        _historyLoaded = false;
      });
    } on Object catch (err) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _saveNotice = AdminApi.message(err);
      });
    }
  }

  void _replaceOpenRequest(AgentChangeRequest? request) {
    final detail = _detail;
    if (detail == null) return;
    _detail = AgentListingDetail(
      assignment: detail.assignment,
      facts: detail.facts,
      owner: detail.owner,
      photos: detail.photos,
      openRequest: request,
    );
  }

  void _discardDraft() {
    final detail = _detail;
    if (detail == null) return;
    _UnsavedDraftStore.clear(detail.assignment.listingId);
    _resetDraft(detail);
  }

  Future<void> _submitReview() async {
    final detail = _detail;
    if (detail == null || _submittingReview) return;
    final reason = _reviewReason.trim();
    if (reason.length < 12) {
      setState(() {
        _reviewError = 'Enter a reason of at least 12 characters.';
      });
      return;
    }
    if (_dirty) {
      setState(() {
        _reviewError =
            'Save the current draft first — the review request submits the '
            'saved proposal, not unsaved edits.';
      });
      return;
    }
    setState(() {
      _submittingReview = true;
      _reviewError = null;
    });
    try {
      final request = await _repo.requestAdminReview(
        detail.assignment.listingId,
        reason,
      );
      if (!mounted) return;
      setState(() {
        _submittingReview = false;
        _reviewDialogOpen = false;
        _reviewReason = '';
        _historyLoaded = false;
      });
      _replaceOpenRequest(request);
      await _loadHistory();
    } on Object catch (err) {
      if (!mounted) return;
      setState(() {
        _submittingReview = false;
        _reviewError = AdminApi.message(err);
      });
    }
  }

  // --- History -----------------------------------------------------------------

  Future<void> _loadHistory() async {
    final detail = _detail;
    if (detail == null || _historyLoaded) return;
    try {
      final history = await _repo.changeHistory(detail.assignment.listingId);
      final findings = await _repo.verificationFindings(
        detail.assignment.listingId,
      );
      final merged = [...history.audit, ...findings];
      merged.sort((left, right) => right.createdAt.compareTo(left.createdAt));
      if (!mounted) return;
      setState(() {
        _activity = merged;
        _history = history.requests;
        _historyLoaded = true;
      });
    } on Object {
      if (!mounted) return;
      setState(() {
        _activity = const [];
        _history = const [];
        _historyLoaded = true;
      });
    }
  }

  void _selectTab(String tab) {
    if (_tab == tab) return;
    setState(() => _tab = tab);
    if (tab == 'activity' || tab == 'review') unawaited(_loadHistory());
  }

  // --- Media -----------------------------------------------------------------

  static const _allowedTypes = {'image/jpeg', 'image/png', 'image/webp'};
  static const _maxPhotoBytes = 8 * 1024 * 1024;

  Future<void> _handleFiles(List<web.File> files) async {
    final detail = _detail;
    if (detail == null || files.isEmpty || _uploading) return;
    setState(() {
      _uploading = true;
      _mediaNotice = null;
    });
    var uploaded = 0;
    String? failure;
    for (final file in files) {
      if (!_allowedTypes.contains(file.type)) {
        failure = 'Use JPG, PNG or WebP images — "${file.name}" was skipped.';
        continue;
      }
      if (file.size > _maxPhotoBytes) {
        failure = '"${file.name}" is larger than 8 MB and was skipped.';
        continue;
      }
      try {
        final buffer = (await file.arrayBuffer().toDart).toDart;
        await _repo.uploadPhoto(
          detail.assignment.listingId,
          filename: file.name,
          contentType: file.type,
          bytes: buffer.asUint8List(),
        );
        uploaded++;
      } on Object catch (err) {
        failure = AdminApi.message(err);
        break;
      }
    }
    if (!mounted) return;
    setState(() {
      _uploading = false;
      _mediaNotice =
          failure ??
          (uploaded > 0 ? '$uploaded photo(s) uploaded to the listing.' : null);
    });
    if (uploaded > 0) await _reloadPhotos();
  }

  Future<void> _reloadPhotos() async {
    final detail = _detail;
    if (detail == null) return;
    try {
      final fresh = await _repo.listingDetail(detail.assignment.listingId);
      if (!mounted) return;
      setState(() {
        _detail = AgentListingDetail(
          assignment: fresh.assignment,
          facts: fresh.facts,
          owner: fresh.owner,
          photos: fresh.photos,
          openRequest: _openRequest,
        );
      });
    } on Object {
      // The gallery keeps the previous state; the failure is reported by the
      // next action, never silently rewritten.
    }
  }

  Future<void> _removePhoto(AgentPhoto photo) async {
    final detail = _detail;
    if (detail == null) return;
    setState(() => _mediaNotice = null);
    try {
      await _repo.deletePhoto(detail.assignment.listingId, photo.id);
      await _reloadPhotos();
    } on Object catch (err) {
      if (!mounted) return;
      setState(() => _mediaNotice = AdminApi.message(err));
    }
  }

  Future<void> _makePrimary(AgentPhoto photo) async {
    final detail = _detail;
    if (detail == null) return;
    try {
      await _repo.setPrimaryPhoto(detail.assignment.listingId, photo.id);
      await _reloadPhotos();
    } on Object catch (err) {
      if (!mounted) return;
      setState(() => _mediaNotice = AdminApi.message(err));
    }
  }

  void _onFilesPicked() {
    final event = web.window.event;
    if (event == null) return;
    final target = event.target;
    if (target == null || !target.isA<web.HTMLInputElement>()) return;
    final inputElement = target as web.HTMLInputElement;
    final files = inputElement.files;
    if (files == null) return;
    final picked = [for (var i = 0; i < files.length; i++) files.item(i)!];
    inputElement.value = '';
    unawaited(_handleFiles(picked));
  }

  Future<void> _addNote() async {
    final detail = _detail;
    final text = _noteText.trim();
    if (detail == null || text.isEmpty || _savingNote) return;
    setState(() {
      _savingNote = true;
      _noteError = null;
    });
    try {
      await _repo.addNote(detail.assignment.listingId, text);
      if (!mounted) return;
      setState(() {
        _noteText = '';
        _savingNote = false;
        _historyLoaded = false;
      });
      await _loadHistory();
    } on Object catch (err) {
      if (!mounted) return;
      setState(() {
        _savingNote = false;
        _noteError = AdminApi.message(err);
      });
    }
  }

  // --- Selector --------------------------------------------------------------

  /// The route for another assigned listing. Navigation is a normal
  /// router navigation: unsaved values live in [_UnsavedDraftStore], so they
  /// are restored by [_resetDraft] when the agent comes back.
  String _routeFor(int listingId) => '/agent/property-detail?id=$listingId';

  List<AgentAssignment> get _filteredAssignments {
    final q = _selectorQuery.trim().toLowerCase();
    if (q.isEmpty) return _assignments;
    return _assignments.where((assignment) {
      final hay =
          '${assignment.displayTitle} ${assignment.displayId} ${assignment.raw['city'] ?? ''}';
      return hay.toLowerCase().contains(q);
    }).toList();
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Component build(BuildContext context) {
    return AppLayout(
      role: AppRole.agent,
      currentRoute: '/agent/property-detail',
      title: 'Manage property',
      eyebrow: 'Staff portal · agent',
      subtitle:
          'Keep listing details current, track availability, and prepare '
          'verified changes for administrator review.',
      actions: [
        if (_detail != null)
          ActionButton(
            'Preview listing',
            onClick: () => setState(() => _previewOpen = true),
            variant: 'ghost',
          ),
        ActionLink(
          'Back to listings',
          href: '/agent/listings',
          variant: 'secondary',
        ),
      ],
      child: _body(),
    );
  }

  Component _body() {
    if (_loading) {
      return div(classes: 'loading', [
        span(classes: 'spinner', []),
        Component.text('Loading listing…'),
      ]);
    }
    if (_loadError == 'invalid-id') {
      return _stateCard(
        title: 'Listing id missing',
        body:
            'This page needs a numeric listing id: '
            '/agent/property-detail?id={listingId}. Open it from Assigned '
            'Listings so the id comes from a real assignment.',
      );
    }
    if (_loadError != null) {
      final forbidden = _loadError!.contains('not assigned to you');
      final missing = _loadError!.toLowerCase().contains('not found');
      return _stateCard(
        title: forbidden
            ? 'Not your assignment'
            : missing
            ? 'Listing not found'
            : 'Could not load this listing',
        body: _loadError!,
      );
    }
    final detail = _detail;
    if (detail == null) return const Component.text('');
    final facts = detail.facts;
    if (facts == null) {
      return _stateCard(
        title: 'Operational record not linked',
        body:
            'The assignment exists, but no operational property row matches '
            'this numeric id yet. Editing, photos and change requests need '
            'that record — ask an administrator to check the link.',
      );
    }
    return div(classes: 'swpm stack', [
      ?_selectorPanel(),
      div(classes: 'swpm-topgrid', [
        _propertyCard(detail, facts),
        _reviewCard(facts),
      ]),
      div(classes: 'swpm-edgrid', [_editor(detail, facts), _sideStack(facts)]),
      if (_previewOpen) _previewDialog(facts),
      if (_reviewDialogOpen) _reviewDialog(),
    ]);
  }

  Component _stateCard({required String title, required String body}) {
    return div(classes: 'card stack', [
      span(classes: 'title', [Component.text(title)]),
      p(classes: 'body muted', [Component.text(body)]),
      div(classes: 'btn-row', [
        ActionLink(
          'Back to listings',
          href: '/agent/listings',
          variant: 'secondary',
        ),
        ActionButton(
          'Try again',
          onClick: () => unawaited(_refresh(assignmentsToo: true)),
          variant: 'secondary',
        ),
      ]),
    ]);
  }

  // --- Selector ---------------------------------------------------------------

  Component? _selectorPanel() {
    if (_assignments.isEmpty) return null;
    final rows = _filteredAssignments;
    return section(classes: 'panel swpm-select', [
      div(classes: 'swpm-select-head', [
        div([
          h2(classes: 'swpm-h2', [Component.text('Portfolio properties')]),
          p(classes: 'swpm-sub', [
            Component.text(
              '${_assignments.length} listing(s) assigned to you by an '
              'administrator — choose one to inspect or edit its draft.',
            ),
          ]),
        ]),
        SearchInput(
          ariaLabel: 'Search property selector',
          placeholder: 'Search listings…',
          onInput: (value) => setState(() => _selectorQuery = value),
        ),
      ]),
      div(classes: 'swpm-selectors', [
        for (final row in rows) _selectorCard(row),
      ]),
    ]);
  }

  /// Every card is a real link (router-intercepted), including while the
  /// current listing has unsaved edits: those edits are already mirrored into
  /// [_UnsavedDraftStore] on each keystroke, so switching listings no longer
  /// loses them and no confirm dialog is needed. Middle-click and
  /// open-in-new-tab keep working because nothing is a synthetic button.
  Component _selectorCard(AgentAssignment assignment) {
    final selected = assignment.listingId == _detail?.assignment.listingId;
    final classes = selected
        ? 'swpm-selector swpm-selector--active'
        : 'swpm-selector';
    final attributes = {'aria-pressed': selected ? 'true' : 'false'};
    final children = [
      span(classes: 'swpm-selector-row', [
        Component.text(assignment.displayId),
        span([Component.text(_statusLabel(_facts))]),
      ]),
      span(classes: 'swpm-selector-title', [
        Component.text(
          assignment.displayTitle.isEmpty
              ? _facts?.name ?? 'Untitled assignment'
              : assignment.displayTitle,
        ),
      ]),
      if (_UnsavedDraftStore.read(assignment.listingId) != null)
        span(classes: 'swpm-selector-note', [
          Component.text('Unsaved edits kept'),
        ]),
    ];
    return AppLink(
      to: _routeFor(assignment.listingId),
      classes: classes,
      attributes: attributes,
      children: children,
    );
  }

  // --- Property card -----------------------------------------------------------

  Component _propertyCard(AgentListingDetail detail, AgentListingFacts facts) {
    return div(classes: 'swpm-card swpm-property', [
      div(classes: 'swpm-property-head', [
        div(classes: 'grow', [
          span(classes: 'swpm-idline', [
            Component.text('LISTING · ${detail.assignment.displayId}'),
          ]),
          h2(classes: 'swpm-title', [Component.text(facts.name)]),
          p(classes: 'swpm-address', [
            Component.text(
              facts.addressDisplay.isEmpty
                  ? 'No address recorded on the operational row'
                  : facts.addressDisplay,
            ),
          ]),
          div(classes: 'swpm-pills', _pills(facts)),
        ]),
        span(classes: 'badge badge-muted', [
          Component.text('Assigned listing'),
        ]),
      ]),
      div(classes: 'swpm-property-body', [
        div(classes: 'swpm-facts', _factTiles(facts)),
        _ownerBlock(detail),
      ]),
      div(classes: 'swpm-foot', [
        span(classes: 'ms', [Component.text('info')]),
        span([
          Component.text(
            'Registered location and ownership data come from the verified '
            'record and are read-only here. Draft changes are not publicly '
            'visible.',
          ),
        ]),
      ]),
    ]);
  }

  List<Component> _pills(AgentListingFacts facts) => [
    StatusBadge(
      _availabilityLabel(facts.availability),
      tone: _availabilityTone(facts.availability),
      dot: true,
    ),
    StatusBadge.forVerification(_verificationOf(facts)),
    StatusBadge(
      facts.isPublished ? 'Published' : 'Not published',
      tone: facts.isPublished ? 'success' : 'neutral',
    ),
  ];

  static VerificationStatus _verificationOf(AgentListingFacts facts) =>
      switch (facts.verificationStatus) {
        'approved' => VerificationStatus.verified,
        'pending' => VerificationStatus.pending,
        'rejected' => VerificationStatus.rejected,
        _ => VerificationStatus.draft,
      };

  static String _availabilityLabel(String? value) =>
      value == null || value.trim().isEmpty ? 'Availability not set' : value;

  static String _availabilityTone(String? value) =>
      value != null && value.trim().toLowerCase() == 'available'
      ? 'success'
      : 'warning';

  static String _statusLabel(AgentListingFacts? facts) => facts == null
      ? '—'
      : switch (facts.verificationStatus) {
          'approved' => 'Verified',
          'pending' => 'Pending review',
          'rejected' => 'Rejected',
          _ => 'Draft',
        };

  List<Component> _factTiles(AgentListingFacts facts) => [
    _fact(
      'Monthly rental',
      facts.rentalDisplay.isEmpty
          ? 'Not recorded'
          : '${facts.rentalDisplay}/mo',
    ),
    _fact(
      'Built-up area',
      facts.areaDisplay.isEmpty ? 'Not recorded' : facts.areaDisplay,
    ),
    _fact(
      'Floor level',
      facts.floorLevel == null
          ? 'Not recorded'
          : 'Storey ${_numText(facts.floorLevel)}',
    ),
    _fact(
      'Property type',
      facts.propertyType?.isNotEmpty == true
          ? facts.propertyType!
          : 'Not recorded',
    ),
    _fact('Verification', _statusLabel(facts)),
    _fact('Updated', _shortDate(facts.updatedAt)),
  ];

  static Component _fact(String label, String value) =>
      div(classes: 'swpm-fact', [
        small([Component.text(label)]),
        strong([Component.text(value)]),
      ]);

  Component _ownerBlock(AgentListingDetail detail) {
    final owner = detail.owner;
    return div(classes: 'swpm-ownerbox', [
      span(classes: 'swpm-label', [Component.text('Owner information')]),
      if (owner != null) ...[
        span(classes: 'who', [
          Component.text(
            owner.displayName.isEmpty
                ? 'Owner record exists'
                : owner.displayName,
          ),
        ]),
        span(classes: 'sub', [
          Component.text(
            'Shown because this listing carries a submitting owner. Only '
            'what the backend exposes to staff is displayed.',
          ),
        ]),
      ] else
        p(classes: 'sub', [
          Component.text(
            'Not available — this row has no submitting owner (imported '
            'research record), so no ownership reference exists to show.',
          ),
        ]),
    ]);
  }

  // --- Review card -------------------------------------------------------------

  Component _reviewCard(AgentListingFacts facts) {
    return div(classes: 'swpm-card swpm-review', [
      div(classes: 'swpm-cardtop', [
        div([
          h2(classes: 'swpm-h2', [Component.text('Review & publication')]),
          p(classes: 'swpm-sub', [
            Component.text('Approval and availability are different statuses.'),
          ]),
        ]),
        StatusBadge.forVerification(_verificationOf(facts)),
      ]),
      div(classes: 'swpm-review-status', [
        _stateRow('Availability (proposed)', _draft['availability'] ?? '—'),
        _stateRow('Verification', _statusLabel(facts)),
        _stateRow(
          'Publication',
          facts.isPublished ? 'Published' : 'Not published',
        ),
        _stateRow(
          'Change requests awaiting review',
          _hasPending ? '1 pending' : 'None',
        ),
      ]),
      if (_latestNegativeDecision != null)
        Callout(
          _negativeDecisionText(_latestNegativeDecision!),
          tone: _latestNegativeDecision!.status ==
                  AgentChangeRequest.statusRejected
              ? 'danger'
              : 'warning',
          icon: 'history',
        ),
      div(classes: 'swpm-boundary', [
        span(classes: 'ms', [Component.text('admin_panel_settings')]),
        span([
          Component.text(
            'Administrator-controlled. New Entrepreneur submissions enter '
            'review automatically. You can request review of your changes '
            'but cannot approve ownership, verification or publication.',
          ),
        ]),
      ]),
      ActionButton(
        _hasPending ? 'Review request pending' : 'Request review of changes',
        onClick: _hasPending
            ? null
            : () => setState(() {
                _reviewDialogOpen = true;
                _reviewError = null;
              }),
        variant: 'primary',
        icon: 'north_east',
      ),
      p(classes: 'swpm-sub', [
        Component.text(
          _hasPending
              ? 'An administrator has not decided on the open request yet.'
              : 'Submits the saved draft proposal — never unsaved edits.',
        ),
      ]),
    ]);
  }

  static Component _stateRow(String label, String value) =>
      div(classes: 'swpm-state-row', [
        span([Component.text(label)]),
        strong([Component.text(value)]),
      ]);

  // --- Editor -------------------------------------------------------------------

  Component _editor(AgentListingDetail detail, AgentListingFacts facts) {
    return section(classes: 'panel swpm-editor', [
      div(classes: 'swpm-tabs', _tabButtons()),
      div(
        classes: 'swpm-editor-body',
        attributes: {'role': 'tabpanel', 'aria-labelledby': 'swpm-tab-$_tab'},
        [
          switch (_tab) {
            'overview' => _overviewTab(facts),
            'details' => _detailsTab(facts),
            'media' => _mediaTab(detail),
            'activity' => _activityTab(),
            _ => _adminReviewTab(facts),
          },
        ],
      ),
    ]);
  }

  List<Component> _tabButtons() {
    Component tab(String key, String label) {
      final selected = _tab == key;
      return button(
        classes: selected ? 'swpm-tab swpm-tab--active' : 'swpm-tab',
        attributes: {
          'type': 'button',
          'role': 'tab',
          'id': 'swpm-tab-$key',
          'aria-selected': selected ? 'true' : 'false',
        },
        events: events(onClick: () => _selectTab(key)),
        [Component.text(label)],
      );
    }

    return [
      tab('overview', 'Overview'),
      tab('details', 'Listing details'),
      tab('media', 'Photos & media'),
      tab('activity', 'Activity'),
      tab('review', 'Admin review'),
    ];
  }

  Component _sectionHead(String title, String subtitle, [String? chip]) {
    return div(classes: 'swpm-section-head', [
      div([
        h3(classes: 'swpm-h3', [Component.text(title)]),
        p(classes: 'swpm-sub', [Component.text(subtitle)]),
      ]),
      if (chip != null) StatusBadge(chip, tone: 'action'),
    ]);
  }

  Component _savebar() {
    return div(classes: 'swpm-savebar', [
      p(classes: 'swpm-savebar-note', [
        Component.text(
          _dirty
              ? '● Unsaved edits — local draft only.'
              : '✓ Draft in step with the current proposal state.',
        ),
        Component.text(
          ' The published listing is unchanged until an administrator '
          'approves a change.',
        ),
      ]),
      div(classes: 'btn-row', [
        ActionButton(
          'Discard changes',
          onClick: _discardDraft,
          variant: 'ghost',
        ),
        ActionButton(
          'Save draft',
          onClick: _saving ? null : () => unawaited(_saveDraft()),
          variant: 'secondary',
        ),
      ]),
    ]);
  }

  // --- Tab: overview ------------------------------------------------------------

  Component _overviewTab(AgentListingFacts facts) {
    return div(classes: 'stack stack--sections', [
      _sectionHead(
        'Manage availability',
        'Choose a status for the proposed listing update. This changes the '
            'proposal only — never the administrator\u2019s verification or '
            'publication decision.',
        'Agent-editable proposal',
      ),
      div(classes: 'swpm-avail', [
        for (final optionText in _availabilityOptions)
          button(
            classes: _draft['availability'] == optionText
                ? 'swpm-avail-btn swpm-avail-btn--active'
                : 'swpm-avail-btn',
            attributes: {
              'type': 'button',
              'aria-pressed': _draft['availability'] == optionText
                  ? 'true'
                  : 'false',
            },
            events: events(onClick: () => _setAvailability(optionText)),
            [Component.text(optionText)],
          ),
      ]),
      div(classes: 'swpm-inline-note', [
        span(classes: 'ms', [Component.text('info')]),
        span([
          Component.text(
            'Availability describes whether the unit can be offered to '
            'tenants. It is not verification: a selection here can never '
            'approve or publish the property.',
          ),
        ]),
      ]),
      h4(classes: 'swpm-h4', [Component.text('Current listing information')]),
      div(classes: 'swpm-tiles', [
        _tile(
          'Asking rental',
          facts.rentalDisplay.isEmpty
              ? 'Not recorded'
              : '${facts.rentalDisplay} per month',
        ),
        _tile(
          'Floor area',
          facts.areaDisplay.isEmpty ? 'Not recorded' : facts.areaDisplay,
        ),
        _tile(
          'Parking',
          facts.hasParking ? 'Parking available' : 'No parking recorded',
        ),
        _tile(
          'F&B suitability flag',
          facts.isFnbSuitable ? 'Flagged suitable' : 'Not flagged',
        ),
      ]),
      div(classes: 'swpm-value-line', [
        span([Component.text('Property details need updating?')]),
        ActionButton(
          'Edit listing details',
          onClick: () => _selectTab('details'),
          variant: 'secondary',
          icon: 'arrow_forward',
        ),
      ]),
      _savebar(),
    ]);
  }

  static Component _tile(String label, String value) =>
      div(classes: 'swpm-tile', [
        strong([Component.text(label)]),
        p([Component.text(value)]),
      ]);

  // --- Tab: details -------------------------------------------------------------

  Component _detailsTab(AgentListingFacts facts) {
    return form(
      classes: 'stack stack--sections',
      attributes: {'novalidate': 'novalidate'},
      [
        _sectionHead(
          'Listing details',
          'Prepare authorized changes. Saving writes a server-side draft '
              'proposal; public data is not overwritten.',
          'Draft editing',
        ),
        if (_saveNotice != null) ActionNotice(_saveNotice!, tone: 'info'),
        div(classes: 'swpm-fieldgrid', [
          _textField(
            key: 'name',
            label: 'Property title',
            value: _draft['name']!,
          ),
          _numberField(
            key: 'rental_price',
            label: 'Monthly rental · RM',
            value: _draft['rental_price']!,
            hint: 'Positive number, whole ringgit.',
          ),
          _numberField(
            key: 'size_sqft',
            label: 'Built-up area · sqft',
            value: _draft['size_sqft']!,
            hint: 'Positive number.',
          ),
          Field(
            labelText: 'Property type',
            child: select(
              attributes: {'aria-label': 'Property type'},
              events: events<List<String>>(
                onInput: (values) => _setField(
                  'property_type',
                  values.isEmpty ? '' : values.first,
                ),
              ),
              [
                for (final entry in _propertyTypes)
                  option(
                    value: entry,
                    attributes: _draft['property_type'] == entry
                        ? {'selected': ''}
                        : null,
                    [Component.text(entry)],
                  ),
              ],
            ),
          ),
          _numberField(
            key: 'floor_level',
            label: 'Floor level',
            value: _draft['floor_level']!,
            hint: 'Storey number of the unit (0 = ground floor).',
          ),
          Field(
            labelText: 'Availability',
            child: select(
              attributes: {'aria-label': 'Availability'},
              events: events<List<String>>(
                onInput: (values) =>
                    _setAvailability(values.isEmpty ? '' : values.first),
              ),
              [
                for (final entry in _availabilityOptions)
                  option(
                    value: entry,
                    attributes: _draft['availability'] == entry
                        ? {'selected': ''}
                        : null,
                    [Component.text(entry)],
                  ),
              ],
            ),
          ),
          Field(
            labelText: 'Registered location · read only',
            hint:
                'Location and ownership changes require the separate '
                'verified workflow.',
            child: input(
              attributes: {
                'type': 'text',
                'value': facts.addressDisplay,
                'readonly': 'readonly',
              },
            ),
          ),
          div(classes: 'swpm-checkgrid', [
            label(classes: 'swpm-check', [
              input(
                type: InputType.checkbox,
                checked: _draftParking,
                events: events(
                  onClick: () {
                    setState(() {
                      _draftParking = !_draftParking;
                      _dirty = true;
                      _saveNotice = null;
                    });
                    _rememberUnsaved();
                  },
                ),
              ),
              span([Component.text('Parking available')]),
            ]),
            label(classes: 'swpm-check', [
              input(
                type: InputType.checkbox,
                checked: _draftFnb,
                events: events(
                  onClick: () {
                    setState(() {
                      _draftFnb = !_draftFnb;
                      _dirty = true;
                      _saveNotice = null;
                    });
                    _rememberUnsaved();
                  },
                ),
              ),
              span([Component.text('Flagged as F&B suitable')]),
            ]),
          ]),
          Field(
            labelText: 'Property description',
            child: textarea(
              attributes: {'maxlength': '4000', 'rows': '6'},
              events: events<String>(
                onInput: (v) => _setField('description', v),
              ),
              [Component.text(_draft['description']!)],
            ),
          ),
        ]),
        _savebar(),
      ],
    );
  }

  Component _textField({
    required String key,
    required String label,
    required String value,
  }) {
    return Field(
      labelText: label,
      child: input(
        attributes: {'type': 'text', 'value': value},
        events: events<String>(onInput: (v) => _setField(key, v)),
      ),
    );
  }

  Component _numberField({
    required String key,
    required String label,
    required String value,
    String? hint,
  }) {
    return Field(
      labelText: label,
      hint: hint,
      child: input(
        attributes: {'type': 'number', 'value': value, 'min': '0', 'step': '1'},
        // Jaspr delivers `num` (valueAsNumber) for number inputs — a String
        // subscription throws at runtime (see add_property_page).
        events: events<num>(
          onInput: (v) => _setField(key, v.isNaN ? '' : _numText(v.toDouble())),
        ),
      ),
    );
  }

  // --- Tab: media -----------------------------------------------------------------

  Component _mediaTab(AgentListingDetail detail) {
    final photos = detail.photos;
    return div(classes: 'stack stack--sections', [
      _sectionHead(
        'Photos & media',
        'Images belong to this listing and are stored on the server — an '
            'upload is only reported once the backend confirms it.',
        'Server storage',
      ),
      if (_mediaNotice != null) ActionNotice(_mediaNotice!, tone: 'info'),
      div(classes: 'swpm-media-grid', [
        for (final photo in photos)
          div(classes: 'swpm-media-item', [
            Component.element(
              tag: 'img',
              attributes: {
                'src': photo.url,
                'alt': photo.caption.isEmpty
                    ? 'Listing photo ${photo.id}'
                    : photo.caption,
                'loading': 'lazy',
              },
              children: [],
            ),
            if (photo.isPrimary)
              span(classes: 'swpm-media-primary', [Component.text('Primary')]),
            div(classes: 'swpm-media-actions', [
              if (!photo.isPrimary)
                button(
                  classes: 'swpm-mini',
                  attributes: {'type': 'button'},
                  events: events(onClick: () => unawaited(_makePrimary(photo))),
                  [Component.text('Set primary')],
                ),
              button(
                classes: 'swpm-mini swpm-mini--danger',
                attributes: {'type': 'button'},
                events: events(onClick: () => unawaited(_removePhoto(photo))),
                [Component.text('Remove')],
              ),
            ]),
            if (photo.caption.isNotEmpty)
              span(classes: 'swpm-media-caption', [
                Component.text(photo.caption),
              ]),
          ]),
        label(classes: 'swpm-upload', [
          span(classes: 'swpm-upload-title', [
            Component.text(
              _uploading ? 'Uploading…' : 'Upload property photos',
            ),
          ]),
          span(classes: 'swpm-upload-hint', [
            Component.text('JPEG, PNG or WebP · up to 8 MB each'),
          ]),
          input(
            type: InputType.file,
            attributes: {
              'accept': 'image/png,image/jpeg,image/webp',
              'multiple': 'multiple',
              if (_uploading) 'disabled': 'disabled',
            },
            events: events(onChange: (_) => _onFilesPicked()),
          ),
        ]),
      ]),
      p(classes: 'swpm-sub', [
        Component.text(
          photos.isEmpty
              ? 'No photos are stored for this listing yet.'
              : '${photos.length} photo(s) stored on the listing.',
        ),
      ]),
    ]);
  }

  // --- Tab: activity ----------------------------------------------------------------

  Component _activityTab() {
    return div(classes: 'stack stack--sections', [
      _sectionHead(
        'Activity and internal notes',
        'The preserved server history for this listing — change-request '
            'events and verification findings, newest first.',
        'Audit history',
      ),
      if (!_historyLoaded)
        div(classes: 'loading', [
          span(classes: 'spinner', []),
          Component.text('Loading history…'),
        ])
      else if (_activity.isEmpty)
        EmptyState(
          title: 'No recorded activity yet',
          body:
              'Saving a draft, requesting a review, an administrator '
              'decision or a site-visit finding will appear here with its '
              'server timestamp.',
        )
      else
        div(classes: 'swpm-activity-list', [
          for (final event in _activity) _activityRow(event),
        ]),
      div(classes: 'swpm-notebox', [
        input(
          attributes: {
            'type': 'text',
            'maxlength': '240',
            'placeholder': 'Record a follow-up or required check',
            'aria-label': 'New internal note',
            'value': _noteText,
            if (_noteError != null) 'aria-invalid': 'true',
          },
          events: events<String>(
            // setState is required: the Add-note button is disabled while the
            // field is empty, so the rebuild is what enables it.
            onInput: (v) => setState(() {
              _noteText = v;
              _noteError = null;
            }),
          ),
        ),
        ActionButton(
          _savingNote ? 'Saving…' : 'Add note',
          onClick: _savingNote || _noteText.trim().isEmpty
              ? null
              : () => unawaited(_addNote()),
          variant: 'secondary',
        ),
        if (_noteError != null)
          p(classes: 'swpm-sub', [Component.text(_noteError!)]),
      ]),
    ]);
  }

  Component _activityRow(AgentActivityEvent event) {
    final tone = switch (event.action) {
      'approve' || 'approved' => 'success',
      'reject' || 'rejected' => 'danger',
      'changes_requested' => 'warning',
      'review_requested' => 'action',
      _ => 'neutral',
    };
    return div(classes: 'swpm-activity', [
      div(classes: 'swpm-activity-head', [
        strong([Component.text(event.label)]),
        StatusBadge(
          event.source == 'verification'
              ? 'Verification finding'
              : 'Change request',
          tone: tone,
        ),
      ]),
      small([
        Component.text(
          event.createdAt.isEmpty
              ? 'No server timestamp'
              : _shortDate(event.createdAt),
        ),
      ]),
      if (event.note != null && event.note!.isNotEmpty)
        p([Component.text(event.note!)]),
      span(classes: 'swpm-actor', [
        Component.text('Actor ${event.actorId.isEmpty ? '—' : event.actorId}'),
      ]),
    ]);
  }

  static String _shortDate(String? iso) {
    if (iso == null || iso.isEmpty) return '—';
    final parsed = DateTime.tryParse(iso);
    if (parsed == null) return iso;
    final local = parsed.toLocal();
    final m = '${local.month}'.padLeft(2, '0');
    final d = '${local.day}'.padLeft(2, '0');
    final hh = '${local.hour}'.padLeft(2, '0');
    final mm = '${local.minute}'.padLeft(2, '0');
    return '${local.year}-$m-$d $hh:$mm';
  }

  // --- Tab: admin review ------------------------------------------------------------

  Component _adminReviewTab(AgentListingFacts facts) {
    final open = _openRequest;
    return div(classes: 'stack stack--sections', [
      _sectionHead(
        'Administrator review',
        'Keep ownership verification, listing approval and publication '
            'separate. Only an authorized administrator can make a final '
            'decision.',
      ),
      div(classes: 'swpm-timeline', [
        _timelineStep(
          '1',
          'Initial submission',
          facts.verificationStatus.isEmpty
              ? 'No owner submission recorded'
              : 'Entrepreneur submission: ${facts.verificationStatus}',
          done: facts.verificationStatus == 'approved',
        ),
        _timelineStep(
          '2',
          'Listing verification',
          _statusLabel(facts),
          done: facts.verificationStatus == 'approved',
        ),
        _timelineStep(
          '3',
          'Agent change request',
          open == null ? 'No open change request' : 'Request ${open.status}',
          done: open?.status == 'approved',
        ),
        _timelineStep(
          '4',
          'Publication',
          facts.isPublished ? 'Published' : 'Not published',
          done: facts.isPublished,
        ),
      ]),
      div(classes: 'swpm-explain', [
        strong([Component.text('New Entrepreneur listings: ')]),
        Component.text(
          'enter the administrator review queue automatically on submission '
          'and stay unpublished. ',
        ),
        strong([Component.text('Agent edits: ')]),
        Component.text(
          'are saved as proposed changes and submitted for review; approved '
          'changes become effective under server policy. Publication is '
          'never changed by an agent action.',
        ),
      ]),
      if (facts.rejectionReason != null &&
          facts.rejectionReason!.trim().isNotEmpty)
        Callout(
          'Administrator note on this listing: ${facts.rejectionReason}',
          tone: 'warning',
          icon: 'campaign',
        ),
      if (_latestNegativeDecision != null)
        Callout(
          _negativeDecisionText(_latestNegativeDecision!),
          tone: _latestNegativeDecision!.status ==
                  AgentChangeRequest.statusRejected
              ? 'danger'
              : 'warning',
          icon: 'history',
        ),
      h4(classes: 'swpm-h4', [Component.text('Original vs proposed values')]),
      _diffTable(open),
      h4(classes: 'swpm-h4', [Component.text('Submission history')]),
      _historyList(),
    ]);
  }

  /// The newest decision that sent the work back to the agent. ``_history`` is
  /// newest-first, so the first rejected / changes-requested entry is the one
  /// the agent must act on.
  AgentChangeRequest? get _latestNegativeDecision {
    for (final request in _history) {
      if (request.status == AgentChangeRequest.statusRejected ||
          request.status == AgentChangeRequest.statusChangesRequested) {
        return request;
      }
    }
    return null;
  }

  static String _negativeDecisionText(AgentChangeRequest request) {
    final reason = request.reviewNote?.trim();
    final verdict = request.status == AgentChangeRequest.statusRejected
        ? 'rejected'
        : 'sent back for changes';
    return reason == null || reason.isEmpty
        ? 'Your last change request was $verdict. Revise the fields and submit '
              'again.'
        : 'Your last change request was $verdict: “$reason”. Revise the fields '
              'and submit again.';
  }

  Component _diffTable(AgentChangeRequest? open) {
    if (open == null) {
      return p(classes: 'swpm-sub', [
        Component.text(
          'No open change request. Edit a field in Listing details and save '
          'the draft to build a proposal.',
        ),
      ]);
    }
    if (open.changes.isEmpty) {
      return p(classes: 'swpm-sub', [
        Component.text('The open request carries no field differences.'),
      ]);
    }
    String display(dynamic value) {
      if (value == null) return '—';
      if (value is bool) return value ? 'Yes' : 'No';
      if (value is num) {
        final d = value.toDouble();
        return d.round() == d ? '${d.round()}' : '$d';
      }
      final s = '$value';
      return s.isEmpty ? '—' : s;
    }

    String fieldLabel(String key) => switch (key) {
      'name' => 'Property title',
      'rental_price' => 'Monthly rental (RM)',
      'size_sqft' => 'Built-up area (sqft)',
      'property_type' => 'Property type',
      'floor_level' => 'Floor level',
      'availability' => 'Availability',
      'description' => 'Description',
      'has_parking' => 'Parking',
      'is_fnb_suitable' => 'F&B suitable flag',
      _ => key,
    };

    return div(classes: 'swpm-tablewrap', [
      table(classes: 'swpm-table', [
        thead([
          tr([
            th([Component.text('Field')]),
            th([Component.text('Current approved value')]),
            th([Component.text('Proposed value')]),
          ]),
        ]),
        tbody([
          for (final entry in open.changes.entries)
            tr([
              td([Component.text(fieldLabel(entry.key))]),
              td([Component.text(display(entry.value['from']))]),
              td(classes: 'swpm-proposed', [
                Component.text(display(entry.value['to'])),
              ]),
            ]),
        ]),
      ]),
    ]);
  }

  Component _historyList() {
    if (!_historyLoaded) {
      return div(classes: 'loading', [
        span(classes: 'spinner', []),
        Component.text('Loading history…'),
      ]);
    }
    if (_history.isEmpty) {
      return p(classes: 'swpm-sub', [
        Component.text(
          'No change requests have been recorded for this listing.',
        ),
      ]);
    }
    return div(classes: 'swpm-activity-list', [
      for (final request in _history)
        div(classes: 'swpm-activity', [
          div(classes: 'swpm-activity-head', [
            strong([
              Component.text(
                'Change request · ${_shortDate(request.createdAt)}',
              ),
            ]),
            StatusBadge(
              _statusText(request.status),
              tone: _statusTone(request.status),
            ),
          ]),
          if (request.reason != null && request.reason!.isNotEmpty)
            p([Component.text(request.reason!)]),
          if (request.reviewNote != null && request.reviewNote!.isNotEmpty)
            p(classes: 'swpm-review-note', [
              Component.text('Administrator: ${request.reviewNote}'),
            ]),
          span(classes: 'swpm-actor', [
            Component.text('${request.changes.length} field(s) proposed'),
          ]),
        ]),
    ]);
  }

  static String _statusText(String status) => switch (status) {
    'draft' => 'Draft',
    'pending' => 'Pending review',
    'approved' => 'Approved',
    'rejected' => 'Rejected',
    'changes_requested' => 'Changes requested',
    _ => status,
  };

  static String _statusTone(String status) => switch (status) {
    'approved' => 'success',
    'rejected' => 'danger',
    'pending' || 'changes_requested' => 'warning',
    _ => 'neutral',
  };

  // --- Side stack ----------------------------------------------------------------

  Component _sideStack(AgentListingFacts facts) {
    return div(classes: 'swpm-sidestack', [
      div(classes: 'swpm-card', [
        h2(classes: 'swpm-h2', [Component.text('How review works')]),
        p(classes: 'swpm-sub', [
          Component.text(
            'Protecting the property owner and published listing.',
          ),
        ]),
        div(classes: 'swpm-process', [
          _processStep(
            '01',
            'Entrepreneur submits',
            'A new property enters pending review automatically, unpublished.',
          ),
          _processStep(
            '02',
            'Agent proposes changes',
            'Authorized edits are saved as a server draft, separate from '
                'public listing data.',
          ),
          _processStep(
            '03',
            'Admin decides',
            'Review ownership and listing evidence, approve, reject or '
                'request correction.',
          ),
          _processStep(
            '04',
            'Publication eligibility',
            'Only approved changes may become visible, subject to '
                'publication controls.',
          ),
        ]),
      ]),
      _readinessCard(facts),
    ]);
  }

  Component _readinessCard(AgentListingFacts facts) {
    final checks = <(String, bool)>[
      ('Property title recorded', facts.name.trim().isNotEmpty),
      (
        'Rental price recorded',
        facts.rentalPrice != null && facts.rentalPrice! > 0,
      ),
      ('Built-up area recorded', facts.sizeSqft != null && facts.sizeSqft! > 0),
      ('Property type recorded', (facts.propertyType ?? '').trim().isNotEmpty),
      ('Availability set', (facts.availability ?? '').trim().isNotEmpty),
      ('Description present', (facts.description ?? '').trim().length >= 30),
      ('At least one photo', _detail?.photos.isNotEmpty ?? false),
      ('Administrator verified', facts.verificationStatus == 'approved'),
    ];
    final complete =
        ((checks.where((check) => check.$2).length / checks.length) * 100)
            .round();
    return div(classes: 'swpm-card', [
      h2(classes: 'swpm-h2', [Component.text('Listing readiness')]),
      p(classes: 'swpm-sub', [
        Component.text('Completeness is a form check, not an approval.'),
      ]),
      div(classes: 'swpm-completion', [
        span(
          styles: Styles(raw: {'width': '$complete%'}),
          attributes: {'aria-hidden': 'true'},
          [],
        ),
      ]),
      div(classes: 'swpm-stats', [
        _stateRow('Completeness', '$complete%'),
        _stateRow('Draft state', _dirty ? 'Unsaved changes' : 'Saved'),
        _stateRow('Owner and licence evidence', 'Requires verification'),
      ]),
      p(classes: 'swpm-side-tip', [
        Component.text(
          'Verification, F&B planning permission and owner authorization '
          'are checked independently. Missing evidence is never interpreted '
          'as approved.',
        ),
      ]),
    ]);
  }

  static Component _processStep(String num, String title, String body) =>
      div(classes: 'swpm-process-row', [
        span(classes: 'swpm-process-num', [Component.text(num)]),
        div([
          strong([Component.text(title)]),
          p([Component.text(body)]),
        ]),
      ]);

  static Component _timelineStep(
    String num,
    String title,
    String body, {
    required bool done,
  }) =>
      div(classes: done ? 'swpm-tl-step swpm-tl-step--done' : 'swpm-tl-step', [
        span(classes: 'swpm-tl-num', [Component.text(num)]),
        div([
          strong([Component.text(title)]),
          p([Component.text(body)]),
        ]),
      ]);

  // --- Dialogs -----------------------------------------------------------------

  Component _previewDialog(AgentListingFacts facts) {
    return SitewiseDialog(
      title: facts.name,
      ariaLabel: 'Read-only listing preview',
      onClose: () => setState(() => _previewOpen = false),
      body: div(classes: 'stack', [
        p(classes: 'sub', [Component.text(facts.addressDisplay)]),
        div(classes: 'swpm-tiles', [
          _tile(
            'Asking rent',
            facts.rentalDisplay.isEmpty
                ? 'Not recorded'
                : '${facts.rentalDisplay}/month',
          ),
          _tile(
            'Floor area',
            facts.areaDisplay.isEmpty ? 'Not recorded' : facts.areaDisplay,
          ),
          _tile('Availability', _availabilityLabel(_draft['availability'])),
          _tile('Verification', _statusLabel(facts)),
        ]),
        p(classes: 'body', [
          Component.text(
            (_draft['description'] ?? '').isEmpty
                ? 'No description recorded.'
                : _draft['description']!,
          ),
        ]),
        Callout(
          'This preview shows the current draft values. Publication is not '
          'changed by previewing.',
          tone: 'info',
          icon: 'info',
        ),
      ]),
      actions: [
        ActionButton(
          'Close preview',
          onClick: () => setState(() => _previewOpen = false),
          variant: 'secondary',
        ),
      ],
    );
  }

  Component _reviewDialog() {
    return SitewiseDialog(
      title: 'Request administrator review',
      ariaLabel: 'Request administrator review',
      onClose: () => setState(() => _reviewDialogOpen = false),
      body: div(classes: 'stack', [
        p(classes: 'body muted', [
          Component.text(
            'Submits the saved draft proposal for '
            '${_facts?.name ?? "this listing"} to an authorized '
            'administrator. The request is only confirmed once the backend '
            'persists it.',
          ),
        ]),
        if (_hasPending)
          Callout(
            'This listing already has a request awaiting review — duplicate '
            'submissions are refused.',
            tone: 'warning',
            icon: 'hourglass_top',
          ),
        if (_dirty)
          Callout(
            'You have unsaved edits. Save the draft first; a review request '
            'submits the saved proposal only.',
            tone: 'warning',
            icon: 'error',
          ),
        Field(
          labelText: 'Why should an administrator review this change?',
          hint:
              'Describe the change and what evidence needs checking '
              '(min 12 characters).',
          error: _reviewError,
          child: textarea(
            attributes: {'maxlength': '500', 'rows': '4'},
            events: events<String>(
              onInput: (v) => setState(() => _reviewReason = v),
            ),
            [Component.text(_reviewReason)],
          ),
        ),
      ]),
      actions: [
        ActionButton(
          'Cancel',
          onClick: () => setState(() => _reviewDialogOpen = false),
          variant: 'secondary',
        ),
        ActionButton(
          _submittingReview ? 'Submitting…' : 'Submit request',
          onClick: _submittingReview || _dirty || _hasPending
              ? null
              : () => unawaited(_submitReview()),
          variant: 'primary',
        ),
      ],
    );
  }
}

/// One listing's unsaved editor state, held for the browser session.
final class _UnsavedDraft {
  const _UnsavedDraft({
    required this.fields,
    required this.parking,
    required this.fnb,
  });

  final Map<String, String> fields;
  final bool parking;
  final bool fnb;
}

/// In-memory buffer of unsaved agent edits, keyed by listing id.
///
/// The persisted draft lives on the server (written by "Save draft"); this
/// store only covers values typed but not yet saved, so switching listings or
/// leaving the page for My Properties and coming back restores them. It is
/// cleared on a successful save, on discard, and when the session ends.
abstract final class _UnsavedDraftStore {
  static final Map<int, _UnsavedDraft> _entries = <int, _UnsavedDraft>{};

  static _UnsavedDraft? read(int listingId) => _entries[listingId];

  static void write(int listingId, _UnsavedDraft draft) {
    _entries[listingId] = draft;
  }

  static void clear(int listingId) {
    _entries.remove(listingId);
  }
}
