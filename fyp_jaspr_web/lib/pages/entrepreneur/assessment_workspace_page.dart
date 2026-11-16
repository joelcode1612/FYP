import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/assessment_journey_stepper.dart';
import '../../components/dashboard_kit.dart' show SitewiseDialog;
import '../../components/ui.dart';
import '../../data/app_locator.dart';
import '../../data/assessment_api.dart';
import '../../data/dev_auth_bypass.dart';

/// The web decision-support workflow, in five persisted stages.
///
/// ```text
/// .crumbs        Explore / Recommendations / Saved › Workspace
/// .asw-progress  N of 5 stages · current stage · bar
/// .asw-grid
///   main   .asw-stages   one card per stage (number, title, description,
///                        status, action) + the open stage's panel
///   aside  selected property · next action · capability verdicts
/// ```
///
/// Nothing here decides progress locally. Stage status, `current_stage`,
/// `progress_percent` and the next action all come from the persisted record
/// the backend derives from its stage timestamps and a runtime capability
/// probe, so a stage can only read as complete when a row says so.
///
/// **Platform separation.** This page is the Jaspr web decision-support
/// workflow: select property → business requirements → location evidence →
/// AI recommendation explanation → assessment report. The Flutter mobile
/// assessment is a data-collection workflow (assess → setup → evidence →
/// submit/save) with its own session store; it does not read or write the
/// `/api/v1/assessments` record and this page is not reachable from mobile
/// navigation.
@client
class AssessmentWorkspacePage extends StatefulComponent {
  /// The catalogue property id from `?id=` (e.g. `EP-01051`). The same
  /// identifier Explore, Property detail and Saved already use.
  final String propertyId;

  /// Optional `?stage=` deep link into one of the two in-page stage panels.
  final String stage;

  /// Optional `?businessType=` selection carried from Recommendations.
  ///
  /// Used ONLY to seed a draft when the assessment has no saved requirements
  /// yet. An existing saved requirement is never overwritten: the entrepreneur's
  /// recorded answer stays authoritative.
  final String businessType;

  const AssessmentWorkspacePage({
    super.key,
    required this.propertyId,
    this.stage = '',
    this.businessType = '',
  });

  @override
  State<AssessmentWorkspacePage> createState() => _AssessmentWorkspaceState();
}

class _AssessmentWorkspaceState extends State<AssessmentWorkspacePage> {
  static const _api = AssessmentApi();

  /// The two stages whose body lives inside the workspace. The other three
  /// hand over to pages that already exist.
  static const _inlineStages = {'business_requirements', 'location_evidence'};

  /// All five checkpoint keys — every stage opens its own independent
  /// checkpoint view (the mockup's step1…step5 sections), navigated by the
  /// journey stepper.
  static const _stageKeys = {
    'select_property',
    'business_requirements',
    'location_evidence',
    'ai_explanation',
    'assessment_report',
  };

  late Future<_Load> _future = _open(component.propertyId);

  /// Which in-page stage panel is expanded. Seeded from `?stage=` in
  /// [initState] so a shared link lands on the panel it names.
  String? _openStage;

  /// Which checkpoint view is on screen — one of [_stageKeys]. Null falls
  /// back to the record's own current stage. Each checkpoint is independent:
  /// the workspace renders exactly one at a time.
  String? _checkpoint;

  /// Step 1's saved-property search query.
  String _propSearch = '';

  /// Step 3's evidence filter: `all` | `measured` | `missing`.
  String _evidenceFilter = 'all';

  /// Step 3's evidence search query.
  String _evidenceSearch = '';

  /// Step 4's persisted SHAP explanation read, cached per open record.
  Future<ApiResult<ResearchExplanation?>>? _explanationFuture;

  /// The property whose assessment is open as an in-place detail view. Set by
  /// the listing's row actions so the workspace content swaps in WITHOUT a
  /// page navigation (the report tab's gate→content behaviour, and the
  /// mockup's showDetail/back pattern). A `?id=` deep link always wins.
  String? _openPropertyId;

  /// The property the workspace flow is bound to: the URL's `?id=` when
  /// present, otherwise the in-place selection from the listing.
  String get _activePropertyId =>
      component.propertyId.isNotEmpty ? component.propertyId : (_openPropertyId ?? '');

  /// True when the workspace was opened in place from the listing (no `?id=`
  /// in the URL), so a back-to-assessments control is offered.
  bool get _openedInPlace =>
      component.propertyId.isEmpty && _openPropertyId != null;

  bool _busy = false;
  String? _notice;
  AssessmentFailure? _writeError;

  /// The record the last successful read or write returned. Kept so the
  /// requirements form can seed itself from what is actually persisted.
  AssessmentRecord? _record;

  /// Stage 2 form values. Numbers stay as text so an emptied field is visibly
  /// empty and invalid — never silently coerced to zero.
  _RequirementsDraft? _draft;
  Map<String, String> _draftErrors = const {};

  Future<List<String>>? _typesFuture;
  Future<ApiResult<EvidencePayload>>? _evidenceFuture;

  // --- Assessments listing (the tab's default view) -------------------------
  //
  // The listing is the workspace's entry state: the entrepreneur's real
  // assessment records from the authenticated history endpoint, filterable by
  // status and searchable by property. Records are opened (in-progress rows
  // deep-link straight to the questionnaire) or deleted — never created from
  // this page; starting an assessment happens through the workspace's own
  // `?id=` entry points on a saved property.

  /// The account's assessment records. A failed read renders the failure
  /// state — the listing never invents rows.
  Future<ApiResult<AssessmentHistory>>? _historyFuture;

  /// `all` | `in-progress` | `completed` — the listing's status filter.
  String _listFilter = 'all';

  /// The listing's free-text search over property and assessment identity.
  String _listSearch = '';

  // --- Create-assessment dialog ---------------------------------------------

  /// Whether the create dialog is open. Opening it lazy-loads the account's
  /// saved properties exactly once.
  bool _createOpen = false;

  /// The saved properties, resolved against the catalogue. Null until the
  /// first read completes.
  Future<AssessmentSelectableProperties>? _selectableFuture;

  /// The dialog's search query.
  String _dialogSearch = '';

  /// The catalogue refs the entrepreneur selected in the dialog, in selection
  /// order.
  ///
  /// Up to three properties may be chosen, but each still gets its OWN
  /// independent assessment record: the backend's create-or-resume contract is
  /// per property (one `property_id` per assessment row) and there is no
  /// combined multi-property prediction or report, so this list never becomes
  /// a single batched record.
  static const int _maxSelections = 3;
  final List<String> _selectedRefs = <String>[];

  /// True while the per-property create requests are in flight.
  bool _creating = false;

  /// The dialog's own failure text — per-property refusals, verbatim.
  String? _dialogError;

  // --- Delete-assessment dialog ----------------------------------------------

  /// The record whose deletion is awaiting confirmation, or null.
  AssessmentRecord? _deleteTarget;

  /// True while the delete request is in flight.
  bool _deleting = false;

  /// The dialog's own failure text — the backend's refusal, verbatim.
  String? _deleteError;

  @override
  void initState() {
    super.initState();
    if (_inlineStages.contains(component.stage)) _openStage = component.stage;
    if (_stageKeys.contains(component.stage)) _checkpoint = component.stage;
    if (_openStage == 'location_evidence' && component.propertyId.isNotEmpty) {
      _evidenceFuture = _api.evidence(component.propertyId);
    }
  }

  /// Re-runs the load when the route changes the property.
  ///
  /// The router reuses the same element for the same route, so a query-only
  /// change (Stage 1 → `/entrepreneur/assessments?id=…`) arrives here rather
  /// than as a fresh state. Without this the workspace would keep showing the
  /// previous property's record.
  @override
  void didUpdateComponent(covariant AssessmentWorkspacePage oldComponent) {
    super.didUpdateComponent(oldComponent);
    if (oldComponent.propertyId == component.propertyId) return;
    _openStage =
        _inlineStages.contains(component.stage) ? component.stage : null;
    _checkpoint =
        _stageKeys.contains(component.stage) ? component.stage : null;
    _record = null;
    _draft = null;
    _draftErrors = const {};
    _typesFuture = null;
    _evidenceFuture = null;
    _explanationFuture = null;
    _propSearch = '';
    _evidenceFilter = 'all';
    _evidenceSearch = '';
    _notice = null;
    _writeError = null;
    // Entering or leaving the listing view: its reads and dialog state are
    // rebuilt from scratch so a stale record never survives the round trip.
    _historyFuture = null;
    _listFilter = 'all';
    _listSearch = '';
    _createOpen = false;
    _dialogSearch = '';
    _selectedRefs.clear();
    _dialogError = null;
    _selectableFuture = null;
    _deleteTarget = null;
    _deleteError = null;
    // A route change (including leaving a `?id=` URL) always wins over any
    // in-place selection.
    _openPropertyId = null;
    _future = _open(component.propertyId);
  }

  // ------------------------------------------------------------------- load

  /// Reads the persisted record without creating one. A page view must not
  /// start an assessment: the entrepreneur decides that with the Start button.
  static Future<_Load> _open(String propertyId) async {
    final result = await _api.byProperty(propertyId);
    if (!result.ok) return _Failed(result.failure!);
    final record = result.value;
    if (record != null) return _Started(record);

    // No record yet. Identify the listing anyway so the start screen says what
    // it is about to assess, through the same catalogue read Explore uses.
    final property = await _api.property(propertyId);
    return _NotStarted(
      propertyId: propertyId,
      property: property.ok ? property.value : null,
      failure: property.ok ? null : property.failure,
    );
  }

  void _reload(String propertyId) => setState(() {
    _notice = null;
    _writeError = null;
    _draft = null;
    _future = _open(propertyId);
  });

  /// Opens an assessment IN PLACE from the listing row (user request: row
  /// clicks must swap this page's content, not navigate — the report tab's
  /// gate→content behaviour and the mockup's showDetail/back pattern).
  /// `?id=` deep links keep working through the normal route flow.
  void _openAssessment(String propertyId, {String? stage}) => setState(() {
    _openPropertyId = propertyId;
    _checkpoint = _stageKeys.contains(stage) ? stage : null;
    _openStage = _inlineStages.contains(stage) ? stage : null;
    _record = null;
    _draft = null;
    _draftErrors = const {};
    _typesFuture = null;
    _evidenceFuture = null;
    _explanationFuture = null;
    _propSearch = '';
    _evidenceFilter = 'all';
    _evidenceSearch = '';
    _notice = null;
    _writeError = null;
    _busy = false;
    if (_openStage == 'location_evidence') {
      _evidenceFuture = _api.evidence(propertyId);
    }
    _future = _open(propertyId);
  });

  /// Returns from the in-place workspace to the listing without a route
  /// change — the mockup's back-to-list control. The listing is re-read so a
  /// record changed in the workspace shows its new state.
  void _closeAssessment() => setState(() {
    _openPropertyId = null;
    _checkpoint = null;
    _openStage = null;
    _record = null;
    _draft = null;
    _draftErrors = const {};
    _typesFuture = null;
    _evidenceFuture = null;
    _explanationFuture = null;
    _propSearch = '';
    _evidenceFilter = 'all';
    _evidenceSearch = '';
    _notice = null;
    _writeError = null;
    _busy = false;
    _historyFuture = _loadListing();
  });

  Future<List<String>> _types() {
    final existing = _typesFuture;
    if (existing != null) return existing;
    // A failed lookup yields no options, and the form then says the list is
    // unavailable rather than offering values that may match nothing.
    final future = _api.propertyTypes().then(
      (result) => result.ok ? result.value! : const <String>[],
    );
    _typesFuture = future;
    return future;
  }

  Future<ApiResult<EvidencePayload>> _evidence(String propertyId) =>
      _evidenceFuture ??= _api.evidence(propertyId);

  void _retryEvidence(String propertyId) =>
      setState(() => _evidenceFuture = _api.evidence(propertyId));

  // ------------------------------------------------------------------ writes

