import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import 'package:sitewise_jaspr_web/features/assessment/presentation/components/assessment_journey_stepper.dart';
import 'package:sitewise_jaspr_web/features/assessment/presentation/components/customer_questionnaire_step5.dart';
import 'package:sitewise_jaspr_web/features/assessment/presentation/components/m2_workflow_panel.dart';
import 'package:sitewise_jaspr_web/features/assessment/presentation/components/bdj_objective_proposal_panel.dart';
import 'package:sitewise_jaspr_web/features/assessment/presentation/components/project1_research_stage_panel.dart';
import 'package:sitewise_jaspr_web/shared/presentation/components/dashboard_kit.dart' show SitewiseDialog;
import 'package:sitewise_jaspr_web/shared/presentation/components/ui.dart';
import 'package:sitewise_jaspr_web/core/di/app_locator.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/assessment_api.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/assessment_report.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/business_description.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/explanation_candidate.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/measurement_chart_preview.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/q01_synthetic_preview.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/synthetic_preview_gate.dart';
import 'package:sitewise_jaspr_web/features/assessment/application/stage3_access.dart';
import 'package:sitewise_jaspr_web/shared/presentation/layouts/app_layout.dart';
import 'package:sitewise_jaspr_web/features/assessment/presentation/pages/assessment_report_view.dart';

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
  /// Retained for route compatibility; the active M2 workflow owns declarations.
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

  /// Which checkpoint view is on screen — one of [_stageKeys]. Null falls
  /// back to the record's own current stage. Each checkpoint is independent:
  /// the workspace renders exactly one at a time.
  String? _checkpoint;

  /// Step 1's saved-property search query.
  String _propSearch = '';

  /// The property whose assessment is open as an in-place detail view. Set by
  /// the listing's row actions so the workspace content swaps in WITHOUT a
  /// page navigation (the report tab's gate→content behaviour, and the
  /// mockup's showDetail/back pattern). A `?id=` deep link always wins.
  String? _openPropertyId;

  /// The property the workspace flow is bound to: the URL's `?id=` when
  /// present, otherwise the in-place selection from the listing.
  String get _activePropertyId => component.propertyId.isNotEmpty
      ? component.propertyId
      : (_openPropertyId ?? '');

  /// True when the workspace was opened in place from the listing (no `?id=`
  /// in the URL), so a back-to-assessments control is offered.
  bool get _openedInPlace =>
      component.propertyId.isEmpty && _openPropertyId != null;

  bool _busy = false;
  String? _notice;
  AssessmentFailure? _writeError;

  String? _readinessAssessmentId;
  Map<String, dynamic>? _workflowReadiness;
  String? _readinessError;
  int _readinessRequest = 0;
  bool _declarationEditing = false;

  void _invalidateWorkflowReadiness() {
    _readinessRequest++;
    _readinessAssessmentId = null;
    _workflowReadiness = null;
    _readinessError = null;
    _previewAssessmentId = null;
    _previewFuture = null;
    _declarationEditing = false;
    _m2LinkRequest++;
    _m2LinkFor = '';
    _m2LinkId = '';
    _m2LinkStatus = 'idle';
    _m2LinkError = null;
  }

  /// Read the readiness payload, optionally retrying after a write.
  ///
  /// Two failure shapes used to strand this page until the user reloaded:
  ///
  /// 1. the refresh returned silently when [_readinessAssessmentId] had not
  ///    caught up with the id being asked for, leaving `_workflowReadiness`
  ///    null and therefore no "Continue to Stage 3" control;
  /// 2. a confirmation is written by one request and read by the next, so a
  ///    read that lands before the write is visible still answers "confirm
  ///    first" -- and nothing re-read it.
  ///
  /// So the id is adopted rather than compared, and a post-write caller gets a
  /// bounded number of retries. The retry stops the moment stage 2 is complete,
  /// so a healthy save costs exactly one request.
  Future<void> _refreshWorkflowReadiness(String assessmentId,
      {bool afterWrite = false}) async {
    if (!mounted || _declarationEditing) return;
    if (_readinessAssessmentId != assessmentId) {
      _readinessAssessmentId = assessmentId;
    }
    final attempts = afterWrite ? 4 : 1;
    for (var attempt = 0; attempt < attempts; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(Duration(milliseconds: 150 * attempt));
        if (!mounted ||
            _declarationEditing ||
            _readinessAssessmentId != assessmentId) {
          return;
        }
      }
      final request = ++_readinessRequest;
      setState(() {
        _workflowReadiness = null;
        _readinessError = null;
      });
      final result = await _api.workflowReadiness(assessmentId);
      if (!mounted ||
          _declarationEditing ||
          _readinessAssessmentId != assessmentId) {
        return;
      }
      if (request != _readinessRequest) {
        // Another refresh started while this one was in flight. Retrying is
        // cheaper than leaving the page with no payload at all.
        continue;
      }
      setState(() {
        _workflowReadiness = result.value;
        if (!result.ok) {
          _readinessError =
              result.failure?.message ??
              'Assessment progress could not be verified.';
        }
      });
      if (!result.ok) return;
      if (!afterWrite) return;
      if ((result.value?['stage_2'] as Map?)?['complete'] == true) return;
    }
  }

  Future<void> _continueToBusinessReview(String assessmentId) async {
    // The click usually follows a confirmation, so allow the bounded retry: a
    // read that lands before the write is visible must not report "confirm the
    // declaration" for a declaration that is already confirmed.
    await _refreshWorkflowReadiness(assessmentId, afterWrite: true);
    if (!mounted ||
        _readinessAssessmentId != assessmentId ||
        _declarationEditing) {
      return;
    }
    final readinessM2 =
        (_workflowReadiness?['stage_2'] as Map?)?['m2_assessment_id'];
    if ((_workflowReadiness?['stage_3'] as Map?)?['enterable'] != true ||
        readinessM2 is! String ||
        readinessM2.isEmpty) {
      setState(
        () => _readinessError ??=
            'Confirm the current saved M2 declaration before continuing.',
      );
      return;
    }
    // Stage 2 may never have been opened in this page instance. Always verify
    // the active relationship rather than comparing to an empty local cache.
    final readinessRequest = _readinessRequest;
    final linkRequest = ++_m2LinkRequest;
    try {
      final matches = await verifyStage3M2Link(
        expectedM2Id: readinessM2,
        readCurrentLink: () => AppLocator.m2.linkForMarketplace(assessmentId),
      );
      if (!mounted ||
          _readinessAssessmentId != assessmentId ||
          _declarationEditing ||
          readinessRequest != _readinessRequest ||
          linkRequest != _m2LinkRequest) {
        return;
      }
      if (!matches) {
        setState(() {
          _m2LinkFor = '';
          _m2LinkId = '';
          _workflowReadiness = null;
          _readinessError =
              'The M2 link changed. Reload the linked questionnaire before continuing.';
        });
        return;
      }
      setState(() {
        _m2LinkFor = assessmentId;
        _m2LinkId = readinessM2;
        _m2LinkStatus = 'linked';
        _m2LinkError = null;
      });
      _openCheckpoint('location_evidence');
    } catch (error) {
      if (!mounted ||
          _readinessAssessmentId != assessmentId ||
          readinessRequest != _readinessRequest ||
          linkRequest != _m2LinkRequest) {
        return;
      }
      setState(() => _readinessError = _m2FailureText(error));
    }
  }

  /// CP-10F: the M2 assessment resolved for the assessment currently open.
  ///
  /// `idle` before the first lookup, then `loading`, then `linked` (with
  /// [_m2LinkId]), `unlinked` (no M2 record exists yet), `initializing`, or
  /// `error`. The panel is only mounted once an id has actually been resolved,
  /// so it can never fall back to "the newest M2 assessment".
  String _m2LinkId = '';
  String _m2LinkStatus = 'idle';
  String? _m2LinkError;
  String _m2LinkFor = '';
  int _m2LinkRequest = 0;

  /// Step 5's assembled report read, loaded the first time the report
  /// checkpoint is opened, so browsing another stage never calls the report
  /// assembler. The endpoint is read-only: it advances nothing.
  ///
  /// The bundle carries the RP-13 business description read with it: the report
  /// document cannot be assembled without section 02, and two independent
  /// futures would let the document render once without it and again with it.
  Future<_ReportBundle>? _reportFuture;
  Future<ApiResult<QuestionnairePreviewStatus>>? _previewFuture;
  String? _previewAssessmentId;

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

  /// The card selected in the entry page's left column. Null means "no explicit
  /// choice yet", in which case the first visible record is shown — selection
  /// is presentation state and is never persisted.
  String? _selectedAssessmentId;

  /// The entry page's sort order: `recent` | `oldest` | `title` | `progress`.
  String _listSort = 'recent';

  /// The record whose assembled report is open IN PLACE.
  ///
  /// Non-null swaps the whole tab content for the report document — the report
  /// is a destination reached from "View report", never a replacement for the
  /// step-5 checkpoint. Clearing it returns the caller exactly where it was
  /// (the entry page or the step-5 checkpoint).
  AssessmentRecord? _reportRecord;

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
  /// The dialog's single choice. The backend's create-or-resume contract is
  /// per property (one `property_id` per assessment row) and there is no
  /// combined multi-property prediction or report, so a shortlist only ever
  /// produced several unrelated records from one click — which read as one
  /// assessment and was not. See [_toggleDialogSelection].
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
    if (_stageKeys.contains(component.stage)) _checkpoint = component.stage;
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
    if (oldComponent.propertyId == component.propertyId) {
      if (oldComponent.stage != component.stage) {
        _checkpoint = _stageKeys.contains(component.stage)
            ? component.stage
            : null;
      }
      return;
    }
    _invalidateWorkflowReadiness();
    _checkpoint = _stageKeys.contains(component.stage) ? component.stage : null;
    _reportFuture = null;
    _propSearch = '';
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
    _reportRecord = null;
    _selectedAssessmentId = null;
    _listSort = 'recent';
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
    _invalidateWorkflowReadiness();
    _notice = null;
    _writeError = null;
    _reportFuture = null;
    _future = _open(propertyId);
  });

  /// Opens an assessment IN PLACE from the listing row (user request: row
  /// clicks must swap this page's content, not navigate — the report tab's
  /// gate→content behaviour and the mockup's showDetail/back pattern).
  /// `?id=` deep links keep working through the normal route flow.
  void _openAssessment(String propertyId, {String? stage}) => setState(() {
    _invalidateWorkflowReadiness();
    _openPropertyId = propertyId;
    _reportRecord = null;
    _checkpoint = _stageKeys.contains(stage) ? stage : null;
    _reportFuture = null;
    _propSearch = '';
    _notice = null;
    _writeError = null;
    _busy = false;
    _future = _open(propertyId);
  });

  /// Returns from the in-place workspace to the listing without a route
  /// change — the mockup's back-to-list control. The listing is re-read so a
  /// record changed in the workspace shows its new state.
  void _closeAssessment() => setState(() {
    _invalidateWorkflowReadiness();
    _openPropertyId = null;
    _checkpoint = null;
    _reportRecord = null;
    _reportFuture = null;
    _propSearch = '';
    _notice = null;
    _writeError = null;
    _busy = false;
    _historyFuture = _loadListing();
  });

  /// Opens the assembled report IN PLACE.
  ///
  /// The report is a destination, not a stage: it is reached from "View report"
  /// (entry page and step 5) and replaces the tab's content without a
  /// navigation, exactly like the workspace itself. The memoised payload is
  /// dropped first so a report opened after a stage change is current.
  void _openReport(AssessmentRecord record) => setState(() {
    _reportRecord = record;
    _reportFuture = null;
    _notice = null;
    _writeError = null;
  });

  /// Returns from the report document to whatever opened it.
  void _closeReport() => setState(() {
    _reportRecord = null;
    _notice = null;
    _writeError = null;
  });

  /// Step 5's report read, memoised per assessment so switching checkpoints
  /// back and forth does not re-assemble the document on every tap.
  ///
  /// The business description is read after the report, not in parallel: when
  /// the report itself fails the description is not fetched at all, so a failed
  /// page never issues a second request whose result it cannot use.
  Future<_ReportBundle> _report(AssessmentRecord record) =>
      _reportFuture ??= _loadReport(record);

  Future<_ReportBundle> _loadReport(AssessmentRecord record) async {
    final report = await _api.report(record.assessmentId);
    if (!report.ok) return _ReportBundle(report, null);
    final business = await _api.businessDescription(record.assessmentId);
    final explanation = await _loadExplanation(record);
    // A failed description read leaves the section in its held state rather
    // than failing the whole report; the failure is not silent, because the
    // section then says no confirmed description could be read.
    return _ReportBundle(
        report, business.ok ? business.value : null, explanation);
  }

  /// The explanation the report may show.
  ///
  /// EX-05 closes the three EX-04 gaps: the readback envelope carries the
  /// assessment/campaign/snapshot identity, the backend resolves that chain
  /// from the authenticated owner's records, and a store-backed read endpoint
  /// returns the persisted candidate. The client still verifies every returned
  /// identity before drawing anything.
  ///
  /// The module-level notice remains the honest answer when no result exists.
  /// If a result exists but is substantive and unadmitted, no card is shown —
  /// a warning would still confirm that a measurement exists.
  Future<ExplanationPanel?> _loadExplanation(AssessmentRecord record) async {
    final availability = await _api.explanationAvailability();
    ExplanationPanel? moduleHeld;
    if (availability.ok && availability.value?['state'] == 'held') {
      final message = availability.value?['message'];
      moduleHeld = ExplanationPanel.unavailable(
        reason: message is String && message.trim().isNotEmpty ? message : null,
      );
    }

    final m2AssessmentId = record.m2AssessmentId;
    if (m2AssessmentId == null) return moduleHeld;
    final bindingResult = await _api.explanationBinding(m2AssessmentId);
    if (!bindingResult.ok || bindingResult.value == null) return moduleHeld;
    final binding = bindingResult.value!;
    // The binding contract is keyed by the M2 assessment, not the marketplace
    // record: `/cq/assessments/{id}/explanations/binding` is addressed with
    // `m2AssessmentId` and echoes that id back. Comparing it to
    // `record.assessmentId` could never succeed, which silently disabled the
    // whole governed readback path.
    if (binding['assessment_id']?.toString() != m2AssessmentId) {
      return moduleHeld;
    }
    final campaignId = binding['campaign_id']?.toString();
    final snapshots = binding['snapshots'];
    if (campaignId == null || campaignId.isEmpty || snapshots is! List) {
      return moduleHeld;
    }

    var sawResult = false;
    for (final entry in snapshots) {
      if (entry is! Map) continue;
      final snapshot = Map<String, dynamic>.from(entry);
      final snapshotId = snapshot['snapshot_id']?.toString();
      final questionId = snapshot['slot_id']?.toString();
      final contextHash = snapshot['context_hash']?.toString();
      if (snapshotId == null || questionId == null || contextHash == null) {
        continue;
      }
      final read = await _api.explanationReadback(
        assessmentId: m2AssessmentId,
        campaignId: campaignId,
        snapshotId: snapshotId,
        questionId: questionId,
        contextHash: contextHash,
      );
      if (!read.ok || read.value == null) continue;
      sawResult = true;
      ExplanationPanel panel;
      try {
        panel = ExplanationPanel.fromReadback(read.value!);
      } on FormatException {
        continue;
      }
      // The readback envelope carries the M2 assessment id the route was
      // addressed with, so identity is checked against that — not the
      // marketplace record id.
      if (panel.assessmentId != m2AssessmentId ||
          panel.campaignId != campaignId ||
          panel.snapshotId != snapshotId ||
          !panel.boundToSnapshot(snapshotId)) {
        continue;
      }
      if (panel.isRenderable) return panel;
    }
    // A stored candidate that cannot be shown is not the same as no candidate.
    return sawResult ? null : moduleHeld;
  }

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
      _future = Future.value(_Started(started.assessment));
      _notice = started.created
          ? 'Assessment started. Stage 1 is recorded as complete because '
                'the property is now bound to it.'
          : 'Your existing assessment for this property was reopened. '
                'Nothing was duplicated.';
    });
  }

  /// Opens one independent checkpoint view. The journey stepper navigates
  /// between the five checkpoints; the workspace renders exactly one at a time.
  void _openCheckpoint(String key) => setState(() {
    _checkpoint = key;
    if (key == 'assessment_report') {
      _previewAssessmentId = null;
      _previewFuture = null;
    }
    _notice = null;
    _writeError = null;
  });

  // ----------------------------------------------------------------- listing

  /// The account's assessments, from the authenticated history endpoint. The
  /// same read the report directory and assessment history use.
  Future<ApiResult<AssessmentHistory>> _loadListing() =>
      _api.history(limit: 50);

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
  /// Selects exactly one property.
  ///
  /// Choosing a different card REPLACES the current choice rather than adding
  /// to it, so the dialog can never build a shortlist that turns into several
  /// independent assessments from a single click. Choosing the selected card
  /// again clears the selection.
  void _toggleDialogSelection(String propertyRef) => setState(() {
    if (_selectedRefs.contains(propertyRef)) {
      _selectedRefs.remove(propertyRef);
    } else {
      _selectedRefs
        ..clear()
        ..add(propertyRef);
    }
    _dialogError = null;
  });

  /// Creates — or resumes — the assessment for the one selected property, then
  /// opens it at Step 2.
  ///
  /// Step 1 ("Select property") is satisfied by the dialog itself: the record
  /// is bound to that `property_id` the moment the POST succeeds, and the
  /// backend has already created its stage row. Landing the entrepreneur back
  /// on Step 1 to re-pick the property they just picked would be a step that
  /// can only be answered one way, so the dialog hands over at
  /// `business_requirements` instead.
  ///
  /// A refusal keeps the dialog open with the reason verbatim; nothing is
  /// opened on a failed create.
  Future<void> _createSelected() async {
    if (_creating || _selectedRefs.isEmpty) return;
    setState(() {
      _creating = true;
      _dialogError = null;
    });

    final ref = _selectedRefs.first;
    final started = await _api.start(ref);
    if (!mounted) return;
    if (!started.ok) {
      setState(() {
        _creating = false;
        _dialogError = 'Property $ref — ${started.failure!.message}';
      });
      return;
    }

    final created = started.value!.created;
    setState(() {
      _creating = false;
      _createOpen = false;
      _selectedRefs.clear();
      _historyFuture = _loadListing();
      // No `_notice` here: the workspace replaces this view immediately, so a
      // banner about the listing would be a message about a page the
      // entrepreneur is no longer looking at.
      _notice = null;
    });
    _openAssessment(ref, stage: 'business_requirements');
    if (!created) {
      setState(() {
        _notice =
            'You already had an assessment for this property — it was '
            'reopened at Step 2. Nothing was duplicated.';
      });
    }
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
            '${result.failure!.message} Reload to check the current state before retrying.';
        return;
      }
      _deleteTarget = null;
      _historyFuture = _loadListing();
      // The selected card and any open report belonged to the deleted record.
      if (_selectedAssessmentId == target.assessmentId) {
        _selectedAssessmentId = null;
      }
      if (_reportRecord?.assessmentId == target.assessmentId) {
        _reportRecord = null;
      }
      _notice =
          'The assessment for '
          '${target.property?.title ?? 'Property ${target.propertyId}'} '
          'was deleted.';
    });
  }

  // ------------------------------------------------------------------ render

  @override
  Component build(BuildContext context) {
    // The tab now lives inside the same persistent [AppLayout] chrome as the
    // Report tab (user request). That chrome is what makes the pill nav — and
    // therefore in-app tab switching without a document reload — available
    // here; before this, `/entrepreneur/assessments` was the one entrepreneur
    // tab with no navigation at all, so leaving it meant a full page load.
    return AppLayout(
      role: AppRole.entrepreneur,
      currentRoute: '/entrepreneur/assessments',
      title: 'Assessments',
      // The tab supplies its own breadcrumb, eyebrow, heading and CTAs, so the
      // shell must not print a second copy above it — the same contract the
      // report selector uses.
      showPageHead: false,
      showBreadcrumbs: false,
      child: _body(),
    );
  }

  /// The tab's content, split out of [build] so the whole page can be wrapped
  /// in [AppLayout] without re-indenting every branch.
  Component _body() {
    // The report is a destination reached from "View report" — it takes over
    // the tab's content in place and leaves the checkpoint/listing state
    // untouched underneath, so Back returns to exactly the previous view.
    final openReport = _reportRecord;
    if (openReport != null) return _reportDocument(openReport);
    if (_activePropertyId.isEmpty) {
      return _listing();
    }

    final detail = FutureBuilder<_Load>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return _shell(
            showHead: !_openedInPlace,
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
            showHead: !_openedInPlace,
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

    // A row click, or "Continue assessment" in the entry page's detail panel,
    // swaps this tab's content for the workspace. No route change and no page
    // reload: the entry page is one Back away, and its own reads are re-issued
    // when it returns, so the list never shows a stale record.
    return detail;
  }

  /// Page-level shell for the tab's own breadcrumb + head.
  ///
  /// The design starts with the breadcrumb — "Home › Assessments › Customer
  /// questionnaire" — then the page head, then the existing workspace layout
  /// (journey stepper, progress, stage cards, aside).
  ///
  /// This is the *inner* shell only. The pill nav, the signed-in chrome and
  /// the dev-bypass banner come from [AppLayout] in [build]; `.asw-page` no
  /// longer carries its own width band because `.app-content__inner` already
  /// supplies one (see the scoped rule in styles.css).
  Component _shell({
    required String title,
    String? subtitle,
    List<Component> actions = const [],
    required Component child,
    String eyebrow = 'Assessment workspace',
    String? leaf,

    /// False only for the inner detail shells rendered under the listing —
    /// the outer combined shell keeps its single breadcrumb and page head.
    bool showHead = true,
  }) => div(classes: showHead ? 'asw-page' : 'asw-page asw-page--embedded', [
    if (showHead) ...[
      _crumbs(leaf: leaf),
      PageHead(
        title: title,
        // The entry page passes an empty eyebrow: its breadcrumb already
        // says "Entrepreneur workspace", and the supplied design does not
        // repeat it as a caption above the title.
        eyebrow: eyebrow.isEmpty ? null : eyebrow,
        description: subtitle,
        actions: actions,
      ),
    ],
    // The dev-bypass banner is not repeated here: [AppLayout] renders it
    // once for the whole page, and two copies stacked above the same heading
    // read as a bug.
    // Embedded detail has no page head, so name the selected record here —
    // otherwise two assessments' workspace panels look identical. The
    // actions carry the way back, since there is no page head to hold them.
    if (!showHead)
      div(classes: 'asw-inline-detail__head', [
        div(classes: 'asw-inline-detail__copy', [
          h2([Component.text(title)]),
          if (subtitle != null && subtitle.isNotEmpty)
            p(classes: 'asw-muted', [Component.text(subtitle)]),
        ]),
        if (actions.isNotEmpty)
          div(classes: 'asw-inline-detail__actions', actions),
      ]),
    child,
  ]);

  // --------------------------------------------------------------- listing UI

  /// The Assessments entry page — the tab's default view.
  ///
  /// Two columns, as the supplied design: the account's records as selectable
  /// cards on the left, the selected record's own details on the right.
  /// Selection is local state, so inspecting an assessment never navigates;
  /// opening its workspace or its report swaps this page's content in place.
  /// Creating an assessment happens through the dialog, never by opening this
  /// page.
  Component _listing() {
    return _shell(
      title: 'My assessments',
      eyebrow: '',
      subtitle:
          'Manage your location assessments and view reports at any stage.',
      actions: [
        // The supplied design carries exactly one action here: create. The
        // history shortcut that used to sit beside it is dropped because
        // "History" is its own sidebar destination, so the header no longer
        // offers two routes to the same place.
        ActionButton(
          _creating ? 'Starting…' : 'Create assessment',
          icon: 'add',
          onClick: _creating ? null : _openCreate,
        ),
      ],
      child: _listingBody(),
    );
  }

  /// The listing's body without the page shell, so it can stay mounted above
  /// an in-place workspace detail.
  Component _listingBody() {
    final history = _historyFuture ??= _loadListing();
    return div(classes: 'stack stack--sections', [
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
    ]);
  }

  /// The list panel: header row, filter tabs, search, then the table — or the
  /// empty / no-results states.
  Component _listingPanel(AssessmentHistory history) {
    final records = history.items;
    final total = records.length;

    final query = _listSearch.trim().toLowerCase();
    final visible = _sortedRecords([
      for (final record in records)
        if ((_listFilter == 'all' ||
                (_listFilter == 'completed'
                    ? record.isCompleted
                    : !record.isCompleted)) &&
            (query.isEmpty || _listingHaystack(record).contains(query)))
          record,
    ]);

    // Selection survives filtering while its record is still visible;
    // otherwise the first visible record is shown, so the right column is
    // never empty while the left column has cards.
    AssessmentRecord? selected;
    for (final record in visible) {
      if (record.assessmentId == _selectedAssessmentId) selected = record;
    }
    selected ??= visible.isEmpty ? null : visible.first;

    return div(classes: 'asw-entry', [
      section(classes: 'panel panel--flush asw-entry__list', [
        div(classes: 'panel__head', [
          div(classes: 'asw-list-head', [
            span(classes: 'panel__title', [
              Component.text('Assessments ($total)'),
            ]),
          ]),
          span(
            classes: 'asw-list-count',
            attributes: const {'aria-live': 'polite'},
            [
              Component.text(
                '${visible.length} result${visible.length == 1 ? '' : 's'}',
              ),
            ],
          ),
        ]),
        div(classes: 'asw-entry__controls', [
          div(classes: 'asw-entry__search', [
            SearchInput(
              placeholder: 'Search by property or ID',
              ariaLabel: 'Search assessments',
              onInput: (value) => setState(() => _listSearch = value),
            ),
          ]),
          select(
            [
              option([Component.text('All statuses')], value: 'all'),
              option([Component.text('In progress')], value: 'in-progress'),
              option([Component.text('Completed')], value: 'completed'),
            ],
            value: _listFilter,
            classes: 'asw-entry__select',
            attributes: const {'aria-label': 'Filter assessments by status'},
            onChange: (values) => setState(
              () => _listFilter = values.isEmpty ? 'all' : values.first,
            ),
          ),
          select(
            [
              option([Component.text('Most recent')], value: 'recent'),
              option([Component.text('Oldest first')], value: 'oldest'),
              option([Component.text('Name A–Z')], value: 'title'),
              option([Component.text('Most progress')], value: 'progress'),
            ],
            value: _listSort,
            classes: 'asw-entry__select',
            attributes: const {'aria-label': 'Sort assessments'},
            onChange: (values) => setState(
              () => _listSort = values.isEmpty ? 'recent' : values.first,
            ),
          ),
        ]),
        if (visible.isNotEmpty)
          div(classes: 'asw-entry__cards', [
            for (final record in visible)
              _assessmentCard(
                record,
                selected: selected?.assessmentId == record.assessmentId,
              ),
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
      ]),
      if (selected != null)
        _detailPanel(selected)
      else
        section(classes: 'panel panel--flush asw-entry__detail', [
          div(classes: 'panel__head', [
            span(classes: 'panel__title', [
              Component.text('Assessment details'),
            ]),
          ]),
          div(classes: 'panel__body', [
            EmptyState(
              title: 'Nothing selected',
              body:
                  'Select an assessment on the left to see its details, '
                  'continue it, or open its report.',
            ),
          ]),
        ]),
    ]);
  }

  /// The search haystack for one record: the identifiers and place names a
  /// person would actually type.
  static String _listingHaystack(AssessmentRecord record) => [
    record.propertyId,
    record.assessmentId,
    record.property?.title ?? '',
    record.property?.city ?? '',
    record.property?.state ?? '',
  ].join(' ').toLowerCase();

  /// Applies the chosen sort. `recent`/`oldest` read the record's own
  /// `updated_at`; a record with no timestamp sorts last rather than being
  /// treated as "now", so the order never claims knowledge the server omitted.
  List<AssessmentRecord> _sortedRecords(List<AssessmentRecord> records) {
    final sorted = [...records];
    int byUpdated(AssessmentRecord a, AssessmentRecord b) {
      final left = DateTime.tryParse(a.updatedAt ?? '');
      final right = DateTime.tryParse(b.updatedAt ?? '');
      if (left == null && right == null) return 0;
      if (left == null) return 1;
      if (right == null) return -1;
      return left.compareTo(right);
    }

    switch (_listSort) {
      case 'oldest':
        sorted.sort(byUpdated);
      case 'title':
        sorted.sort(
          (first, second) => (first.property?.title ?? first.propertyId)
              .toLowerCase()
              .compareTo(
                (second.property?.title ?? second.propertyId).toLowerCase(),
              ),
        );
      case 'progress':
        sorted.sort(
          (first, second) =>
              second.progressPercent.compareTo(first.progressPercent),
        );
      default:
        sorted.sort((first, second) => byUpdated(second, first));
    }
    return sorted;
  }

  /// One assessment card in the entry page's left column.
  ///
  /// The whole card selects the record (no navigation); "View report" and
  /// "Remove" are real buttons inside it, so their clicks also select the card
  /// — which is the same record, so the two never disagree.
  Component _assessmentCard(AssessmentRecord record, {required bool selected}) {
    final property = record.property;
    final title = property?.title ?? 'Property ${record.propertyId}';
    return div(
      classes: 'asw-ecard${selected ? ' is-selected' : ''}',
      attributes: {
        'role': 'button',
        'tabindex': '0',
        'aria-pressed': selected.toString(),
        'aria-label': 'Assessment for $title',
      },
      events: events(
        onClick: () =>
            setState(() => _selectedAssessmentId = record.assessmentId),
      ),
      [
        div(classes: 'asw-ecard__top', [
          span(classes: 'asw-ecard__title', [Component.text(title)]),
          StatusBadge(
            record.isCompleted ? 'Completed' : 'In progress',
            tone: record.isCompleted ? 'success' : 'warning',
          ),
        ]),
        span(classes: 'asw-ecard__id', [Component.text(record.assessmentId)]),
        div(classes: 'asw-ecard__progress', [
          // The card bar carried no semantics at all: a coloured div and a
          // "2/5 stages" string. A screen reader announced the number but not
          // that it was progress, and nothing exposed the percentage the fill
          // actually encodes. The roles below make the bar and the text agree
          // on one value, taken from the same record field that sizes the fill.
          div(
            [
              span(
                classes: 'asw-ecard__fill',
                styles: Styles(
                  width: Unit.percent(
                    record.progressPercent.clamp(0, 100).toDouble(),
                  ),
                ),
                [],
              ),
            ],
            classes: 'asw-ecard__track',
            attributes: {
              'role': 'progressbar',
              'aria-valuenow':
                  '${record.progressPercent.clamp(0, 100).toInt()}',
              'aria-valuemin': '0',
              'aria-valuemax': '100',
              'aria-valuetext':
                  '${record.completedStages} of ${record.totalStages} stages '
                  'complete, ${record.stagesRemaining} remaining',
              'aria-label': 'Assessment stage progress',
            },
          ),
          span(classes: 'asw-ecard__stages', [
            Component.text(
              '${record.completedStages}/${record.totalStages} stages · '
              '${record.stagesRemaining} remaining',
            ),
          ]),
          button(
            classes: 'asw-ecard__link',
            attributes: {
              'type': 'button',
              'aria-label': 'View the report for $title',
            },
            events: events(onClick: () => _openReport(record)),
            [Icon('visibility', size: 'sm'), Component.text('View report')],
          ),
        ]),
        div(classes: 'asw-ecard__foot', [
          span(classes: 'asw-ecard__updated', [
            Component.text('Updated ${_dateLabel(record.updatedAt)}'),
          ]),
          button(
            classes: 'asw-ecard__remove',
            attributes: {
              'type': 'button',
              'aria-label': 'Remove the assessment for $title',
              'title': 'Remove this assessment',
            },
            events: events(onClick: () => _openDelete(record)),
            [Icon('delete', size: 'sm'), Component.text('Remove')],
          ),
        ]),
      ],
    );
  }

  /// The entry page's right column: the selected record's own details.
  ///
  /// Every figure is read from the record. The participation counts are
  /// nullable — an unset count renders "—", never 0, because a zero would claim
  /// "nobody responded" when the server may simply not know.
  Component _detailPanel(AssessmentRecord record) {
    final property = record.property;
    final currentStage = record.stages
        .where((stage) => stage.number == record.currentStage)
        .firstOrNull;
    final title = property?.title ?? 'Property ${record.propertyId}';
    final businessProfiles = (record.requirements?.isEmpty ?? true) ? '0' : '1';

    return section(classes: 'panel panel--flush asw-entry__detail', [
      div(classes: 'panel__head', [
        span(classes: 'panel__title', [Component.text('Assessment details')]),
        div(classes: 'asw-entry__detailactions', [
          ActionButton(
            'Continue assessment',
            variant: 'secondary',
            icon: 'arrow_forward',
            onClick: () => _openAssessment(
              record.propertyId,
              stage: record.currentStageKey,
            ),
          ),
          ActionButton(
            'View report',
            icon: 'visibility',
            onClick: () => _openReport(record),
          ),
        ]),
      ]),
      div(classes: 'asw-entry__detailbody', [
        div(classes: 'asw-ehero', [
          span(classes: 'asw-ehero__icon', [Icon('home_work', size: 'sm')]),
          div(classes: 'asw-ehero__copy', [
            strong([Component.text(title)]),
            span(classes: 'asw-ehero__sub', [
              Component.text(
                'Location assessment'
                '${property == null ? '' : ' · ${property.propertyType}'}',
              ),
            ]),
          ]),
          StatusBadge(
            record.isCompleted ? 'Completed' : 'In progress',
            tone: record.isCompleted ? 'success' : 'warning',
          ),
        ]),
        div(classes: 'asw-emeta', [
          _metaCell('Assessment ID', record.assessmentId),
          _metaCell('Created by', 'Your account'),
          _metaCell('Created on', _dateLabel(record.createdAt)),
          _metaCell('Last updated', _dateLabel(record.updatedAt)),
        ]),
        div(classes: 'asw-eprogress', [
          div(classes: 'asw-eprogress__head', [
            strong([Component.text('Progress & inputs')]),
            span(classes: 'asw-eprogress__count', [
              Component.text(
                '${record.completedStages} of ${record.totalStages} stages '
                'completed · ${record.stagesRemaining} remaining',
              ),
            ]),
          ]),
          div(classes: 'asw-eprogress__bar', [
            div(classes: 'asw-eprogress__track', [
              span(
                classes: 'asw-eprogress__fill',
                styles: Styles(
                  width: Unit.percent(
                    record.progressPercent.clamp(0, 100).toDouble(),
                  ),
                ),
                [],
              ),
            ]),
            strong([
              Component.text('${record.progressPercent.clamp(0, 100)}%'),
            ]),
          ]),
          p(classes: 'asw-eprogress__stage', [
            Component.text(
              'Current stage: '
              '${currentStage?.title ?? record.nextAction.label}',
            ),
          ]),
          div(classes: 'asw-ekpis', [
            _inputKpi('badge', businessProfiles, 'Business profiles'),
            _inputKpi(
              'apartment',
              '${record.property == null ? 0 : 1}',
              'Selected rentals',
            ),
            _inputKpi(
              'group',
              record.respondentCount?.toString() ?? '—',
              'Respondents',
            ),
            _inputKpi(
              'fact_check',
              record.responseCount?.toString() ?? '—',
              'Survey responses',
            ),
            _inputKpi(
              'public',
              record.externalSourceCount?.toString() ?? '—',
              'External sources',
            ),
          ]),
        ]),
        div(classes: 'asw-ecallout', [
          span(classes: 'asw-ecallout__icon', [
            Icon('description', size: 'sm'),
          ]),
          div(classes: 'asw-ecallout__copy', [
            strong([Component.text('Draft report available to view')]),
            span([
              Component.text(
                'Open the assembled report at any point. Sections without '
                'stored or verified evidence are marked as not available.',
              ),
            ]),
          ]),
        ]),
        div(classes: 'asw-erents', [
          div(classes: 'asw-erents__head', [
            strong([
              Component.text(
                'Selected rentals (${record.property == null ? 0 : 1})',
              ),
            ]),
            span([
              Component.text(
                record.property == null
                    ? 'Listing no longer in the catalogue'
                    : 'Linked to this assessment',
              ),
            ]),
          ]),
          if (property == null)
            div(classes: 'asw-erents__row asw-erents__row--empty', [
              Icon('info', size: 'sm'),
              span([
                Component.text(
                  'The listing for property ${record.propertyId} is no longer '
                  'published, so its details cannot be shown. The assessment '
                  'record itself is unchanged.',
                ),
              ]),
            ])
          else
            div(classes: 'asw-erents__row', [
              span(classes: 'asw-erents__icon', [
                Icon('apartment', size: 'sm'),
              ]),
              div(classes: 'asw-erents__copy', [
                strong([Component.text(property.title)]),
                span([Component.text(property.propertyType)]),
              ]),
            ]),
        ]),
        div(classes: 'asw-entry__danger', [
          span([
            Component.text(
              'Removing an assessment deletes its saved preferences and stage '
              'history permanently.',
            ),
          ]),
          ActionButton(
            'Permanently discard unfinished assessment',
            variant: 'danger-outline',
            icon: 'delete',
            onClick: () => _openDelete(record),
          ),
        ]),
      ]),
    ]);
  }

  /// One cell of the detail panel's four-cell meta grid.
  Component _metaCell(String label, String value) =>
      div(classes: 'asw-emeta__cell', [
        span(classes: 'asw-emeta__label', [Component.text(label)]),
        strong(classes: 'asw-emeta__value', [Component.text(value)]),
      ]);

  /// One "Progress & inputs" tile: icon, figure, label.
  Component _inputKpi(String icon, String value, String label) =>
      div(classes: 'asw-ekpi', [
        span(classes: 'asw-ekpi__icon', [Icon(icon, size: 'sm')]),
        strong(classes: 'asw-ekpi__value', [Component.text(value)]),
        span(classes: 'asw-ekpi__label', [Component.text(label)]),
      ]);

  static const _monthNames = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
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
      // A landscape panel: the saved properties lay out in a two-column grid
      // beside each other instead of stacking into a tall scrolling list.
      panelClass: 'asw-create-dialog',
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
                  () => _selectableFuture = AppLocator
                      .assessmentSelectableProperties
                      .call(),
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
          return div(classes: 'stack stack--md', [
            p(classes: 'small asw-muted', [
              Component.text(
                'Choose the one saved property you want to assess. The '
                'assessment starts at Step 2, because this dialog is Step 1.',
              ),
            ]),
            SearchInput(
              label: 'Select a saved property',
              placeholder: 'Search by property name or ID',
              ariaLabel: 'Search saved properties',
              onInput: (value) => setState(() => _dialogSearch = value),
            ),
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
                  'role': 'radiogroup',
                  'aria-label': 'Saved properties — choose one',
                },
                [for (final item in visible) _dialogChoice(item)],
              ),
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
              _selectedRefs.isEmpty
                  ? 'No property selected'
                  : '1 property selected',
            ),
          ],
        ),
        ActionButton('Cancel', variant: 'secondary', onClick: _closeCreate),
        ActionButton(
          _creating ? 'Creating…' : 'Create Assessment',
          onClick: _selectedRefs.isEmpty || _creating ? null : _createSelected,
        ),
      ],
    );
  }

  /// One saved property as a selectable dialog card.
  ///
  /// A single choice: the control is a radio, so the browser enforces
  /// one-at-a-time and screen readers announce the group as a radiogroup. A
  /// property whose listing could not be resolved stays visible but is never
  /// selectable.
  Component _dialogChoice(SelectableProperty item) {
    final property = item.property;
    final unavailable = property == null;
    final selected = _selectedRefs.contains(item.propertyRef);

    return label(
      classes: [
        'asw-select-card',
        if (selected) 'is-selected',
        if (unavailable) 'asw-select-card--locked',
      ].join(' '),
      [
        input<bool>(
          type: InputType.radio,
          name: 'create-assessment-property',
          value: item.propertyRef,
          checked: selected,
          disabled: unavailable,
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
      title: 'Permanently discard unfinished assessment?',
      ariaLabel: 'Permanently discard unfinished assessment',
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
            'removed permanently only for an eligible unfinished draft. Protected evidence is refused. This cannot be undone — if you want the '
            'property assessed again, starting it later creates a fresh '
            'assessment from stage 1.',
          ),
        ]),
        if (_deleteError != null)
          div(classes: 'notice notice-danger', [Component.text(_deleteError!)]),
      ]),
      actions: [
        ActionButton('Cancel', variant: 'secondary', onClick: _closeDelete),
        ActionButton(
          _deleting ? 'Discarding…' : 'Permanently discard',
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
      showHead: !_openedInPlace,
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
    showHead: !_openedInPlace,
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
          p(classes: 'asw-guidance__kicker', [Component.text('STEP 1 OF 5')]),
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
        span(classes: 'asw-guidance__state', [Component.text('Not started')]),
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
    if (_readinessAssessmentId != record.assessmentId) {
      if (_readinessAssessmentId != null) _checkpoint = null;
      _readinessAssessmentId = record.assessmentId;
      _workflowReadiness = null;
      _readinessError = null;
      _declarationEditing = false;
      Future.microtask(() => _refreshWorkflowReadiness(record.assessmentId));
    }
    final property = record.property;

    // Exactly ONE checkpoint view is on screen — the mockup's five
    // independent steps, navigated by the journey stepper.
    //
    // A checkpoint the user explicitly asked for may be opened for REVIEW even
    // when the server has not marked it enterable: each panel renders its own
    // explicit blocked state, and every write, approval and transition stays
    // gated by server readiness. Viewing a stage grants nothing.
    final requestedKey = _checkpoint ?? record.currentStageKey;
    final selectedKey = _stageKeys.contains(requestedKey)
        ? requestedKey
        : (canViewAssessmentStage(requestedKey, _workflowReadiness)
              ? requestedKey
              : 'business_requirements');
    final selected =
        record.stages.where((stage) => stage.key == selectedKey).firstOrNull ??
        record.stages
            .where((stage) => stage.number == record.currentStage)
            .firstOrNull ??
        record.stages.last;

    return _shell(
      showHead: !_openedInPlace,
      title: 'Location assessment',
      leaf: AssessmentJourneyStepper.displayLabel(selected.key, selected.title),
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
        if (_readinessError != null && selectedKey != 'business_requirements')
          p(classes: 'notice notice-warn', [Component.text(_readinessError!)]),
        if (selectedKey != requestedKey)
          p(classes: 'notice notice-warn', [
            Component.text(
              _workflowReadiness == null
                  ? 'Checking assessment access. The requested stage is not yet verified.'
                  : 'This stage is unavailable until its current server-side requirements are met.',
            ),
          ]),

        // Compact five-step tracker — the checkpoint navigator.
        AssessmentJourneyStepper(
          record: record,
          busy: _busy,
          governedWorkflow: true,
          workflowReadiness: _workflowReadiness,
          selectedStageKey: selected.key,
          onOpenStage: (key) {
            if (key == 'location_evidence') {
              _continueToBusinessReview(record.assessmentId);
            } else {
              _openCheckpoint(key);
            }
          },
        ),

        // One independent checkpoint at a time, each in the reference's own
        // layout: saved-property selection, questionnaire, findings &
        // decision, question review, report review.
        if (selected.key == 'select_property')
          ..._savedPropertiesStep(record, property),
        if (selected.key == 'business_requirements')
          ..._preferencesStep(record, property),
        if (selected.key == 'location_evidence') ...[
          Project1ResearchStagePanel(
            marketplaceAssessmentId: record.assessmentId,
            propertyId: record.propertyId,
            stageNumber: 3,
            onOpenStage: (key) {
              if (canViewAssessmentStage(key, _workflowReadiness)) {
                _openCheckpoint(key);
              }
            },
          ),
          // Governed BDJ research-objective proposals for the current
          // confirmation. Additive: the legacy stage panel above is unchanged,
          // and this panel reads only the objective-proposal endpoints.
          BdjObjectiveProposalPanel(
            marketplaceAssessmentId: record.assessmentId,
          ),
        ],
        if (selected.key == 'ai_explanation')
          Project1ResearchStagePanel(
            marketplaceAssessmentId: record.assessmentId,
            propertyId: record.propertyId,
            stageNumber: 4,
            onOpenStage: (key) {
              if (key == 'location_evidence') {
                _continueToBusinessReview(record.assessmentId);
              } else if (canViewAssessmentStage(key, _workflowReadiness)) {
                _openCheckpoint(key);
              }
            },
          ),
        if (selected.key == 'assessment_report')
          ..._reportStep(record, selected),

        // Stage 3/4 research panels show only server-authorized transitions.
        // Do not use the legacy stage footer: it bypassed research readiness.
        p(classes: 'disclaimer', [
          Component.text(
            'Saved business declarations are planning inputs, not verified '
            'evidence of demand or business viability. Review generated '
            'research questions before they are considered for use.',
          ),
        ]),
      ]),
    );
  }

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
    final future = _selectableFuture ??= AppLocator
        .assessmentSelectableProperties
        .call();
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
                Component.text(total == 0 ? 'None saved' : '1 of $total bound'),
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
    if (bound) span(classes: 'asw-proprow__tag', [Component.text('Bound')]),
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
    // CP-10 DEF-03: M2 now owns the Step 2 questionnaire. The five-question
    // recommender form is retained below because recommendation_scoring.py
    // reads fnb_concept, recommendation_priority and space_size_preference,
    // none of which M2V1 collects — deleting it would silently disable
    // location scoring rather than replace it.
    _m2QuestionnaireSection(record),
  ];

  /// CP-10 DEF-03 / DEF-11: the M2V1 research questionnaire (11 items) inside
  /// Step 2. This is the authoritative business-declaration instrument; every
  /// value still comes from `/api/v1/m2/...` through [M2WorkflowPanel], so no
  /// answer storage, BDJ evaluation, confirmation or BCB logic is duplicated
  /// here.
  ///
  /// `requireExplicitId: true` is the DEF-11 correction. The panel is embedded
  /// in an assessment-specific page, so it must never adopt "the owner's most
  /// recent M2 assessment" — that would show one assessment's answers under
  /// another's heading. Until a verified link exists, it renders an unbound
  /// notice and no editor, which also makes saving impossible.
  /// CP-10F: Step 2 resolves this assessment's M2 record and mounts the real
  /// questionnaire against it.
  ///
  /// The lookup is started from here because Step 2 is the first place the
  /// marketplace assessment id and the M2 panel meet. Nothing is guessed: until
  /// the service returns an id, the panel is not mounted at all.
  Component _m2QuestionnaireSection(AssessmentRecord record) {
    if (_m2LinkFor != record.assessmentId) {
      _m2LinkFor = record.assessmentId;
      _m2LinkStatus = 'idle';
      _m2LinkId = '';
      _m2LinkError = null;
      Future.microtask(() => _resolveM2Link(record.assessmentId));
    }
    return section(classes: 'panel asw-inline', [
      _panelHead(
        icon: 'fact_check',
        title: 'Business declaration (M2 research questionnaire)',
      ),
      div(classes: 'panel__body stack stack--md', [
        _m2LinkBody(record),
        if (_readinessError != null)
          p(classes: 'small asw-muted', [Component.text(_readinessError!)]),
        if ((_workflowReadiness?['stage_3'] as Map?)?['enterable'] == true)
          ActionButton(
            'Continue to Stage 3',
            onClick: () => _continueToBusinessReview(record.assessmentId),
          ),
        if (_readinessError != null && !_declarationEditing)
          ActionButton(
            'Retry progress check',
            variant: 'secondary',
            onClick: () => _refreshWorkflowReadiness(record.assessmentId),
          ),
      ]),
    ]);
  }

  Component _m2LinkBody(AssessmentRecord record) {
    switch (_m2LinkStatus) {
      case 'linked':
        return M2WorkflowPanel(
          assessmentId: _m2LinkId,
          requireExplicitId: true,
          embedded: true,
          marketplaceAssessmentId: record.assessmentId,
          onDeclarationChanged: () {
            // A confirmed declaration is a write followed by a read. Clear the
            // editing hold *and* adopt this assessment id before re-reading, so
            // the refresh cannot no-op and strand the Continue control.
            setState(() {
              _declarationEditing = false;
              _readinessAssessmentId = record.assessmentId;
              _readinessError = null;
            });
            _refreshWorkflowReadiness(record.assessmentId, afterWrite: true);
          },
          onDeclarationEditing: () {
            _readinessRequest++;
            _declarationEditing = true;
            setState(() {
              _workflowReadiness = null;
              _readinessError =
                  'Save and review the changed declaration before continuing.';
            });
          },
        );
      case 'initializing':
        return _m2Notice(
          'Preparing the M2 questionnaire…',
          'Creating this assessment\'s M2 research record. This happens once '
              'per assessment.',
          busy: true,
        );
      case 'error':
        return _m2Notice(
          'The M2 questionnaire could not be resolved',
          _m2LinkError ?? 'The M2 service did not answer.',
          action: ('Try again', () => _resolveM2Link(record.assessmentId)),
        );
      case 'unlinked':
        return _m2Notice(
          'This assessment has no M2 research record yet',
          // The item count is a property of the instrument, which is not known
          // until the link resolves. Naming a number here was wrong the moment
          // a second instrument version existed, so the sentence describes the
          // questionnaire instead of counting it.
          'Initialize it to open the business-declaration questionnaire for '
              'this assessment. Existing M2 records are not reused, and no '
              'other assessment\'s answers are shown.',
          action: (
            'Initialize M2 questionnaire',
            () => _initializeM2Link(record.assessmentId),
          ),
        );
      default:
        return _m2Notice(
          'Resolving the M2 questionnaire…',
          'Looking up the M2 research record linked to this assessment.',
          busy: true,
        );
    }
  }

  Component _m2Notice(
    String title,
    String body, {
    bool busy = false,
    (String, Future<void> Function())? action,
  }) => div(classes: 'bdj-empty', [
    p(classes: 'bdj-empty__title', [Component.text(title)]),
    p(classes: 'bdj-empty__body', [Component.text(body)]),
    if (busy) p(classes: 'small asw-muted', [Component.text('Working…')]),
    if (action != null)
      ActionButton(action.$1, variant: 'secondary', onClick: () => action.$2()),
  ]);

  Future<void> _resolveM2Link(String assessmentId) async {
    if (_m2LinkFor != assessmentId) return;
    final request = ++_m2LinkRequest;
    setState(() {
      _m2LinkStatus = 'loading';
      _m2LinkError = null;
    });
    try {
      final link = await AppLocator.m2.linkForMarketplace(assessmentId);
      if (!mounted || _m2LinkFor != assessmentId || request != _m2LinkRequest) {
        return;
      }
      final id = link?['m2_assessment_id'] as String? ?? '';
      setState(() {
        _m2LinkId = id;
        _m2LinkStatus = id.isEmpty ? 'unlinked' : 'linked';
      });
    } catch (error) {
      if (!mounted || _m2LinkFor != assessmentId || request != _m2LinkRequest) {
        return;
      }
      setState(() {
        _m2LinkStatus = 'error';
        _m2LinkError = _m2FailureText(error);
      });
    }
  }

  Future<void> _initializeM2Link(String assessmentId) async {
    if (_m2LinkFor != assessmentId) return;
    final request = ++_m2LinkRequest;
    setState(() {
      _m2LinkStatus = 'initializing';
      _m2LinkError = null;
    });
    try {
      final link = await AppLocator.m2.initializeForMarketplace(assessmentId);
      if (!mounted || _m2LinkFor != assessmentId || request != _m2LinkRequest) {
        return;
      }
      final id = link['m2_assessment_id'] as String? ?? '';
      if (id.isEmpty) {
        setState(() {
          _m2LinkStatus = 'error';
          _m2LinkError = 'The service returned no M2 assessment.';
        });
        return;
      }
      setState(() {
        _m2LinkId = id;
        _m2LinkStatus = 'linked';
      });
    } catch (error) {
      if (!mounted || _m2LinkFor != assessmentId || request != _m2LinkRequest) {
        return;
      }
      setState(() {
        _m2LinkStatus = 'error';
        _m2LinkError = _m2FailureText(error);
      });
    }
  }

  /// A failure the entrepreneur can act on, without leaking transport detail.
  String _m2FailureText(Object error) {
    if (error is AppFailure) {
      return error.backendCode ?? error.userMessage;
    }
    return 'The M2 service could not be reached.';
  }

  /// The one-sentence objective shown in the aside, derived from the answers.
  String _reviewObjective(AssessmentRecord record) {
    final stored = record.requirements ?? const <String, dynamic>{};
    final concept = _answerText(stored, 'fnb_concept');
    final customers = _answerText(stored, 'target_customers');
    if (concept == null) {
      return 'Choose your business preferences in Step 2 to build a research '
          'objective.';
    }
    if (customers != null) {
      return 'Assess interest in the ${concept.toLowerCase()} you plan to '
          'open and whether ${customers.toLowerCase()} would visit this '
          'location.';
    }
    return 'Assess interest in the ${concept.toLowerCase()} you plan to open '
        'at this location.';
  }

  /// A stored requirement rendered with the questionnaire's own option labels.
  String? _answerText(Map<String, dynamic> stored, String id) {
    final raw = stored[id];
    if (raw == null) return null;
    final question = _questions.firstWhere((item) => item.id == id);
    if (raw is List) {
      final parts = [for (final item in raw) _optionCaption(question, '$item')];
      return parts.isEmpty ? null : parts.join(', ');
    }
    final text = _optionCaption(question, '$raw');
    return text.isEmpty ? null : text;
  }

  String _optionCaption(
    ({
      String id,
      String prompt,
      String help,
      String kind,
      List<(String, String)> options,
    })
    q,
    String token,
  ) {
    for (final (value, caption) in q.options) {
      if (value == token) return caption;
    }
    return token.replaceAll('_', ' ');
  }

  // ------------------------------------------------------- step 5: report view

  /// Step 5 is the **checkpoint**, not the document (user correction: the final
  /// report applies to "View report" only). It states what the report contains
  /// and what is still missing, then hands over to the assembled report — which
  /// opens in place via [_openReport] and comes back here on Back.
  /// Step 5 body: the customer questionnaire review.
  ///
  /// Replaces the old "report contents" summary that used to sit here. The
  /// report document itself is untouched — it still opens from "View report"
  /// on the assessment card and in the details panel, so this checkpoint no
  /// longer duplicates that table. Stage completion lives inside the
  /// questionnaire component, beside the design's own preview-only controls.
  List<Component> _reportStep(AssessmentRecord record, AssessmentStage stage) {
    if (_previewAssessmentId != record.assessmentId) {
      _previewAssessmentId = record.assessmentId;
      _previewFuture = _api.questionnairePreview(record.assessmentId);
    }
    return [
      FutureBuilder<ApiResult<QuestionnairePreviewStatus>>(
        future: _previewFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return p([Component.text('Checking questionnaire sources…')]);
          }
          final result = snapshot.data;
          if (result?.ok != true ||
              result?.value == null ||
              result!.value!.assessmentId != record.assessmentId) {
            return section(classes: 'panel asw-inline', [
              p([
                Component.text(
                  'Questionnaire source could not be verified. No questions are shown.',
                ),
              ]),
              button(
                attributes: const {'type': 'button'},
                onClick: () => setState(
                  () => _previewFuture = _api.questionnairePreview(
                    record.assessmentId,
                  ),
                ),
                [Component.text('Retry questionnaire source')],
              ),
            ]);
          }
          // The preview contract currently reports UNAVAILABLE with an empty
          // item list, so no rows are invented here. The server's own reason is
          // passed through verbatim for the blocked state.
          final preview = result.value!;
          return CustomerQuestionnaireStep5(
            assessmentId: record.assessmentId,
            rows: const [],
            blockedReason: preview.reason,
            onBack: () => _openCheckpoint('ai_explanation'),
            busy: _busy,
            stageComplete: false,
            onMarkComplete: null,
          );
        },
      ),
    ];
  }

  /// The assembled report document, opened in place from "View report".
  ///
  /// It replaces the tab's content (no navigation) and returns to whatever
  /// opened it when Back is pressed — the entry page or this checkpoint.
  Component _reportDocument(AssessmentRecord record) {
    final property = record.property;
    return _shell(
      title: 'Assessment report',
      eyebrow: 'Entrepreneur workspace',
      leaf: 'Assessment report',
      subtitle: property == null
          ? 'Property ${record.propertyId}'
          : '${property.title} · ${property.address}, ${property.city}',
      actions: [
        ActionButton(
          'Back',
          variant: 'secondary',
          icon: 'arrow_back',
          onClick: _closeReport,
        ),
        ActionLink(
          'Assessment History',
          href: '/entrepreneur/assessments/history',
          variant: 'secondary',
        ),
      ],
      child: FutureBuilder<_ReportBundle>(
        future: _report(record),
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return div(classes: 'stack stack--md', [
              Skeleton(variant: 'title'),
              Skeleton(variant: 'block', count: 3),
            ]);
          }
          final bundle = snapshot.data;
          final result = bundle?.report;
          final payload = result?.ok == true ? result!.value : null;
          if (payload == null) {
            return section(classes: 'panel asw-inline', [
              _panelHead(icon: 'description', title: 'Assessment report'),
              div(classes: 'panel__body', [
                EmptyState(
                  title: 'The report could not be assembled',
                  body:
                      result?.failure?.message ??
                      'The report service returned no readable payload.',
                  action: ActionButton(
                    'Try again',
                    onClick: () => setState(() => _reportFuture = null),
                  ),
                ),
              ]),
            ]);
          }
          return AssessmentReportView(
            report: payload,
            record: record,
            // Legacy in-memory review candidates have no verified provenance.
            register: const [],
            decisions: const {},
            scope: _reportScope(record),
            objective: _reviewObjective(record),
            extraQuestions: const [],
            // Development-only: the synthetic Q01 demonstration appears in this
            // same report, in the questionnaire section beside R03. `null` in
            // every production build, because the gate is a compile-time
            // constant that defaults to false. It grants no admission — the
            // section it renders stays HELD and non-reportable.
            q01Preview: syntheticPreviewEnabled
                ? Q01SyntheticPreview.tryFromFixture()
                : null,
            // Development-only: the real EE-01 measurement readback for R03.
            // Same compile-time gate as the Q01 preview, and independently
            // `null` when the fixture is not a held, non-disclosing payload.
            //
            // Passing it does not draw it. The report binds a readback to the
            // assessment named in its provenance, and this fixture belongs to
            // the FC4-D synthetic assessment — so on a workspace assessment it
            // is dropped and R03 keeps its held state. There is no live
            // campaign→assessment binding to read here yet; see
            // RT_E2E_01_SOURCE_TRACEABILITY.md.
            measurementChart: syntheticPreviewEnabled
                ? MeasurementChartPreview.tryFromFixture()
                : null,
            // RP-13: the confirmed business description this assessment is
            // bound to. `null` when the read failed, which leaves section 02 in
            // its declared/held state rather than inventing a description.
            businessDescription: bundle?.business,
            // EX-04: the explanation the report may render. `null` when the read
            // failed or the module is available (no per-item read exists yet), in
            // which case the report renders no explanation card at all.
            explanation: bundle?.explanation,
            backLabel: 'Back to assessment',
            onBack: _closeReport,
          );
        },
      ),
    );
  }

  /// The declared business as label/value pairs for the report's business
  /// description. Values come from the saved requirements through the
  /// questionnaire's own option captions, so the report and Step 2 cannot
  /// describe the same answer two different ways.
  List<(String, String)> _reportScope(AssessmentRecord record) {
    final stored = record.requirements ?? const <String, dynamic>{};
    final rows = <(String, String)>[];
    for (final key in const [
      'fnb_concept',
      'service_model',
      'target_customers',
      'recommendation_priority',
      'space_size_preference',
    ]) {
      final value = _answerText(stored, key);
      if (value == null || value.isEmpty) continue;
      rows.add((_questionNavLabels[key] ?? key, value));
    }
    final budget = stored['max_monthly_rent_myr'] ?? stored['max_budget_rm'];
    if (budget != null) rows.add(('Rental ceiling', 'RM $budget/month'));
    final area = stored['min_floor_area_sqft'] ?? stored['min_size_sqft'];
    if (area != null) rows.add(('Minimum floor area', '$area sq ft'));
    final access = stored['customer_access_mode'];
    if (access is String && access.isNotEmpty) {
      rows.add(('Customer access', access.replaceAll('_', ' ')));
    }
    return rows;
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
              )
              as Component;
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

  /// One business-preference question (five-question Recommender V3,
  /// requirements schema v3, 2026-11-11).
  ///
  /// `kind` is `single` or `multi`; `options` are (token, label) pairs.
  /// Tokens are what the backend validates, so a label can change without
  /// rewriting a saved answer. Q4 shows the five V3 priorities; the two
  /// legacy v2 tokens stay valid server-side for pre-V3 records, which seed
  /// from storage without being re-interpreted.
  static const List<
    ({
      String id,
      String prompt,
      String help,
      String kind,
      List<(String, String)> options,
    })
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

  /// Human-readable labels for saved V3 answers shown in the report.
  static const Map<String, String> _questionNavLabels = {
    'fnb_concept': 'Business type',
    'service_model': 'Service model',
    'target_customers': 'Target customers',
    'recommendation_priority': 'Choosing priority',
    'space_size_preference': 'Space size',
  };

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
    'Business review and research goals',
    'Competitor pressure, accessibility, catchment demand and the built '
        'environment, as measured by the geospatial analysis pipeline.',
  ),
  'ai_explanation': (
    'AI recommendation explanation',
    'Why the property scored what it did, from the recommendation model. '
        'Needs a trained model artifact on the server.',
  ),
  'assessment_report': (
    'Publish questionnaire',
    'Review the customer questionnaire, then publish it or keep it as a '
        'draft. The consolidated report stays available from "View report".',
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

/// The report document and the RP-13 business description read together.
///
/// They are one future because they are one document: section 02 is part of the
/// report, so a page that rendered the report without it and then again with it
/// would flicker between two different documents. [business] is null when the
/// description read failed — the section then renders its held state, and the
/// failure never masks a report that did assemble.
final class _ReportBundle {
  final ApiResult<AssessmentReportPayload> report;
  final BusinessDescription? business;

  /// The explanation the report may render, or `null` when none could be read.
  final ExplanationPanel? explanation;

  const _ReportBundle(this.report, this.business, [this.explanation]);
}