  /// Creates the record. The backend resumes an existing one instead of
  /// duplicating it, so this is safe from every entry point.
  Future<void> _start(String propertyId) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _writeError = null;
      _notice = null;
    });
    final result = await _api.start(propertyId);
    if (!mounted) return;
    if (!result.ok) {
      setState(() {
        _busy = false;
        _writeError = result.failure;
      });
      return;
    }
    final started = result.value!;
    setState(() {
      _busy = false;
      _record = started.assessment;
      _future = Future.value(_Started(started.assessment));
      _notice = started.created
          ? 'Assessment started. Stage 1 is recorded as complete because '
                'the property is now bound to it.'
          : 'Your existing assessment for this property was reopened. '
                'Nothing was duplicated.';
    });
  }

  /// Asks the backend to record a stage as complete. The server refuses with
  /// 409 when the stage's own precondition is unmet, and that refusal is
  /// shown verbatim — progress is never marked up locally.
  Future<void> _completeStage(AssessmentRecord record, String stageKey) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _writeError = null;
      _notice = null;
    });
    final result = await _api.completeStage(record.assessmentId, stageKey);
    if (!mounted) return;
    if (!result.ok) {
      setState(() {
        _busy = false;
        _writeError = result.failure;
      });
      return;
    }
    final updated = result.value!;
    final stage = updated.stageByKey(stageKey);
    setState(() {
      _busy = false;
      _record = updated;
      _future = Future.value(_Started(updated));
      _notice = stage == null
          ? 'The assessment was updated.'
          : 'Stage ${stage.number} — ${stage.title} is now recorded as '
                'complete. ${updated.completedStages} of '
                '${updated.totalStages} stages done.';
    });
  }

  /// Validates locally (the same rules the server enforces, so the message
  /// arrives before a round trip), then asks the backend to confirm stage 2.
  ///
  /// The requirements themselves are no longer written from the web workspace:
  /// stage 2 is the M2 questionnaire preview and nothing here persists
  /// answers. Completion is decided by the backend — the PATCH refuses with
  /// 409 when the stage's own precondition is not met, so the client cannot
  /// fake progress.
  Future<void> _saveRequirements(AssessmentRecord record) async {
    if (_busy) return;
    final draft = _draft;
    if (draft == null) return;

    final errors = draft.validate();
    if (errors.isNotEmpty) {
      setState(() {
        _draftErrors = errors;
        _writeError = null;
        _notice = null;
      });
      return;
    }

    setState(() {
      _busy = true;
      _draftErrors = const {};
      _writeError = null;
      _notice = null;
    });
    final result = await _api.completeStage(
      record.assessmentId,
      'business_requirements',
    );
    if (!mounted) return;
    if (!result.ok) {
      // Values preserved: the entrepreneur re-reads the server's objection
      // against what they actually typed, not an emptied form.
      setState(() {
        _busy = false;
        _writeError = result.failure;
      });
      return;
    }
    final updated = result.value!;
    _applyToSharedPreferences(updated);
    setState(() {
      _busy = false;
      _record = updated;
      _future = Future.value(_Started(updated));
      _notice = 'Stage 2 — Business preferences is recorded as complete. '
          '${updated.completedStages} of ${updated.totalStages} stages done.';
    });
  }

  /// Points the shared [BusinessPreferences] at the values just persisted, so
  /// the recommendation engine reads the same numbers the assessment stores.
  /// The mapping is [businessPreferencesFrom] — the same one the preferences
  /// page uses — so the two surfaces cannot drift into separate vocabularies.
  void _applyToSharedPreferences(AssessmentRecord record) {
    final value = businessPreferencesFrom(record.requirements);
    if (value == null) return;
    context
        .read(entrepreneurNotifierProvider.notifier)
        .updatePreferences(value);
    AppLocator.persistPreferences(value);
  }

  void _toggleStage(String key) => setState(() {
    _openStage = _openStage == key ? null : key;
    _notice = null;
    _writeError = null;
    if (_openStage == 'business_requirements') _seedDraft();
    if (_openStage == 'location_evidence') {
      _evidenceFuture ??= _api.evidence(_activePropertyId);
    }
  });

  /// Opens one independent checkpoint view. The journey stepper navigates
  /// between the five checkpoints; the workspace renders exactly one at a
  /// time, and an inline stage's panel expands with its checkpoint.
  void _openCheckpoint(String key) => setState(() {
    _checkpoint = key;
    _notice = null;
    _writeError = null;
    if (_inlineStages.contains(key)) {
      _openStage = key;
      if (key == 'business_requirements') _seedDraft();
      if (key == 'location_evidence') {
        _evidenceFuture ??= _api.evidence(_activePropertyId);
      }
    } else {
      _openStage = null;
    }
  });

  /// Builds the form from the persisted requirements, or from the shared
  /// preferences when the assessment has none yet — so the first save starts
  /// from the criteria the ranking already uses.
  void _seedDraft() {
    if (_draft != null) return;
    final stored = _record?.requirements;
    if (stored != null) {
      _draft = _RequirementsDraft(
        businessType: stored['business_type'] as String? ?? '',
        propertyType: stored['property_type'] as String? ?? '',
        targetMarket: _firstText(stored['requirements']),
        seatingModel: stored['seating_model'] as String? ?? '',
        minBudget: _text(stored['min_budget_rm']),
        maxBudget: _text(stored['max_budget_rm']),
        minSize: _text(stored['min_size_sqft']),
        maxSize: _text(stored['max_size_sqft']),
        preferredAreas: _textList(stored['preferred_areas']),
      );
      return;
    }
    final prefs = AppLocator.preferences;
    // The recommendation the entrepreneur arrived from carries their own
    // business type; prefer it over the shared preference, but never over an
    // already-saved assessment requirement (handled above).
    final carried = component.businessType.trim();
    _draft = _RequirementsDraft(
      businessType: carried.isNotEmpty ? carried : prefs.businessType,
      propertyType: prefs.propertyType,
      targetMarket: prefs.requirements.isEmpty ? '' : prefs.requirements.first,
      seatingModel: prefs.seatingModel,
      minBudget: _text(prefs.minBudgetRm),
      maxBudget: _text(prefs.maxBudgetRm),
      minSize: _text(prefs.minSizeSqft),
      maxSize: prefs.maxSizeSqft.isFinite ? _text(prefs.maxSizeSqft) : '',
      preferredAreas: prefs.preferredAreas,
    );
  }

  static String _text(Object? value) =>
      value is num ? value.toStringAsFixed(0) : '';

  static List<String> _textList(Object? value) => [
    if (value is List)
      for (final item in value) '$item',
  ];

  static String _firstText(Object? value) {
    final items = _textList(value);
    return items.isEmpty ? '' : items.first;
  }

  // ----------------------------------------------------------------- listing

  /// The account's assessments, from the authenticated history endpoint. The
  /// same read the report directory and assessment history use.
  Future<ApiResult<AssessmentHistory>> _loadListing() => _api.history(limit: 50);

  void _reloadListing() => setState(() {
    _historyFuture = _loadListing();
    _notice = null;
    _writeError = null;
  });

  // ------------------------------------------------------------ create dialog

  /// Opens the dialog and lazy-loads the saved list once.
  void _openCreate() => setState(() {
    _createOpen = true;
    _dialogSearch = '';
    _selectedRefs.clear();
    _dialogError = null;
    _selectableFuture ??= AppLocator.assessmentSelectableProperties.call();
  });

  void _closeCreate() => setState(() {
    if (_creating) return;
    _createOpen = false;
    _dialogError = null;
  });

  /// Toggles one saved property in the dialog's shortlist.
  ///
  /// A property whose details could not be resolved never reaches this
  /// method (its checkbox is disabled), duplicates are impossible because the
  /// toggle checks membership first, and a fourth property cannot be added.
  void _toggleDialogSelection(String propertyRef) => setState(() {
    if (_selectedRefs.contains(propertyRef)) {
      _selectedRefs.remove(propertyRef);
      _dialogError = null;
    } else if (_selectedRefs.length < _maxSelections) {
      _selectedRefs.add(propertyRef);
      _dialogError = null;
    }
  });

  /// Creates — or resumes — one independent assessment per selected property.
  ///
  /// The backend's create-or-resume contract is per property (one
  /// `property_id` per assessment row), so each selection is one POST and the
  /// requests run sequentially on purpose: each is an independent server
  /// transaction that checks the catalogue and the account's saved list, and
  /// refuses a property the account has not saved. A per-property refusal
  /// never aborts the other selections.
  Future<void> _createSelected() async {
    if (_creating || _selectedRefs.isEmpty) return;
    setState(() {
      _creating = true;
      _dialogError = null;
    });

    var created = 0;
    var resumed = 0;
    final failures = <String>[];
    for (final ref in _selectedRefs) {
      final started = await _api.start(ref);
      if (!mounted) return;
      if (!started.ok) {
        failures.add('Property $ref — ${started.failure!.message}');
        continue;
      }
      started.value!.created ? created++ : resumed++;
    }

    if (!mounted) return;
    final ready = created + resumed;
    setState(() {
      _creating = false;
      _historyFuture = _loadListing();
      if (failures.isNotEmpty) {
        // The dialog stays open so each refusal is visible against the
        // selection that caused it. Everything that did succeed is already
        // reflected in the re-read listing.
        _dialogError = [
          if (ready > 0)
            '$ready assessment${ready == 1 ? '' : 's'} started, but:',
          ...failures,
        ].join(' ');
        return;
      }
      _createOpen = false;
      _selectedRefs.clear();
      _notice = created == 0
          ? '$resumed assessment${resumed == 1 ? '' : 's'} reopened — nothing '
                'was duplicated. Open each property from the list below.'
          : '$ready assessment${ready == 1 ? '' : 's'} ready: $created new, '
                '$resumed reopened. Open each property from the list below — '
                'the assessments are independent.';
    });
  }

  // ------------------------------------------------------------ delete dialog

  /// Opens the confirmation dialog for one record.
  void _openDelete(AssessmentRecord record) => setState(() {
    if (_deleting) return;
    _deleteTarget = record;
    _deleteError = null;
  });

  void _closeDelete() => setState(() {
    if (_deleting) return;
    _deleteTarget = null;
    _deleteError = null;
  });

  /// Deletes the confirmed record. The backend enforces ownership (404
  /// unknown, 403 foreign), so the dialog only ever succeeds for a record the
  /// listing itself served. A refusal keeps the dialog open with the reason.
  Future<void> _deleteConfirmed() async {
    final target = _deleteTarget;
    if (target == null || _deleting) return;
    setState(() {
      _deleting = true;
      _deleteError = null;
    });
    final result = await _api.deleteAssessment(target.assessmentId);
    if (!mounted) return;
    setState(() {
      _deleting = false;
      if (!result.ok) {
        _deleteError =
            '${result.failure!.message} The assessment was not deleted.';
        return;
      }
      _deleteTarget = null;
      _historyFuture = _loadListing();
      _notice =
          'The assessment for '
          '${target.property?.title ?? 'Property ${target.propertyId}'} '
          'was deleted.';
    });
  }



  // ------------------------------------------------------------------ render

  @override
  Component build(BuildContext context) {
    if (_activePropertyId.isEmpty) {
      return _listing();
    }

    return FutureBuilder<_Load>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return _shell(
            title: 'Location assessment',
            subtitle: 'Loading the assessment for this property…',
            child: const div(classes: 'asw-grid', [
              div(classes: 'stack stack--md', [
                Skeleton(variant: 'block'),
                Skeleton(variant: 'row', count: 5),
              ]),
              div(classes: 'stack stack--md', [
                Skeleton(variant: 'block'),
                Skeleton(variant: 'block'),
              ]),
            ]),
          );
        }

        final load = snapshot.data;
        if (load == null) {
          return _shell(
            title: 'Location assessment',
            child: EmptyState(
              title: 'The assessment could not be loaded',
              body:
                  'The workspace received no response for this property. Try '
                  'again — nothing has been changed.',
              action: ActionButton(
                'Try again',
                onClick: () => _reload(_activePropertyId),
              ),
            ),
          );
        }

        return switch (load) {
          _Started(:final record) => _workspace(record),
          _NotStarted(:final propertyId, :final property, :final failure) =>
            _notStarted(propertyId, property, failure),
          _Failed(:final failure) => _failure(failure),
        };
      },
    );
  }

  /// Content-only page shell (user request: no sidebar, no pill nav).
  ///
  /// The design starts with the breadcrumb — "Home › Assessments › Customer
  /// questionnaire" — then the page head, then the existing workspace layout
  /// (journey stepper, progress, stage cards, aside). `.asw-page` carries the
  /// same width band and gutter as `.app-content__inner` so the page keeps the
  /// app's vertical grid without the `AppLayout` chrome around it.
  Component _shell({
    required String title,
    String? subtitle,
    List<Component> actions = const [],
    required Component child,
    String eyebrow = 'Assessment workspace',
    String? leaf,
  }) => div(classes: 'asw-page', [
    _crumbs(leaf: leaf),
    PageHead(
      title: title,
      eyebrow: eyebrow,
      description: subtitle,
      actions: actions,
    ),
    if (devAuthBypassEnabled)
      p(classes: 'panel', attributes: const {'role': 'status'}, [
        Component.text(
          'DEVELOPMENT TESTING · Authentication bypass active. Backend '
          'identity and ownership checks still apply. No production fielding '
          'or report authority is granted.',
        ),
      ]),
    child,
  ]);

  // --------------------------------------------------------------- listing UI

  /// The Assessments listing — the tab's default view.
  ///
  /// The entrepreneur's real assessment records in one table: a status filter,
  /// free-text search, per-record step progress and status, and one action
  /// into the workspace for the record's own `?id=` flow. Creating an
  /// assessment happens through the dialog, never by opening this page.
  Component _listing() {
    final history = _historyFuture ??= _loadListing();
    return _shell(
      title: 'Assessments',
      eyebrow: 'Entrepreneur workspace',
      subtitle:
          'Review your location assessments, pick up where you left off, or '
          'start a new one for a saved property.',
      actions: [
        ActionLink(
          'Assessment History',
          href: '/entrepreneur/assessments/history',
          variant: 'secondary',
        ),
        ActionButton(
          _creating ? 'Starting…' : 'New Assessment',
          icon: 'add',
          onClick: _creating ? null : _openCreate,
        ),
      ],
      child: div(classes: 'stack stack--sections', [
        FutureBuilder<ApiResult<AssessmentHistory>>(
          future: history,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return section(classes: 'panel', [
                div(classes: 'panel__head', [
                  span(classes: 'panel__title', [
                    Component.text('My assessments'),
                  ]),
                ]),
                div(classes: 'panel__body', [
                  const Skeleton(variant: 'row', count: 4),
                ]),
              ]);
            }
            final result = snapshot.data;
            if (result == null || !result.ok) {
              final failure = result?.failure;
              if (failure?.kind == AssessmentFailureKind.unauthorized) {
                return const EmptyState(
                  title: 'You are not signed in to this workspace',
                  body:
                      'Assessments belong to your account, so the service '
                      'will only return them to a signed-in entrepreneur.',
                  action: ActionLink(
                    'Go to sign in',
                    href: '/login',
                    variant: 'primary',
                  ),
                );
              }
              return EmptyState(
                title: 'Your assessments did not load',
                body:
                    failure?.message ??
                    'The listing received no response. Nothing has been '
                        'changed.',
                action: ActionButton('Try again', onClick: _reloadListing),
              );
            }
            return _listingPanel(result.value!);
          },
        ),

        if (_notice != null) _successNotice(_notice!),
        if (_writeError != null) _errorNotice(_writeError!),

        if (_createOpen) _createDialog(),
        if (_deleteTarget != null) _deleteDialog(),
      ]),
    );
  }

  /// The list panel: header row, filter tabs, search, then the table — or the
  /// empty / no-results states.
  Component _listingPanel(AssessmentHistory history) {
    final records = history.items;
    final total = records.length;
    final completedCount = records.where((record) => record.isCompleted).length;
    final inProgressCount = total - completedCount;

    final query = _listSearch.trim().toLowerCase();
    final visible = [
      for (final record in records)
        if ((_listFilter == 'all' ||
                (_listFilter == 'completed'
                    ? record.isCompleted
                    : !record.isCompleted)) &&
            (query.isEmpty ||
                [
                  record.propertyId,
                  record.assessmentId,
                  record.property?.title ?? '',
                  record.property?.city ?? '',
                  record.property?.state ?? '',
                ].join(' ').toLowerCase().contains(query)))
          record,
    ];

    return section(classes: 'panel panel--flush', [
      div(classes: 'panel__head', [
        div(classes: 'asw-list-head', [
          span(classes: 'panel__title', [Component.text('My assessments')]),
          span(classes: 'small asw-muted', [
            Component.text('All your assessment records in one place.'),
          ]),
        ]),
        span(
          classes: 'asw-list-count',
          attributes: const {'aria-live': 'polite'},
          [Component.text('$total assessment${total == 1 ? '' : 's'}')],
        ),
      ]),
      div(classes: 'asw-list-controls', [
        div(
          classes: 'tabs',
          attributes: const {
            'role': 'tablist',
            'aria-label': 'Filter assessments',
          },
          [
            _filterTab('all', 'All', total),
            _filterTab('in-progress', 'In progress', inProgressCount),
            _filterTab('completed', 'Completed', completedCount),
          ],
        ),
        SearchInput(
          label: 'Search',
          placeholder: 'Search assessments or properties',
          ariaLabel: 'Search assessments',
          onInput: (value) => setState(() => _listSearch = value),
        ),
      ]),
      if (visible.isNotEmpty)
        div(classes: 'table-scroll', [
          table(classes: 'audit-table', [
            thead([
              tr([
                th([Component.text('Assessment / property')]),
                th([Component.text('Current step')]),
                th([Component.text('Status')]),
                th([Component.text('Last updated')]),
                th([Component.text('Action')]),
              ]),
            ]),
            tbody([for (final record in visible) _listingRow(record)]),
          ]),
        ])
      else if (total == 0)
        div(classes: 'panel__body', [
          EmptyState(
            title: 'No assessments yet',
            body:
                'Your location assessments will appear here once you start '
                'one. Choose a property you want to evaluate.',
            action: ActionButton(
              'Create your first assessment',
              onClick: _openCreate,
            ),
          ),
        ])
      else
        div(classes: 'panel__body', [
          p(classes: 'body', [
            Component.text(
              'No assessments match your search or selected status.',
            ),
          ]),
        ]),
    ]);
  }

  /// One filter tab. The existing `.tabs` / `.tab` vocabulary, with the
  /// record count baked into the label.
  Component _filterTab(String value, String label, int count) => button(
    classes: 'tab${_listFilter == value ? ' is-active' : ''}',
    attributes: {
      'type': 'button',
      'role': 'tab',
      'aria-selected': (_listFilter == value).toString(),
    },
    events: events(onClick: () => setState(() => _listFilter = value)),
    [Component.text('$label ($count)')],
  );

  /// One assessment row. The step bar width is the record's own
  /// `progress_percent` — derived server-side from the stage timestamps, never
  /// computed here. The action hands over to the workspace for that property,
  /// which supplies the actual stages and backend saving.
  Component _listingRow(AssessmentRecord record) {
    final property = record.property;
    final currentStage = record.stages
        .where((stage) => stage.number == record.currentStage)
        .firstOrNull;
    return tr([
      td([
        span(classes: 'who', [
          Component.text(property?.title ?? 'Property ${record.propertyId}'),
        ]),
        span(classes: 'sub', [
          Component.text('Property ${record.propertyId}'),
        ]),
      ]),
      td([
        div(classes: 'asw-step', [
          span(
            classes: 'asw-step__bar',
            attributes: const {'aria-hidden': 'true'},
            [
              span(
                classes: 'asw-step__fill',
                styles: Styles(
                  width: Unit.percent(
                    record.progressPercent.clamp(0, 100).toDouble(),
                  ),
                ),
                [],
              ),
            ],
          ),
          span(classes: 'small', [
            Component.text(
              'Step ${record.currentStage} of ${record.totalStages}',
            ),
          ]),
        ]),
        span(classes: 'sub', [
          Component.text(currentStage?.title ?? record.nextAction.label),
        ]),
      ]),
      td([
        StatusBadge(
          record.isCompleted ? 'Completed' : 'In progress',
          tone: record.isCompleted ? 'success' : 'action',
        ),
      ]),
      td([
        span(classes: 'sub', [
          Component.text(_dateLabel(record.updatedAt)),
        ]),
      ]),
      td([
        div(classes: 'asw-row-actions', [
          // In-place open (user request: no page navigation — the workspace
          // swaps into this page's content like the report tab does). The
          // checkpoint follows the record's OWN progress — the step the
          // progress column shows is the checkpoint that opens. Stage 2 gets
          // the questionnaire wording; other stages are a continue.
          button(
            classes: 'asw-row-btn',
            attributes: const {'type': 'button'},
            events: events(
              onClick: () => _openAssessment(
                record.propertyId,
                stage: record.currentStageKey,
              ),
            ),
            [
              Component.text(
                record.isCompleted
                    ? 'View assessment'
                    : record.currentStageKey == 'business_requirements'
                        ? 'Continue questionnaire'
                        : 'Continue assessment',
              ),
            ],
          ),
          button(
            classes: 'asw-row-btn asw-row-btn--danger',
            attributes: {
              'type': 'button',
              'aria-label': 'Delete the assessment for '
                  '${property?.title ?? 'Property ${record.propertyId}'}',
            },
            events: events(onClick: () => _openDelete(record)),
            [Component.text('Delete')],
          ),
        ]),
      ]),
    ]);
  }

  static const _monthNames = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  /// Day Month Year, or an honest dash when the server sent no timestamp.
  static String _dateLabel(String? iso) {
    if (iso == null || iso.isEmpty) return '—';
    final date = DateTime.tryParse(iso);
    if (date == null) return '—';
    return '${date.day} ${_monthNames[date.month - 1]} ${date.year}';
  }

  // ------------------------------------------------------------- create dialog

  /// The "New assessment" dialog: the account's saved properties, searchable,
  /// up to three selections. Confirming starts one independent assessment per
  /// selected property — the same per-property POST the workspace's own entry
  /// points use.
  Component _createDialog() {
    final selectable = _selectableFuture;
    if (selectable == null) return div(const []);
    return SitewiseDialog(
      title: 'Create a new assessment',
      ariaLabel: 'Create a new assessment',
      wide: true,
      onClose: _closeCreate,
      body: FutureBuilder<AssessmentSelectableProperties>(
        future: selectable,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Skeleton(variant: 'row', count: 4);
          }
          final data = snapshot.data;
          if (data == null || data.hasError) {
            return EmptyState(
              title: 'Your saved properties did not load',
              body:
                  data?.errorMessage ??
                  'The dialog received no response for your saved list. '
                      'Nothing has been changed.',
              action: ActionButton(
                'Try again',
                onClick: () => setState(
                  () => _selectableFuture =
                      AppLocator.assessmentSelectableProperties.call(),
                ),
              ),
            );
          }
          if (data.isUnauthorized) {
            return const EmptyState(
              title: 'You are not signed in to this workspace',
              body:
                  'Saved properties belong to your account, so the service '
                  'will only return them to a signed-in entrepreneur.',
              action: ActionLink(
                'Go to sign in',
                href: '/login',
                variant: 'primary',
              ),
            );
          }
          if (data.isEmpty) {
            return const EmptyState(
              title: 'No saved properties yet',
              body:
                  'Save a property from Explore first — assessments can only '
                  'be created for properties on your saved list.',
              action: ActionLink(
                'Explore properties',
                href: '/entrepreneur/explore',
                variant: 'primary',
              ),
            );
          }

          final visible = data.search(_dialogSearch);
          final atLimit = _selectedRefs.length >= _maxSelections;
          return div(classes: 'stack stack--md', [
            p(classes: 'small asw-muted', [
              Component.text(
                'Choose the saved property you want to assess. You can '
                'select up to $_maxSelections.',
              ),
            ]),
            SearchInput(
              label: 'Select saved properties',
              placeholder: 'Search by property name or ID',
              ariaLabel: 'Search saved properties',
              onInput: (value) => setState(() => _dialogSearch = value),
            ),
            if (atLimit)
              div(classes: 'notice notice-info asw-select-limit', [
                Component.text(
                  'You have selected the maximum of $_maxSelections '
                  'properties. Remove one below to choose a different '
                  'property.',
                ),
              ]),
            if (visible.isEmpty)
              p(classes: 'body', [
                Component.text(
                  _dialogSearch.trim().isEmpty
                      ? 'None of your saved properties can be assessed right '
                            'now.'
                      : 'No saved property matches “${_dialogSearch.trim()}”.',
                ),
              ])
            else
              div(
                classes: 'asw-select',
                attributes: {
                  'role': 'group',
                  'aria-label':
                      'Saved properties — choose up to $_maxSelections',
                },
                [for (final item in visible) _dialogChoice(item, atLimit)],
              ),
            p(classes: 'small asw-muted', [
              Component.text(
                'Choose at least one property. Each property gets its own '
                'independent assessment — questionnaire, evidence, prediction '
                'and report. The assessments are never combined.',
              ),
            ]),
            if (_dialogError != null)
              div(classes: 'notice notice-danger', [
                Component.text(_dialogError!),
              ]),
          ]);
        },
      ),
      actions: [
        span(
          classes: 'asw-select-count',
          attributes: const {'aria-live': 'polite'},
          [
            Component.text(
              '${_selectedRefs.length} of $_maxSelections selected',
            ),
          ],
        ),
        ActionButton('Cancel', variant: 'secondary', onClick: _closeCreate),
        ActionButton(
          _creating ? 'Creating…' : 'Create Assessment',
          onClick:
              _selectedRefs.isEmpty || _creating ? null : _createSelected,
        ),
      ],
    );
  }

  /// One saved property as a selectable dialog row — checkbox, image and lock
  /// behaviour identical to the workspace's own selector cards.
  Component _dialogChoice(SelectableProperty item, bool atLimit) {
    final property = item.property;
    final unavailable = property == null;
    final selected = _selectedRefs.contains(item.propertyRef);
    final locked = !selected && (atLimit || unavailable);

    return label(
      classes: [
        'asw-select-card',
        if (selected) 'is-selected',
        if (locked) 'asw-select-card--locked',
      ].join(' '),
      [
        input<bool>(
          type: InputType.checkbox,
          name: 'create-assessment-property',
          value: item.propertyRef,
          checked: selected,
          disabled: locked,
          onChange: (_) => _toggleDialogSelection(item.propertyRef),
        ),
        div(classes: 'asw-select-card__body', [
          if (property != null &&
              property.imageUrl != null &&
              property.imageUrl!.isNotEmpty)
            img(
              src: property.imageUrl!,
              attributes: {'alt': property.title, 'loading': 'lazy'},
              classes: 'asw-select-card__img',
            )
          else
            div(classes: 'asw-select-card__noimg', [
              Icon('image_not_supported', size: 'sm'),
            ]),
          div(classes: 'asw-select-card__main', [
            span(classes: 'asw-select-card__title', [
              Component.text(property?.title ?? item.propertyRef),
            ]),
            span(classes: 'small asw-muted', [
              Component.text('Property ${item.propertyRef}'),
            ]),
            if (property != null) ...[
              span(classes: 'small', [
                Component.text(
                  [
                    property.address,
                    if (property.city.isNotEmpty) property.city,
                    if (property.state.isNotEmpty) property.state,
                  ].join(', '),
                ),
              ]),
              span(classes: 'small asw-muted', [
                Component.text(
                  '${property.rentalDisplay} / month · '
                  '${property.sizeSqft.toStringAsFixed(0)} sq ft · '
                  '${property.propertyType}',
                ),
              ]),
            ] else
              span(classes: 'small asw-muted', [
                Component.text(
                  item.unavailableReason ??
                      'The listing details for this property are unavailable.',
                ),
              ]),
          ]),
        ]),
      ],
    );
  }

  // ------------------------------------------------------------- delete dialog

  /// The "Delete this assessment?" confirmation. States exactly what is
  /// removed — the record, its saved requirements and its stage history — so
  /// the irreversible action is never confirmed against a vague label.
  Component _deleteDialog() {
    final target = _deleteTarget!;
    final title = target.property?.title ?? 'Property ${target.propertyId}';
    return SitewiseDialog(
      title: 'Delete this assessment?',
      ariaLabel: 'Delete this assessment',
      onClose: _closeDelete,
      body: div(classes: 'stack stack--md', [
        p(classes: 'body', [
          Component.text(
            'You are about to delete the assessment for "$title" '
            '(Property ${target.propertyId}).',
          ),
        ]),
        p(classes: 'small asw-muted', [
          Component.text(
            'The record, its saved requirements and its stage history are '
            'removed permanently. This cannot be undone — if you want the '
            'property assessed again, starting it later creates a fresh '
            'assessment from stage 1.',
          ),
        ]),
        if (_deleteError != null)
          div(classes: 'notice notice-danger', [
            Component.text(_deleteError!),
          ]),
      ]),
      actions: [
        ActionButton('Cancel', variant: 'secondary', onClick: _closeDelete),
        ActionButton(
          _deleting ? 'Deleting…' : 'Delete assessment',
          variant: 'danger-outline',
          onClick: _deleting ? null : _deleteConfirmed,
        ),
      ],
    );
  }

  // --------------------------------------------------------------- failure UI

  /// The four failure states the spec requires, keyed off the real HTTP status
  /// rather than a parsed message.
  Component _failure(AssessmentFailure failure) {
    final (title, body, action) = switch (failure.kind) {
      AssessmentFailureKind.unauthorized => (
        'You are not authorised to open this assessment',
        'The backend refused this request for your account. Assessments are '
            'scoped to the signed-in entrepreneur, so another account\'s '
            'record is never shown here.',
        const ActionLink('Go to sign in', href: '/login', variant: 'primary')
            as Component?,
      ),
      AssessmentFailureKind.notFound => (
        'No property with this identifier',
        'The identifier in this link does not match any listing in the '
            'catalogue, so there is nothing to assess. The listing may have '
            'been removed, or the link may be out of date.',
        const ActionLink(
              'Browse commercial properties',
              href: '/entrepreneur/explore',
              variant: 'primary',
            )
            as Component?,
      ),
      AssessmentFailureKind.refused => (
        'The request was refused',
        failure.message,
        null,
      ),
      AssessmentFailureKind.serviceFailure => (
        'The assessment service did not respond',
        failure.message,
        ActionButton('Try again', onClick: () => _reload(_activePropertyId))
            as Component?,
      ),
    };

    return _shell(
      title: 'Location assessment',
      subtitle: 'Property $_activePropertyId',
      actions: _openedInPlace
          ? [ActionButton('Back to assessments', onClick: _closeAssessment)]
          : const [],
      child: div(classes: 'stack stack--md', [
        EmptyState(title: title, body: body, action: action),
        if (failure.code != null)
          p(classes: 'disclaimer', [
            Component.text('Reference: ${failure.code}'),
          ]),
      ]),
    );
  }

  // ---------------------------------------------------------- not-started UI

  Component _notStarted(
    String propertyId,
    CommercialProperty? property,
    AssessmentFailure? failure,
  ) => _shell(
    title: 'Location assessment',
    subtitle: 'Start a new assessment',
    actions: [
      if (_openedInPlace)
        ActionButton('Back to assessments', onClick: _closeAssessment),
      const ActionLink(
        'Assessment History',
        href: '/entrepreneur/assessments/history',
        variant: 'secondary',
      ),
      const ActionLink(
        'Back to Explore',
        href: '/entrepreneur/explore',
        variant: 'secondary',
      ),
    ],
    child: div(classes: 'stack stack--sections', [
      if (_writeError != null) _errorNotice(_writeError!),

      // Mockup's stage guidance banner, in its step-1 (not started) state.
      div(classes: 'asw-guidance', [
        div(classes: 'asw-guidance__icon', [Icon('flag', size: 'sm')]),
        div(classes: 'asw-guidance__copy', [
          p(classes: 'asw-guidance__kicker', [
            Component.text('STEP 1 OF 5'),
          ]),
          h2(classes: 'asw-guidance__title', [
            Component.text('Select property'),
          ]),
          p(classes: 'asw-guidance__desc', [
            Component.text(
              'Confirm the property to assess. Starting the assessment binds '
              'it and records step 1 as complete.',
            ),
          ]),
        ]),
        span(classes: 'asw-guidance__state', [
          Component.text('Not started'),
        ]),
      ]),

      section(classes: 'panel', [
        div(classes: 'panel__head', [
          span(classes: 'panel__title', [
            Component.text('Choose a commercial property'),
          ]),
          span(classes: 'small asw-muted', [
            Component.text('Property $propertyId'),
          ]),
        ]),
        div(classes: 'panel__body stack stack--md', [
          p(classes: 'body', [
            Component.text(
              'No assessment exists for this property yet. Starting one '
              'creates a record under your account and records stage 1 — the '
              'property is now bound to the assessment. Reopening the same '
              'property later resumes this record instead of creating another.',
            ),
          ]),
          if (property != null)
            _SelectedPropertyPanel(property: property, record: null)
          else if (failure != null)
            div(classes: 'notice notice-warn', [
              Component.text(
                'The listing itself could not be loaded (${failure.message}) '
                'The assessment can still be started; the property panel will '
                'fill in once the catalogue responds.',
              ),
            ]),
          div(classes: 'actions-row', [
            ActionButton(
              _busy ? 'Starting…' : 'Start assessment',
              onClick: _busy ? null : () => _start(propertyId),
            ),
            ActionLink(
              'Open property detail',
              href: '/entrepreneur/property-detail?id=$propertyId',
              variant: 'secondary',
            ),
          ]),
        ]),
      ]),
      if (_notice != null) _successNotice(_notice!),
      const _StageLegend(),
    ]),
  );

  // ------------------------------------------------------------- workspace UI

  Component _workspace(AssessmentRecord record) {
    // Cached for the requirements form's seed. Assigning during build is safe:
    // it is a plain field write and never schedules a rebuild.
    _record = record;
    final property = record.property;

    // Exactly ONE checkpoint view is on screen — the mockup's five
    // independent steps, navigated by the journey stepper.
    final selectedKey = _checkpoint ?? record.currentStageKey;
    final selected =
        record.stages
            .where((stage) => stage.key == selectedKey)
            .firstOrNull ??
        record.stages
            .where((stage) => stage.number == record.currentStage)
            .firstOrNull ??
        record.stages.last;

    return _shell(
      title: 'Location assessment',
      leaf: selected.title,
      subtitle: property == null
          ? 'Property ${record.propertyId}'
          : '${property.title} · ${property.address}, ${property.city}',
      actions: [
        if (_openedInPlace)
          ActionButton('Back to assessments', onClick: _closeAssessment),
        ActionLink(
          'Assessment History',
          href: '/entrepreneur/assessments/history',
          variant: 'secondary',
        ),
        ActionLink(
          'Property detail',
          href: '/entrepreneur/property-detail?id=${record.propertyId}',
          variant: 'secondary',
        ),
      ],
      child: div(classes: 'stack stack--sections', [
        if (_notice != null) _successNotice(_notice!),

        if (_writeError != null) _errorNotice(_writeError!),

        // Compact five-step tracker — the checkpoint navigator.
        AssessmentJourneyStepper(
          record: record,
          busy: _busy,
          selectedStageKey: selected.key,
          onOpenStage: _openCheckpoint,
        ),

        // One independent checkpoint at a time, each in the reference's own
        // layout: saved-property selection, questionnaire, findings &
        // decision, explanation review, report review.
        if (selected.key == 'select_property')
          ..._savedPropertiesStep(record, property),
        if (selected.key == 'business_requirements')
          ..._preferencesStep(record, property),
        if (selected.key == 'location_evidence')
          ..._findingsStep(record, selected),
        if (selected.key == 'ai_explanation')
          ..._explanationStep(record, selected),
        if (selected.key == 'assessment_report')
          ..._reportStep(record, selected),

        // Steps 1 and 2 carry their own forward action (the saved-property
        // button and the questionnaire footer), so the shared footer only
        // appears where the reference shows one: steps 3 and 4, plus a back
        // link on step 5.
        if (selected.key == 'location_evidence' ||
            selected.key == 'ai_explanation' ||
            selected.key == 'assessment_report')
          _stepFooter(record, selected),

        p(classes: 'disclaimer', [
          Component.text(
            'A suitability score is a relative decision-support indicator. It '
            'is not a probability of business success, a revenue or '
            'customer-volume forecast, regulatory approval, or a guarantee of '
            'any kind. Licensing, extraction, venting and grease-trap '
            'requirements still need official confirmation.',
          ),
        ]),
      ]),
    );
  }

  // ------------------------------------------------- checkpoint step layouts

  /// What each step is for, keyed by the backend's stage keys so the wording
  /// and the stages can never drift apart.
  static String _stageDescription(String stageKey) => switch (stageKey) {
    'select_property' =>
      'This assessment is bound to its property. Review it, then move on to '
          'your business preferences.',
    'business_requirements' =>
      'Answer the preference questions — they shape how the location is '
          'scored against your concept.',
    'location_evidence' =>
      'Review the measured catchment, accessibility and competitor evidence '
          'for this property.',
    'ai_explanation' =>
      'Open the validated model explanation to see why this location scores '
          'the way it does.',
    'assessment_report' =>
      'Assemble and review the full suitability report for this assessment.',
    _ => 'Continue this assessment to move closer to your report.',
  };

  /// The reference's per-step heading: icon tile, kicker, title, description.
  Component _stepHeading({
    required String kicker,
    required String title,
    required String description,
    String icon = 'flag',
  }) => div(classes: 'asw-stephead', [
    div(classes: 'asw-stephead__icon', [Icon(icon, size: 'sm')]),
    div(classes: 'asw-stephead__copy', [
      p(classes: 'asw-stephead__kicker', [Component.text(kicker)]),
      h2(classes: 'asw-stephead__title', [Component.text(title)]),
      p(classes: 'asw-stephead__desc', [Component.text(description)]),
    ]),
  ]);

  // ------------------------------------------------------------ step 1: saved

  /// A panel head with the reference's icon tile in front of the title. The
  /// tile is decoration only — the title still carries the meaning.
  Component _panelHead({
    required String icon,
    required String title,
    Component? trailing,
  }) => div(classes: 'panel__head asw-phead', [
    div(classes: 'asw-phead__title', [
      span(classes: 'asw-phead__icon', [Icon(icon, size: 'sm')]),
      span(classes: 'panel__title', [Component.text(title)]),
    ]),
    ?trailing,
  ]);

  /// Step 1 in the reference's layout: the saved-property list with the
  /// assessment's bound property checked, then a continue button. Only the
  /// bound property is selectable — changing it would be a different
  /// assessment, which starts from Saved.
  List<Component> _savedPropertiesStep(
    AssessmentRecord record,
    CommercialProperty? bound,
  ) {
    final future =
        _selectableFuture ??= AppLocator.assessmentSelectableProperties.call();
    return [
      FutureBuilder<AssessmentSelectableProperties>(
        future: future,
        builder: (context, snapshot) {
          final data = snapshot.data;
          final needle = _propSearch.trim().toLowerCase();
          final saved = (data?.properties ?? const <SelectableProperty>[])
              .where((item) => item.property != null)
              .where((item) {
                if (needle.isEmpty) return true;
                final p = item.property!;
                return '${p.title} ${p.address} ${p.city} ${p.propertyType} '
                        '${item.propertyRef}'
                    .toLowerCase()
                    .contains(needle);
              })
              .toList();
          final others = saved
              .where((item) => item.property!.id != bound?.id)
              .toList();
          final total = others.length + (bound == null ? 0 : 1);

          return section(classes: 'panel asw-inline', [
            _panelHead(
              icon: 'bookmark',
              title: 'Your saved properties',
              trailing: span(classes: 'small asw-muted', [
                Component.text(
                  total == 0 ? 'None saved' : '1 of $total bound',
                ),
              ]),
            ),
            div(classes: 'panel__body stack stack--md', [
              div(classes: 'asw-search', [
                SearchInput(
                  label: 'Search saved properties',
                  placeholder: 'Search saved properties…',
                  ariaLabel: 'Search saved properties',
                  onInput: (value) => setState(() => _propSearch = value),
                ),
              ]),
              if (bound != null) _savedPropertyRow(bound, bound: true),
              for (final item in others)
                _savedPropertyRow(item.property!, bound: false),
              if (bound == null && others.isEmpty)
                const EmptyState(
                  title: 'Listing no longer available',
                  body:
                      'This assessment is bound to a property id that is not '
                      'in the catalogue any more. Its stages and recorded '
                      'progress are still accurate; the listing details '
                      'cannot be shown.',
                ),
              div(classes: 'asw-propactions', [
                p(classes: 'small asw-muted', [
                  Component.text(
                    'The assessment is bound to the selected property. To '
                    'assess another listing, start a separate assessment from '
                    'your saved properties.',
                  ),
                ]),
                ActionButton(
                  'Continue to business preferences',
                  icon: 'arrow_forward',
                  onClick: () => _openCheckpoint('business_requirements'),
                ),
              ]),
            ]),
          ]);
        },
      ),
    ];
  }

  /// One saved-property row: radio, thumbnail, title, location, rent and id.
  Component _savedPropertyRow(
    CommercialProperty property, {
    required bool bound,
  }) => label(classes: 'asw-proprow${bound ? ' is-on' : ''}', [
    // `checked`/`disabled` must go through the typed parameters: the component
    // writes those two keys itself, so an entry in the attributes map is lost.
    input(
      type: InputType.radio,
      name: 'aswBoundProperty',
      checked: bound,
      disabled: !bound,
    ),
    span(classes: 'asw-proprow__thumb', [
      if (property.imageUrl != null && property.imageUrl!.isNotEmpty)
        img(
          src: property.imageUrl!,
          attributes: const {'alt': '', 'loading': 'lazy'},
          classes: 'asw-proprow__img',
        )
      else
        Icon('home_work'),
    ]),
    div(classes: 'asw-proprow__info', [
      p(classes: 'asw-proprow__title', [Component.text(property.title)]),
      p(classes: 'asw-proprow__meta', [
        Component.text(
          [
            property.city,
            property.propertyType,
            property.rentalRm > 0
                ? 'RM ${property.rentalRm.toStringAsFixed(0)}/month'
                : 'Rental not provided',
          ].where((part) => part.trim().isNotEmpty).join(' · '),
        ),
      ]),
      p(classes: 'asw-proprow__id', [
        Component.text('Property ${property.id}'),
      ]),
    ]),
    if (bound)
      span(classes: 'asw-proprow__tag', [Component.text('Bound')]),
  ]);

  // ------------------------------------------------------ step 2: preferences

  List<Component> _preferencesStep(
    AssessmentRecord record,
    CommercialProperty? property,
  ) => [
    div(classes: 'asw-stepbar', [
      h2(classes: 'asw-stepbar__title', [
        Component.text('Business preferences'),
      ]),
      span(classes: 'asw-stepbar__pill', [
        Icon('home_work', size: 'sm'),
        Component.text(property?.title ?? 'Property ${record.propertyId}'),
      ]),
    ]),
    // A record saved before the questionnaire existed keeps its own legacy
    // editor; a v2/v3 record gets the five questions (v3 form).
    record.requirementsVersion == 1
        ? _legacyRequirementsPanel(record)
        : _questionnairePanel(record),
  ];

  // --------------------------------------------------- step 3: findings layout

  List<Component> _findingsStep(
    AssessmentRecord record,
    AssessmentStage stage,
  ) => [
    _stepHeading(
      kicker: 'Step 3 of 5',
      title: 'Findings & objectives',
      icon: 'layers',
      description:
          'Review what the measured evidence says about this property and '
          'confirm it for the assessment.',
    ),
    div(classes: 'asw-2col', [
      _evidenceFindingsPanel(record),
      _stageDecisionPanel(record, stage),
    ]),
  ];

  /// Left panel of step 3: the measured evidence as searchable finding rows,
  /// filterable by measured / not measured. Values are the backend's own.
  Component _evidenceFindingsPanel(AssessmentRecord record) =>
      FutureBuilder<ApiResult<EvidencePayload>>(
        future: _evidence(record.propertyId),
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return section(classes: 'panel asw-inline', [
              _panelHead(icon: 'analytics', title: 'Location evidence'),
              div(classes: 'panel__body stack stack--md', [
                Skeleton(variant: 'row'),
                Skeleton(variant: 'row', count: 4),
              ]),
            ]);
          }
          final result = snapshot.data;
          final payload = result?.ok == true ? result!.value : null;
          if (payload == null || !payload.available) {
            return section(classes: 'panel asw-inline', [
              _panelHead(icon: 'analytics', title: 'Location evidence'),
              div(classes: 'panel__body', [
                EmptyState(
                  title: 'Evidence unavailable',
                  body:
                      payload?.reason ??
                      result?.failure?.message ??
                      'The analysis pipeline has no evidence row for this '
                          'property yet.',
                  action: ActionButton(
                    'Try again',
                    onClick: () => _retryEvidence(record.propertyId),
                  ),
                ),
              ]),
            ]);
          }

          final metrics = [
            for (final group in payload.groups)
              for (final metric in group.metrics) (group: group, metric: metric),
          ];
          final measured = metrics.where((m) => m.metric.isAvailable).length;
          final missing = metrics.length - measured;
          final needle = _evidenceSearch.trim().toLowerCase();
          final visible = metrics.where((entry) {
            final matchesFilter = switch (_evidenceFilter) {
              'measured' => entry.metric.isAvailable,
              'missing' => !entry.metric.isAvailable,
              _ => true,
            };
            if (!matchesFilter) return false;
            if (needle.isEmpty) return true;
            return '${entry.metric.label} ${entry.metric.key} '
                    '${entry.group.label}'
                .toLowerCase()
                .contains(needle);
          }).toList();

          return section(classes: 'panel asw-inline', [
            _panelHead(
              icon: 'analytics',
              title: 'Location evidence (${metrics.length})',
              trailing: Pill(
                '$measured of ${metrics.length} measured',
                tone: missing == 0 ? 'success' : 'neutral',
              ),
            ),
            div(classes: 'panel__body stack stack--md', [
              div(classes: 'asw-findtools', [
                div(classes: 'tabs', [
                  _evidenceFilterTab('All (${metrics.length})', 'all'),
                  _evidenceFilterTab('Measured ($measured)', 'measured'),
                  _evidenceFilterTab('Not measured ($missing)', 'missing'),
                ]),
                div(classes: 'asw-findsearch', [
                  SearchInput(
                    label: 'Search findings',
                    placeholder: 'Search findings…',
                    ariaLabel: 'Search findings',
                    onInput: (value) =>
                        setState(() => _evidenceSearch = value),
                  ),
                ]),
              ]),
              if (visible.isEmpty)
                const EmptyState(
                  title: 'No findings match',
                  body: 'Clear the search or choose a different filter.',
                )
              else
                div(classes: 'asw-findlist', [
                  for (final entry in visible)
                    div(classes: 'asw-find', [
                      span(classes: 'asw-find__id', [
                        Component.text(entry.metric.key),
                      ]),
                      div(classes: 'asw-find__body', [
                        p(classes: 'asw-find__label', [
                          Component.text(entry.metric.label),
                        ]),
                        p(classes: 'asw-find__group', [
                          Component.text(entry.group.label),
                        ]),
                        if (entry.metric.note != null &&
                            entry.metric.note!.isNotEmpty)
                          p(classes: 'asw-find__note', [
                            Component.text(entry.metric.note!),
                          ]),
                      ]),
                      div(classes: 'asw-find__side', [
                        strong(classes: 'asw-find__value', [
                          Component.text(
                            entry.metric.isAvailable
                                ? _metricValue(entry.metric)
                                : 'Not measured',
                          ),
                        ]),
                        span(
                          classes:
                              'asw-chip${entry.metric.isAvailable ? ' asw-chip--ok' : ''}',
                          [
                            Component.text(
                              entry.metric.isAvailable
                                  ? 'Measured'
                                  : 'Not measured',
                            ),
                          ],
                        ),
                      ]),
                    ]),
                ]),
            ]),
          ]);
        },
      );

  Component _evidenceFilterTab(String label, String value) => button(
    classes: 'tab${_evidenceFilter == value ? ' is-active' : ''}',
    attributes: {
      'type': 'button',
      'aria-pressed': _evidenceFilter == value ? 'true' : 'false',
    },
    events: events(onClick: () => setState(() => _evidenceFilter = value)),
    [Component.text(label)],
  );

  /// Right panel of step 3: what this step confirms and the decision to record
  /// it — the reference's objective + decision column.
  Component _stageDecisionPanel(AssessmentRecord record, AssessmentStage stage) {
    final canComplete = !stage.isComplete && !stage.isUnavailable && !_busy;
    return section(classes: 'panel asw-inline', [
      _panelHead(
        icon: 'target',
        title: 'Stage decision',
        trailing: Pill(
          stage.isComplete
              ? 'Complete'
              : stage.isUnavailable
                  ? 'Unavailable'
                  : 'Open',
          tone: stage.isComplete
              ? 'success'
              : stage.isUnavailable
                  ? 'warning'
                  : 'action',
        ),
      ),
      div(classes: 'panel__body stack stack--md', [
        div(classes: 'asw-objective', [
          p(classes: 'asw-objective__label', [
            Component.text('What this step confirms'),
          ]),
          p(classes: 'asw-objective__text', [
            Component.text(_stageDescription(stage.key)),
          ]),
        ]),
        p(classes: 'asw-decision__title', [
          Component.text('What would you like to do?'),
        ]),
        div(classes: 'asw-choices', [
          button(
            classes: 'asw-choice',
            attributes: {
              'type': 'button',
              if (!canComplete) 'disabled': '',
            },
            events: events(
              onClick: canComplete ? () => _completeStage(record, stage.key) : null,
            ),
            [
              Icon('check_circle', size: 'sm'),
              span(classes: 'asw-choice__text', [
                strong([Component.text('Yes, the evidence is accurate')]),
                small([
                  Component.text(
                    'Records stage ${stage.number} as complete on your '
                    'assessment.',
                  ),
                ]),
              ]),
            ],
          ),
          div(classes: 'asw-choice asw-choice--link', [
            ActionLink(
              'Review the full analysis first',
              href:
                  '/entrepreneur/explanation?property=${Uri.encodeComponent(record.propertyId)}',
              variant: 'secondary',
            ),
          ]),
        ]),
        if (stage.isUnavailable && stage.unavailableReason != null)
          div(classes: 'notice notice-warn', [
            Component.text(stage.unavailableReason!),
          ]),
        div(classes: 'asw-decision__foot', [
          span(classes: 'small asw-muted', [
            Component.text(
              stage.isComplete
                  ? 'Recorded as complete.'
                  : stage.isUnavailable
                      ? 'This stage cannot be completed right now.'
                      : 'Nothing is recorded until you confirm.',
            ),
          ]),
          ActionButton(
            _busy ? 'Saving…' : 'Mark stage complete',
            onClick: canComplete ? () => _completeStage(record, stage.key) : null,
          ),
        ]),
      ]),
    ]);
  }

  // ------------------------------------------------ step 4: explanation review

  List<Component> _explanationStep(
    AssessmentRecord record,
    AssessmentStage stage,
  ) {
    final future = _explanationFuture ??= _api.explanation(record.assessmentId);
    return [
      _stepHeading(
        kicker: 'Step 4 of 5',
        title: 'AI explanation',
        icon: 'psychology',
        description:
            'Review which factors raised or lowered this location\'s score, '
            'and how strongly — from the validated model explanation.',
      ),
      FutureBuilder<ApiResult<ResearchExplanation?>>(
        future: future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return section(classes: 'panel asw-inline', [
              div(classes: 'panel__body stack stack--md', [
                Skeleton(variant: 'row', count: 5),
              ]),
            ]);
          }
          final result = snapshot.data;
          final explanation = result?.ok == true ? result!.value : null;
          final available =
              explanation != null &&
              explanation.available &&
              record.capabilities.explanation.available;
          final factors = <({String label, double value})>[
            if (explanation != null) ...[
              for (final factor in explanation.strongestPositive)
                (label: factor.feature, value: factor.contribution),
              for (final factor in explanation.strongestNegative)
                (label: factor.feature, value: factor.contribution),
            ],
          ];
          return div(classes: 'asw-2col asw-2col--aside', [
            section(classes: 'panel asw-inline', [
              _panelHead(
                icon: 'psychology',
                title: 'Explanation factors (${factors.length})',
                trailing: Pill(
                  available ? 'Available' : 'Not available',
                  tone: available ? 'success' : 'warning',
                ),
              ),
              div(classes: 'panel__body stack stack--md', [
                if (!available)
                  EmptyState(
                    title: 'Explanation not available yet',
                    body:
                        record.capabilities.explanation.reason ??
                        explanation?.scoreMeaning ??
                        'The model explanation has not been produced for this '
                            'assessment yet. Complete the earlier steps first.',
                  )
                else if (factors.isEmpty)
                  const EmptyState(
                    title: 'No factors recorded',
                    body:
                        'The explanation payload carries no strongest positive '
                        'or negative factors for this property.',
                  )
                else
                  div(classes: 'asw-findlist', [
                    for (final factor in factors)
                      div(classes: 'asw-find', [
                        div(classes: 'asw-find__body', [
                          p(classes: 'asw-find__label', [
                            Component.text(
                              factor.label.replaceAll('_', ' '),
                            ),
                          ]),
                          p(classes: 'asw-find__group', [
                            Component.text(
                              factor.value >= 0
                                  ? 'Raises the suitability score'
                                  : 'Lowers the suitability score',
                            ),
                          ]),
                        ]),
                        div(classes: 'asw-find__side', [
                          strong(classes: 'asw-find__value', [
                            Component.text(
                              '${factor.value >= 0 ? '+' : ''}'
                              '${factor.value.toStringAsFixed(3)}',
                            ),
                          ]),
                          span(
                            classes:
                                'asw-chip${factor.value >= 0 ? ' asw-chip--ok' : ''}',
                            [
                              Component.text(
                                factor.value >= 0 ? 'Positive' : 'Negative',
                              ),
                            ],
                          ),
                        ]),
                      ]),
                  ]),
                div(classes: 'actions-row', [
                  if (available)
                    ActionLink(
                      'Open full analysis',
                      href:
                          '/entrepreneur/explanation?property=${Uri.encodeComponent(record.propertyId)}',
                      variant: 'secondary',
                    ),
                ]),
              ]),
            ]),
            div(classes: 'asw-aside', [
              _asideBox('monitoring', 'Review progress', [
                div(classes: 'asw-kv', [
                  span([Component.text('Stages completed')]),
                  strong([
                    Component.text(
                      '${record.completedStages} / ${record.totalStages}',
                    ),
                  ]),
                ]),
                div(classes: 'asw-kv', [
                  span([Component.text('Assessment status')]),
                  strong([
                    Component.text(
                      record.isCompleted ? 'Completed' : 'In progress',
                    ),
                  ]),
                ]),
                div(classes: 'progress-track', [
                  i(
                    classes:
                        'w-${(record.progressPercent / 5).round() * 5}',
                    [],
                  ),
                ]),
              ]),
              _asideBox(
                'tune',
                'Business preferences',
                _preferenceRows(record),
              ),
              _asideBox(
                'analytics',
                'Evidence context',
                _evidenceContextRows(record),
              ),
            ]),
          ]);
        },
      ),
    ];
  }

  List<Component> _preferenceRows(AssessmentRecord record) {
    final stored = record.requirements;
    if (stored == null || stored.isEmpty) {
      return [
        p(classes: 'small asw-muted', [
          Component.text('No business preferences recorded yet.'),
        ]),
      ];
    }
    final rows = <Component>[];
    for (final q in _questions) {
      final value = stored[q.id];
      if (value == null) continue;
      final text = value is List
          ? value.map((item) => _optionCaption(q, '$item')).join(', ')
          : _optionCaption(q, '$value');
      rows.add(div(classes: 'asw-kv', [
        span([Component.text(_questionNavLabels[q.id] ?? q.id)]),
        strong([Component.text(text)]),
      ]));
    }
    if (rows.isEmpty) {
      return [
        p(classes: 'small asw-muted', [
          Component.text('No business preferences recorded yet.'),
        ]),
      ];
    }
    return rows;
  }

  String _optionCaption(
    ({String id, String prompt, String help, String kind, List<(String, String)> options}) q,
    String token,
  ) {
    for (final (value, caption) in q.options) {
      if (value == token) return caption;
    }
    return token.replaceAll('_', ' ');
  }

  List<Component> _evidenceContextRows(AssessmentRecord record) =>
      [FutureBuilder<ApiResult<EvidencePayload>>(
        future: _evidence(record.propertyId),
        builder: (context, snapshot) {
          final payload =
              snapshot.data?.ok == true ? snapshot.data!.value : null;
          if (payload == null || !payload.available) {
            return p(classes: 'small asw-muted', [
              Component.text('Evidence is not available for this property.'),
            ]);
          }
          final metrics = [
            for (final group in payload.groups)
              for (final metric in group.metrics)
                if (metric.isAvailable) metric,
          ].take(3).toList();
          if (metrics.isEmpty) {
            return p(classes: 'small asw-muted', [
              Component.text('No measured metrics for this property.'),
            ]);
          }
          return div(classes: 'stack stack--xs', [
            for (final metric in metrics)
              div(classes: 'asw-kv', [
                span([Component.text(metric.label)]),
                strong([Component.text(_metricValue(metric))]),
              ]),
          ]);
        },
      )];

  /// One bordered aside box in the reference's right column.
  Component _asideBox(String icon, String title, List<Component> children) =>
      section(classes: 'panel asw-asidebox', [
        _panelHead(icon: icon, title: title),
        div(classes: 'panel__body stack stack--xs', children),
      ]);

  // ------------------------------------------------------- step 5: report view

  List<Component> _reportStep(AssessmentRecord record, AssessmentStage stage) {
    final reportReady = record.capabilities.report.available;
    final requirementsReady = record.requirements != null &&
        record.requirements!.isNotEmpty;
    final rows = <(String, String, bool)>[
      ('Property summary', 'Bound property record', true),
      (
        'Business preferences',
        requirementsReady ? 'Five answers recorded' : 'Not recorded yet',
        requirementsReady,
      ),
      ('Location evidence', 'Measured evidence for this property', true),
      (
        'AI explanation',
        record.capabilities.explanation.available
            ? 'Model explanation available'
            : 'Not available',
        record.capabilities.explanation.available,
      ),
      ('Suitability score', 'Relative decision-support index', true),
    ];
    return [
      _stepHeading(
        kicker: 'Step 5 of 5',
        title: 'Assessment report',
        icon: 'description',
        description:
            'Review what the report contains, then open it to read, print or '
            'download. Nothing is generated until you open it.',
      ),
      div(classes: 'asw-2col asw-2col--aside', [
        section(classes: 'panel asw-inline', [
          _panelHead(
            icon: 'description',
            title: 'Report contents',
            trailing: Pill(
              reportReady ? 'Report available' : 'Not available',
              tone: reportReady ? 'success' : 'warning',
            ),
          ),
          div(classes: 'panel__body', [
            div(classes: 'table-scroll', [
              table(classes: 'audit-table asw-reporttable', [
                thead([
                  tr([
                    th([Component.text('Section')]),
                    th([Component.text('Contents')]),
                    th([Component.text('Status')]),
                  ]),
                ]),
                tbody([
                  for (final (section, contents, ok) in rows)
                    tr([
                      td([span(classes: 'who', [Component.text(section)])]),
                      td([span(classes: 'sub', [Component.text(contents)])]),
                      td([
                        StatusBadge(
                          ok ? 'Included' : 'Pending',
                          tone: ok ? 'success' : 'warning',
                        ),
                      ]),
                    ]),
                ]),
              ]),
            ]),
          ]),
        ]),
        div(classes: 'asw-aside', [
          _asideBox('monitoring', 'Review progress', [
            div(classes: 'asw-kv', [
              span([Component.text('Stages completed')]),
              strong([
                Component.text(
                  '${record.completedStages} / ${record.totalStages}',
                ),
              ]),
            ]),
            div(classes: 'asw-kv', [
              span([Component.text('Assessment status')]),
              strong([
                Component.text(record.isCompleted ? 'Completed' : 'In progress'),
              ]),
            ]),
            div(classes: 'asw-kv', [
              span([Component.text('Report')]),
              strong([
                Component.text(
                  record.reportAvailable ? 'Generated' : 'Not generated yet',
                ),
              ]),
            ]),
          ]),
          _asideBox('fact_check', 'Stage decision', [
            p(classes: 'small asw-muted', [
              Component.text(
                reportReady
                    ? 'Open the report to review, print or download it.'
                    : record.capabilities.report.reason ??
                        'The report generator is not available right now.',
              ),
            ]),
            if (reportReady)
              ActionLink(
                'Open report',
                href:
                    '/entrepreneur/report?id=${Uri.encodeComponent(record.propertyId)}',
                variant: 'primary',
              ),
            if (!stage.isComplete)
              ActionButton(
                _busy ? 'Saving…' : 'Mark stage complete',
                variant: 'secondary',
                onClick: _busy || stage.isUnavailable
                    ? null
                    : () => _completeStage(record, stage.key),
              ),
          ]),
        ]),
      ]),
    ];
  }

  // --------------------------------------------------------------- step footer

  /// The reference's step footer: back to the previous checkpoint, forward to
  /// the next. Navigation only — completion is always an explicit decision.
  Component _stepFooter(AssessmentRecord record, AssessmentStage selected) {
    final index = record.stages.indexWhere(
      (stage) => stage.key == selected.key,
    );
    final previous = index > 0 ? record.stages[index - 1] : null;
    final next = index >= 0 && index < record.stages.length - 1
        ? record.stages[index + 1]
        : null;
    return div(classes: 'asw-stepactions', [
      if (previous != null)
        ActionButton(
          'Back to ${previous.title}',
          variant: 'secondary',
          onClick: () => _openCheckpoint(previous.key),
        ),
      if (next != null)
        ActionButton(
          'Continue to ${next.title}',
          icon: 'arrow_forward',
          onClick: () => _openCheckpoint(next.key),
        ),
    ]);
  }

  /// A measured metric rendered with its unit, e.g. "31,366 people".
  static String _metricValue(EvidenceMetric metric) {
    final value = metric.value;
    if (value == null) return 'Not measured';
    final text = value == value.roundToDouble()
        ? value.toStringAsFixed(0)
        : value.toStringAsFixed(1);
    final grouped = text.replaceAllMapped(
      RegExp(r'(\d)(?=(\d{3})+(?!\d))'),
      (match) => '${match[1]},',
    );
    final unit = metric.unit.trim();
    if (unit.isEmpty) return grouped;
    if (unit == 'count') return grouped;
    if (unit == 'RM/month') return 'RM $grouped/month';
    if (unit == 'm') {
      final metres = value;
      return metres >= 995
          ? '${(metres / 1000).toStringAsFixed(1)} km'
          : '$grouped m';
    }
    return '$grouped $unit';
  }

  Component _crumbs({String? leaf}) {
    // The listing is the trail's end: Home › Assessments. The workspace adds
    // the checkpoint leaf, and its "Assessments" hop returns in place (no
    // navigation) when the workspace was opened from the listing; from a
    // `?id=` URL it stays a normal link.
    if (_activePropertyId.isEmpty) {
      return nav(classes: 'crumbs', [
        AppLink(
          to: '/entrepreneur',
          classes: 'crumbs__item crumbs__link',
          children: [Component.text('Home')],
        ),
        span(classes: 'crumbs__sep', [Component.text('›')]),
        span(classes: 'crumbs__item crumbs__item--current', [
          Component.text('Assessments'),
        ]),
      ]);
    }
    final assessments = _openedInPlace
        ? button(
            classes: 'crumbs__item crumbs__link',
            attributes: const {'type': 'button'},
            events: events(onClick: _closeAssessment),
            [Component.text('Assessments')],
          )
        : AppLink(
            to: '/entrepreneur/assessments',
            classes: 'crumbs__item crumbs__link',
            children: [Component.text('Assessments')],
          ) as Component;
    return nav(classes: 'crumbs', [
      AppLink(
        to: '/entrepreneur',
        classes: 'crumbs__item crumbs__link',
        children: [Component.text('Home')],
      ),
      span(classes: 'crumbs__sep', [Component.text('›')]),
      assessments,
      span(classes: 'crumbs__sep', [Component.text('›')]),
      span(classes: 'crumbs__item crumbs__item--current', [
        Component.text(leaf ?? 'Location assessment'),
      ]),
    ]);
  }

  Component _successNotice(String text) => div(classes: 'notice notice-info', [
    div([Component.text(text)]),
  ]);

  Component _errorNotice(AssessmentFailure failure) =>
      div(classes: 'notice notice-danger', [
        div(classes: 'stack stack--xs', [
          Component.text(failure.message),
          span(classes: 'small asw-muted', [
            Component.text(
              failure.isRetryable
                  ? 'The service did not answer. Nothing was saved — try again.'
                  : 'Nothing was saved. The assessment is unchanged.',
            ),
          ]),
        ]),
      ]);

  // ------------------------------------------ stage 2: five-question flow (V3)

  /// One business-preference question (five-question Recommender V3,
  /// requirements schema v3, 2026-11-11).
  ///
  /// `kind` is `single` or `multi`; `options` are (token, label) pairs.
  /// Tokens are what the backend validates, so a label can change without
  /// rewriting a saved answer. Q4 shows the five V3 priorities; the two
  /// legacy v2 tokens stay valid server-side for pre-V3 records, which seed
  /// from storage without being re-interpreted.
  static const List<
    ({String id, String prompt, String help, String kind, List<(String, String)> options})
  >
  _questions = [
    (
      id: 'fnb_concept',
      prompt: 'What kind of F&B business are you opening?',
      help: 'Your concept shapes how the competition figures are read.',
      kind: 'single',
      options: [
        ('cafe_coffee_shop', 'Café / Coffee Shop'),
        ('restaurant', 'Restaurant'),
        ('bakery_dessert_shop', 'Bakery / Dessert Shop'),
        ('fast_food_quick_service', 'Fast Food / Quick Service'),
        ('beverage_shop_kiosk', 'Beverage / Kiosk'),
        ('other_fnb', 'Other'),
      ],
    ),
    (
      id: 'service_model',
      prompt: 'How will you serve customers?',
      help: 'Dine-in, takeaway and delivery place different demands on a site.',
      kind: 'single',
      options: [
        ('dine_in', 'Dine-in'),
        ('takeaway_quick_service', 'Takeaway / Quick Service'),
        ('delivery_focused', 'Delivery Focused'),
        ('hybrid', 'Hybrid'),
      ],
    ),
    (
      id: 'target_customers',
      prompt: 'Who are your target customers?',
      help: 'Select every group that matters. At least one is required.',
      kind: 'multi',
      options: [
        ('nearby_residents', 'Nearby Residents'),
        ('office_workers', 'Office Workers'),
        ('students', 'Students'),
        ('commuters', 'Commuters'),
        ('general_public', 'General Public'),
      ],
    ),
    (
      id: 'recommendation_priority',
      prompt: 'What matters most when choosing the location?',
      help:
          'This priority dynamically re-weights the scoring components '
          '(Q4 of the five-question recommender).',
      kind: 'single',
      options: [
        ('high_nearby_population', 'High Nearby Population'),
        ('affordable_operating_location', 'Affordable Operating Location'),
        ('easy_customer_accessibility', 'Easy Customer Accessibility'),
        ('active_commercial_surroundings', 'Active Commercial Surroundings'),
        ('balanced_suitability', 'Balanced Suitability'),
      ],
    ),
    (
      id: 'space_size_preference',
      prompt: 'What size of business space do you prefer?',
      help:
          'Scored against the catalogue\'s calibrated floor-area percentiles '
          '(Q5 of the five-question recommender).',
      kind: 'single',
      options: [
        ('compact_business_space', 'Compact Business Space'),
        ('standard_business_space', 'Standard Business Space'),
        ('spacious_business_space', 'Spacious Business Space'),
        ('flexible_no_preference', 'Flexible / No Preference'),
      ],
    ),
  ];

  /// Answers keyed by question id. Numbers are stored as text while typing and
  /// parsed only when the step is validated.
  final Map<String, dynamic> _answers = <String, dynamic>{};
  int _answerStep = 0;
  String? _answerError;
  bool _answersSeeded = false;

  void _seedAnswers() {
    if (_answersSeeded) return;
    _answersSeeded = true;
    final stored = _record?.requirements;
    for (final q in _questions) {
      final value = stored?[q.id];
      if (value == null) continue;
      if (q.kind == 'multi' && value is List) {
        _answers[q.id] = [for (final item in value) '$item'];
      } else if (q.kind == 'number' && value is num) {
        _answers[q.id] = value == value.roundToDouble()
            ? value.toStringAsFixed(0)
            : '$value';
      } else if (value is String) {
        _answers[q.id] = value;
      }
    }
  }

  bool _stepValid(String kind, Object? value) {
    switch (kind) {
      case 'multi':
        return value is List && value.isNotEmpty;
      case 'number':
        final parsed = double.tryParse('${value ?? ''}');
        return parsed != null && parsed.isFinite && parsed > 0;
      default:
        return value is String && value.isNotEmpty;
    }
  }

  /// Every question answered, then confirm stage 2. The five answers are a
  /// preview (they seed the requirement display only) — nothing here writes
  /// them to the assessment; the backend decides whether stage 2 may complete.
  Future<void> _saveAnswers(AssessmentRecord record) async {
    if (_busy) return;
    final firstInvalid = _questions.indexWhere(
      (q) => !_stepValid(q.kind, _answers[q.id]),
    );
    if (firstInvalid >= 0) {
      setState(() {
        _answerStep = firstInvalid;
        _answerError = 'Answer this question before saving.';
      });
      return;
    }
    setState(() {
      _busy = true;
      _answerError = null;
      _writeError = null;
      _notice = null;
    });
    final result = await _api.completeStage(
      record.assessmentId,
      'business_requirements',
    );
    if (!mounted) return;
    if (!result.ok) {
      setState(() {
        _busy = false;
        _writeError = result.failure;
      });
      return;
    }
    final updated = result.value!;
    setState(() {
      _busy = false;
      _record = updated;
      _future = Future.value(_Started(updated));
      _notice = 'Stage 2 is recorded as complete. '
          '${updated.completedStages} of '
          '${updated.totalStages} stages done.';
    });
  }

  /// Stage 2, in the mockup's two-pane question layout: a navigator column
  /// (answered state per question, progress rail) beside the current question
  /// card (code/position header, prompt, helper, option rows, footer actions).
  /// The flow and validation are the same five-question V3 contract as before
  /// — only the presentation changed.
  static const Map<String, String> _questionNavLabels = {
    'fnb_concept': 'Business type',
    'service_model': 'Service model',
    'target_customers': 'Target customers',
    'recommendation_priority': 'Choosing priority',
    'space_size_preference': 'Space size',
  };

  Component _questionnairePanel(AssessmentRecord record) {
    _seedAnswers();
    final index = _answerStep.clamp(0, _questions.length - 1);
    final q = _questions[index];
    final isLast = index == _questions.length - 1;
    final answered = _questions
        .where((question) => _stepValid(question.kind, _answers[question.id]))
        .length;
    final progress = (answered / _questions.length * 100).round();

    // The reference puts the question navigator and the question card straight
    // on the page (each with its own border), so the step bar above already
    // names the step — no second panel head repeating "Business preferences".
    return div(classes: 'asw-qlayout', [
        // Left: question navigator.
        aside(classes: 'asw-qnav', [
          div(classes: 'asw-qnav__head', [
            h3(classes: 'asw-qnav__title', [
              Component.text('Questions (${_questions.length})'),
            ]),
            p(
              classes: 'small asw-muted',
              attributes: const {'aria-live': 'polite'},
              [Component.text('$answered of ${_questions.length} answered')],
            ),
            div(
              classes: 'asw-qnav__rail',
              attributes: const {'aria-hidden': 'true'},
              [
                div(
                  classes: 'asw-qnav__fill',
                  styles: Styles(width: Unit.percent(progress.toDouble())),
                  const [],
                ),
              ],
            ),
          ]),
          nav(
            classes: 'asw-qnav__list',
            attributes: const {'aria-label': 'Choose an assessment question'},
            [
              for (final (i, question) in _questions.indexed)
                button(
                  classes:
                      'asw-qnav__item${i == index ? ' is-current' : ''}',
                  attributes: {'type': 'button'},
                  events: events(onClick: () => setState(() {
                    _answerStep = i;
                    _answerError = null;
                  })),
                  [
                    span(classes: 'asw-qnav__label', [
                      Component.text(
                        _questionNavLabels[question.id] ?? question.id,
                      ),
                    ]),
                    span(classes: 'asw-qnav__state', [
                      Component.text(
                        _stepValid(question.kind, _answers[question.id])
                            ? '✓'
                            : '',
                      ),
                    ]),
                  ],
                ),
            ],
          ),
          div(classes: 'asw-qnav__foot', [
            Component.text(
              'You can return to any question and change your answer.',
            ),
          ]),
        ]),

        // Right: the current question card.
        div(classes: 'asw-qcard', [
          div(classes: 'asw-qcard__header', [
            span(classes: 'asw-qcard__code', [
              Component.text('V3-Q${index + 1}'),
            ]),
            span(classes: 'asw-qcard__position', [
              Component.text(
                'Question ${index + 1} of ${_questions.length}',
              ),
            ]),
          ]),
          h2(classes: 'asw-qcard__prompt', [Component.text(q.prompt)]),
          p(classes: 'asw-qcard__help', [Component.text(q.help)]),
          div(classes: 'asw-qcard__meta', [
            span(classes: 'asw-qcard__required', [
              Component.text('Required to complete this step'),
            ]),
            span(classes: 'small asw-muted', [
              Component.text(
                q.kind == 'multi'
                    ? 'Select every answer that applies'
                    : 'One answer per question',
              ),
            ]),
          ]),
          div(classes: 'asw-qcard__answers', [
            for (final (token, caption) in q.options)
              label(
                classes: 'asw-answer${_isPicked(q, token) ? ' is-on' : ''}',
                [
                  input(
                    type: q.kind == 'multi'
                        ? InputType.checkbox
                        : InputType.radio,
                    name: 'aswQ${q.id}',
                    checked: _isPicked(q, token),
                    events: events(
                      onChange: (_) => setState(() {
                        _toggleAnswer(q, token);
                        _answerError = null;
                      }),
                    ),
                  ),
                  span(classes: 'asw-answer__label', [
                    Component.text(caption),
                  ]),
                ],
              ),
          ]),
          if (_answerError != null)
            div(classes: 'notice notice-warn', [
              Component.text(_answerError!),
            ]),
          // Footer split like the reference: Previous on the left, the forward
          // action (next question, or save-and-complete on the last one) on
          // the right.
          div(classes: 'asw-qcard__footer', [
            div(classes: 'asw-qcard__group', [
              ActionButton(
                'Previous',
                variant: 'secondary',
                onClick: index == 0
                    ? null
                    : () => setState(() {
                        _answerStep = index - 1;
                        _answerError = null;
                      }),
              ),
            ]),
            div(classes: 'asw-qcard__group', [
              if (isLast)
                ActionButton(
                  _busy ? 'Saving…' : 'Save and complete stage 2',
                  onClick: _busy ? null : () => _saveAnswers(record),
                )
              else
                ActionButton(
                  'Next question',
                  icon: 'arrow_forward',
                  onClick: () {
                    if (!_stepValid(q.kind, _answers[q.id])) {
                      setState(
                        () => _answerError =
                            'Answer this question to continue.',
                      );
                      return;
                    }
                    setState(() {
                      _answerStep = index + 1;
                      _answerError = null;
                    });
                  },
                ),
            ]),
          ]),
        ]),
    ]);
  }

  bool _isPicked(
    ({String id, String prompt, String help, String kind, List<(String, String)> options}) q,
    String token,
  ) {
    final value = _answers[q.id];
    if (q.kind == 'multi') {
      return value is List && value.contains(token);
    }
    return value == token;
  }

  void _toggleAnswer(
    ({String id, String prompt, String help, String kind, List<(String, String)> options}) q,
    String token,
  ) {
    if (q.kind == 'multi') {
      final current = [
        for (final item in (_answers[q.id] as List? ?? const [])) '$item',
      ];
      if (current.contains(token)) {
        current.remove(token);
      } else {
        current.add(token);
      }
      _answers[q.id] = current;
      return;
    }
    _answers[q.id] = token;
  }

  // ------------------------------------------------------------- stage 2 body

  Component _legacyRequirementsPanel(AssessmentRecord record) {
    _seedDraft();
    final draft = _draft;
    if (draft == null) return const span([]);

    return section(classes: 'panel asw-inline', [
      div(classes: 'panel__head', [
        span(classes: 'panel__title', [
          Component.text('Business requirements'),
        ]),
      ]),
      div(classes: 'panel__body stack stack--md', [
        p(classes: 'asw-note', [
          Component.text(
            'These are the same values your ranking preferences use. Saving '
            'here writes them to this assessment and applies them to your '
            'preferences, so the shortlist reflects what you just entered.',
          ),
        ]),
        FutureBuilder<List<String>>(
          future: _types(),
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Skeleton(variant: 'row');
            }
            return _propertyTypeField(draft, snapshot.data ?? const []);
          },
        ),
        div(classes: 'filters', [
          div(classes: 'frow', [
            _numberField(
              'Minimum monthly rent (RM)',
              value: draft.minBudget,
              error: _draftErrors['min_budget_rm'],
              hint: 'Optional. Below 0 is rejected; empty means no floor.',
              onChanged: (v) => setState(() => draft.minBudget = v),
            ),
            _numberField(
              'Maximum monthly rent (RM)',
              value: draft.maxBudget,
              error: _draftErrors['max_budget_rm'],
              hint: 'Required, and must be above zero.',
              onChanged: (v) => setState(() => draft.maxBudget = v),
            ),
            _numberField(
              'Minimum floor area (sq ft)',
              value: draft.minSize,
              error: _draftErrors['min_size_sqft'],
              hint: 'Optional. Empty means no floor.',
              onChanged: (v) => setState(() => draft.minSize = v),
            ),
            _numberField(
              'Maximum floor area (sq ft)',
              value: draft.maxSize,
              error: _draftErrors['max_size_sqft'],
              hint: 'Required, and must be above zero.',
              onChanged: (v) => setState(() => draft.maxSize = v),
            ),
          ]),
          div(classes: 'frow', [
            Field(
              labelText: 'Business category',
              error: _draftErrors['business_type'],
              hint:
                  'Your concept, e.g. "Specialty coffee". Describes the '
                  'business, not the building.',
              child: input(
                attributes: {
                  'type': 'text',
                  'value': draft.businessType,
                  'maxlength': '120',
                  'placeholder': 'e.g. Specialty coffee',
                },
                events: events<String>(
                  onInput: (v) => setState(() => draft.businessType = v),
                ),
              ),
            ),
            Field(
              labelText: 'Target market',
              error: _draftErrors['target_market'],
              hint: 'Stored with the assessment as a requirement note.',
              child: input(
                attributes: {
                  'type': 'text',
                  'value': draft.targetMarket,
                  'maxlength': '240',
                  'placeholder': 'e.g. Office workers, students',
                },
                events: events<String>(
                  onInput: (v) => setState(() => draft.targetMarket = v),
                ),
              ),
            ),
            Field(
              labelText: 'Seating model',
              error: _draftErrors['seating_model'],
              hint: 'Optional. How the space will be used, e.g. "Dine-in".',
              child: input(
                attributes: {
                  'type': 'text',
                  'value': draft.seatingModel,
                  'maxlength': '60',
                  'placeholder': 'e.g. Dine-in with takeaway',
                },
                events: events<String>(
                  onInput: (v) => setState(() => draft.seatingModel = v),
                ),
              ),
            ),
          ]),
        ]),
        if (_draftErrors.isNotEmpty)
          div(classes: 'notice notice-warn', [
            Component.text(
              'Fix the highlighted fields. Nothing has been saved.',
            ),
          ]),
        div(classes: 'actions-row', [
          ActionButton(
            _busy ? 'Saving…' : 'Save and complete stage 2',
            onClick: _busy ? null : () => _saveRequirements(record),
          ),
          ActionButton(
            'Close',
            variant: 'ghost',
            onClick: _busy ? null : () => _toggleStage('business_requirements'),
          ),
        ]),
        p(classes: 'disclaimer', [
          Component.text(
            'The property type above is the building category the eligibility '
            'filter matches against the catalogue. The business category is '
            'your concept. They are separate fields: setting one never '
            'overwrites the other.',
          ),
        ]),
      ]),
    ]);
  }

  Component _propertyTypeField(_RequirementsDraft draft, List<String> types) {
    if (types.isEmpty) {
      return Field(
        labelText: 'Property type',
        error: _draftErrors['property_type'],
        hint:
            'The catalogue\'s property-type list could not be loaded, so this '
            'is free text. The eligibility filter matches it exactly against '
            'the listing\'s property type.',
        child: input(
          attributes: {
            'type': 'text',
            'value': draft.propertyType,
            'maxlength': '60',
            'placeholder': 'e.g. Shop lot',
          },
          events: events<String>(
            onInput: (v) => setState(() => draft.propertyType = v),
          ),
        ),
      );
    }

    // `Any` is the value the recommendation filter treats as no constraint.
    final options = ['Any', ...types];
    return Field(
      labelText: 'Property type',
      error: _draftErrors['property_type'],
      hint: 'Read from the catalogue, so every option matches real listings.',
      child: div(classes: 'chips', [
        for (final option in options)
          label(
            classes: option == draft.propertyType
                ? 'checkpill is-on'
                : 'checkpill',
            [
              input(
                type: InputType.radio,
                name: 'aswPropertyType',
                checked: option == draft.propertyType,
                events: events(
                  onChange: (_) => setState(() => draft.propertyType = option),
                ),
              ),
              span([Component.text(option)]),
            ],
          ),
      ]),
    );
  }

  Component _numberField(
    String label, {
    required String value,
    required String? error,
    required String hint,
    required void Function(String) onChanged,
  }) => Field(
    labelText: label,
    error: error,
    hint: hint,
    child: input(
      attributes: {
        'type': 'number',
        'value': value,
        'min': '0',
        'step': '1',
        'inputmode': 'numeric',
      },
      events: events<String>(onInput: onChanged),
    ),
  );
}

/// The outcome of the initial read, as a value so `build` can match on it.
sealed class _Load {
  const _Load();
}

/// A persisted record exists: render the workspace.
final class _Started extends _Load {
  final AssessmentRecord record;
  const _Started(this.record);
}

/// No record yet. [property] may be null when the catalogue read also failed,
/// in which case [failure] explains why.
final class _NotStarted extends _Load {
  final String propertyId;
  final CommercialProperty? property;
  final AssessmentFailure? failure;
  const _NotStarted({
    required this.propertyId,
    required this.property,
    required this.failure,
  });
}

/// The read itself failed.
final class _Failed extends _Load {
  final AssessmentFailure failure;
  const _Failed(this.failure);
}

// ================================================================= requirements

/// Stage 2 form state.
///
/// Numeric fields are text on purpose: an emptied field has to stay visibly
/// empty and fail validation, rather than being silently parsed to zero and
/// saved as a real constraint the entrepreneur never chose.
final class _RequirementsDraft {
  String businessType;
  String propertyType;
  String targetMarket;
  String seatingModel;
  String minBudget;
  String maxBudget;
  String minSize;
  String maxSize;
  List<String> preferredAreas;

  _RequirementsDraft({
    required this.businessType,
    required this.propertyType,
    required this.targetMarket,
    required this.seatingModel,
    required this.minBudget,
    required this.maxBudget,
    required this.minSize,
    required this.maxSize,
    required this.preferredAreas,
  });

  /// The same limits the backend enforces, so the objection arrives before a
  /// round trip. The server still validates independently.
  Map<String, String> validate() {
    final errors = <String, String>{};

    final business = businessType.trim();
    if (business.isEmpty) {
      errors['business_type'] = 'Enter your business category.';
    } else if (business.length > 120) {
      errors['business_type'] = 'Use 120 characters or fewer.';
    }

    final type = propertyType.trim();
    if (type.isEmpty) {
      errors['property_type'] = 'Choose a property type, or "Any".';
    } else if (type.length > 60) {
      errors['property_type'] = 'Use 60 characters or fewer.';
    }

    if (targetMarket.trim().length > 240) {
      errors['target_market'] = 'Use 240 characters or fewer.';
    }
    if (seatingModel.trim().length > 60) {
      errors['seating_model'] = 'Use 60 characters or fewer.';
    }

    final minBudgetValue = _number(
      minBudget,
      'min_budget_rm',
      errors,
      required: false,
    );
    final maxBudgetValue = _number(
      maxBudget,
      'max_budget_rm',
      errors,
      required: true,
    );
    final minSizeValue = _number(
      minSize,
      'min_size_sqft',
      errors,
      required: false,
    );
    final maxSizeValue = _number(
      maxSize,
      'max_size_sqft',
      errors,
      required: true,
    );

    if (minBudgetValue != null &&
        maxBudgetValue != null &&
        minBudgetValue > maxBudgetValue) {
      errors['min_budget_rm'] = 'Minimum rent cannot exceed the maximum.';
    }
    if (minSizeValue != null &&
        maxSizeValue != null &&
        minSizeValue > maxSizeValue) {
      errors['min_size_sqft'] = 'Minimum floor area cannot exceed the maximum.';
    }
    return errors;
  }

  static double? _number(
    String raw,
    String field,
    Map<String, String> errors, {
    required bool required,
  }) {
    final text = raw.trim();
    if (text.isEmpty) {
      if (required) errors[field] = 'This value is required.';
      return null;
    }
    final parsed = double.tryParse(text);
    if (parsed == null || !parsed.isFinite) {
      errors[field] = 'Enter a number.';
      return null;
    }
    if (parsed < 0) {
      errors[field] = 'Enter zero or a positive number.';
      return null;
    }
    if (required && parsed <= 0) {
      errors[field] = 'Enter a value greater than zero.';
      return null;
    }
    return parsed;
  }

  /// The payload the backend's `validate_requirements` expects.
  Map<String, dynamic> toPayload() => {
    'business_type': businessType.trim(),
    'property_type': propertyType.trim(),
    'target_market': targetMarket.trim(),
    'seating_model': seatingModel.trim(),
    'min_budget_rm': double.tryParse(minBudget.trim()) ?? 0,
    'max_budget_rm': double.tryParse(maxBudget.trim()) ?? 0,
    'min_size_sqft': double.tryParse(minSize.trim()) ?? 0,
    'max_size_sqft': double.tryParse(maxSize.trim()) ?? 0,
    'requirements': targetMarket.trim().isEmpty
        ? const []
        : [targetMarket.trim()],
    'preferred_areas': preferredAreas,
  };
}

// =================================================================== sub-views

/// The five stages and what each one is for. Rendered on the not-started
/// screen so the entrepreneur can see the workflow before committing to it.
class _StageLegend extends StatelessComponent {
  const _StageLegend();

  @override
  Component build(BuildContext context) => section(classes: 'panel', [
    div(classes: 'panel__head', [
      span(classes: 'panel__title', [
        Component.text('What the assessment covers'),
      ]),
    ]),
    div(classes: 'panel__body', [
      ol(classes: 'asw-legend', [
        for (final entry in _stageDescriptions.entries)
          li([
            strong([Component.text(entry.value.$1)]),
            span([Component.text(' — ${entry.value.$2}')]),
          ]),
      ]),
    ]),
  ]);
}

/// Stage titles and descriptions, keyed by the backend's stage keys so the two
/// can never drift.
const Map<String, (String, String)> _stageDescriptions = {
  'select_property': (
    'Select property',
    'Confirms the listing this assessment is about. The record is bound to '
        'this property and to your account.',
  ),
  'business_requirements': (
    'Business requirements',
    'Budget, floor area, property type and concept. These are the values the '
        'ranking engine reads, so saving here also updates your preferences.',
  ),
  'location_evidence': (
    'Location evidence',
    'Competitor pressure, accessibility, catchment demand and the built '
        'environment, as measured by the geospatial analysis pipeline.',
  ),
  'ai_explanation': (
    'AI recommendation explanation',
    'Why the property scored what it did, from the recommendation model. '
        'Needs a trained model artifact on the server.',
  ),
  'assessment_report': (
    'Assessment report',
    'The consolidated report for this property. Only reachable once the '
        'assessment data it summarises actually exists.',
  ),
};

/// The listing being assessed: image when the catalogue has one, title,
/// location, rent, floor area and type.
class _SelectedPropertyPanel extends StatelessComponent {
  final CommercialProperty property;

  /// Null on the not-started screen, where there is no record yet.
  final AssessmentRecord? record;

  const _SelectedPropertyPanel({required this.property, required this.record});

  @override
  Component build(BuildContext context) => section(classes: 'panel', [
    div(classes: 'panel__head', [
      span(classes: 'panel__title', [Component.text('Selected property')]),
    ]),
    div(classes: 'panel__body stack stack--md', [
      if (property.imageUrl != null && property.imageUrl!.isNotEmpty)
        img(
          src: property.imageUrl!,
          attributes: {'alt': property.title, 'loading': 'lazy'},
          classes: 'asw-property__img',
        )
      else
        // No placeholder photograph: the style guide forbids one, and a fake
        // image would misrepresent a listing that has none.
        div(classes: 'asw-property__noimg', [
          Icon('image_not_supported'),
          span(classes: 'small', [
            Component.text('The catalogue has no image for this listing.'),
          ]),
        ]),
      div(classes: 'stack stack--xs', [
        span(classes: 'asw-property__title', [Component.text(property.title)]),
        span(classes: 'small asw-muted', [
          Component.text(
            [
              property.address,
              if (property.city.isNotEmpty) property.city,
              property.state,
              if (property.postcode.isNotEmpty) property.postcode,
            ].join(', '),
          ),
        ]),
        div(classes: 'row row--sm', [
          StatusBadge.forVerification(property.verification),
          Pill(property.propertyType),
        ]),
      ]),
      dl(classes: 'kv', [
        _fact('Monthly rental', property.rentalDisplay),
        _fact('Built-up area', '${property.sizeSqft.toStringAsFixed(0)} sq ft'),
        _fact('Property type', property.propertyType),
        _fact('Listing id', property.id),
      ]),
      div(classes: 'actions-row', [
        ActionLink(
          'Property detail',
          href: '/entrepreneur/property-detail?id=${property.id}',
          variant: 'secondary',
        ),
        ActionLink(
          'Map & surroundings',
          href: '/entrepreneur/explore?id=${property.id}',
          variant: 'ghost',
        ),
      ]),
      if (property.sourceUrl != null)
        span(classes: 'small asw-muted', [
          Component.text('Imported dataset record. '),
          a(
            href: property.sourceUrl!,
            attributes: {'target': '_blank', 'rel': 'noopener noreferrer'},
            [Component.text('View the source listing')],
          ),
        ]),
    ]),
  ]);

  static Component _fact(String label, String value) => div([
    dt([Component.text(label)]),
    dd([Component.text(value)]),
  ]);
}

