import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_router/jaspr_router.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/assessment_journey_stepper.dart';
import '../../components/project1_read_panel.dart';
import '../../components/ui.dart';
import '../../data/app_locator.dart';
import '../../data/assessment_api.dart';
import '../../data/assessment_format.dart';
import '../../layouts/app_layout.dart';

/// The web decision-support workflow, in five persisted stages.
///
/// ```text
/// .crumbs                       Home › Assessments › Assessment workspace
/// AssessmentJourneyStepper      five stage controls + the ONLY progress bar
/// .asw-property-disclosure     collapsed detail for the bound listing
/// .asw-m2-workspace            Stage 2 questionnaire (3 columns, UI preview)
/// .asw-inline                  Stage 3 evidence, opened from the stepper
/// .disclaimer                  decision-support limits
/// ```
///
/// Stage 1 is the saved-property shortlist. Stages 4 and 5 are separate
/// routes (`/entrepreneur/explanation`, `/entrepreneur/report`) linked from
/// the journey stepper. Nothing here decides progress locally: stage status,
/// `current_stage` and `progress_percent` all come from the persisted record
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

  /// Optional `?queue=` — the other properties selected alongside
  /// [propertyId] in one Stage 1 Continue, as comma-separated catalogue refs.
  ///
  /// This lives in the URL rather than only in [State] memory. A router that
  /// rebuilds this page, a browser reload, a shared link or back/forward
  /// navigation would otherwise discard the shortlist and the workspace would
  /// fall back to a single property — the "one to one" behaviour this queue
  /// exists to remove. Refs are identifiers only: every assessment record,
  /// questionnaire, evidence set and report is still fetched per property
  /// from the backend.
  final String queue;

  const AssessmentWorkspacePage({
    super.key,
    required this.propertyId,
    this.stage = '',
    this.queue = '',
  });

  @override
  State<AssessmentWorkspacePage> createState() => _AssessmentWorkspaceState();
}

class _AssessmentWorkspaceState extends State<AssessmentWorkspacePage> {
  static const _api = AssessmentApi();

  /// The stages whose body lives inside the workspace. Stage 3 (Location
  /// evidence) now hosts the BDJ/QJ/QG review portal and stage 4 (AI
  /// explanation) hosts the customer questionnaire preview; the remaining
  /// stages hand over to pages that already exist.
  static const _inlineStages = {
    'business_requirements',
    'location_evidence',
    'ai_explanation',
  };

  late Future<_Load> _future = _open(component.propertyId);

  /// Which in-page stage panel is expanded. Seeded from `?stage=` in
  /// [initState] so a shared link lands on the panel it names.
  String? _openStage;

  bool _busy = false;
  bool _selectedPropertyExpanded = false;
  String? _notice;
  AssessmentFailure? _writeError;

  Future<ApiResult<EvidencePayload>>? _evidenceFuture;

  // --- Stage 1: the saved-property selector ---------------------------------
  //
  // Stage 1 is the workspace's entry state: the entrepreneur picks one of the
  // properties their account has saved. The list comes from the authenticated
  // saved-properties endpoint (the account's own rows) and every entry is
  // resolved against the catalogue, so the cards show real listing data.

  /// The saved properties, resolved against the catalogue. Null until the
  /// first read completes.
  Future<AssessmentSelectableProperties>? _selectableFuture;

  /// The account's assessment history, used to badge a saved property that
  /// already has an assessment. A failed read omits the badge — it never
  /// invents a status.
  Future<Map<String, AssessmentRecord>>? _historyFuture;

  /// The resolved history, keyed by catalogue ref. Empty until the read
  /// completes; a failed read leaves it empty.
  Map<String, AssessmentRecord> _history = const {};

  /// The Stage 1 search query.
  String _search = '';

  /// The catalogue refs the entrepreneur selected, in selection order.
  ///
  /// Up to three properties form the shortlist. Each still gets its OWN
  /// independent assessment record: the backend's create-or-resume contract is
  /// per property (one `property_id` per assessment row) and there is no
  /// combined multi-property prediction or report, so this list never becomes
  /// a single batched record.
  static const int _maxSelections = 3;
  final List<String> _selectedRefs = <String>[];

  /// What the last Continue actually did, one entry per selected property.
  /// Stage 1 renders this as the selected-assessments overview: created,
  /// resumed or refused, with a way into each independent assessment.
  ///
  /// This is an in-session *detail* cache (titles, resumed flags, refusals).
  /// Membership of the queue itself comes from [component] through the URL,
  /// never from here, so the queue cannot disappear when this state is lost.
  List<_SelectionOutcome> _outcomes = const [];

  /// Reads `?queue=` defensively: empty parts and duplicates are dropped and
  /// the list is capped at the same three properties Stage 1 allows, so a
  /// hand-edited link cannot inflate the workspace.
  static List<String> _parseQueue(String raw) {
    final refs = <String>[];
    for (final part in raw.split(',')) {
      final ref = part.trim();
      if (ref.isEmpty || refs.contains(ref)) continue;
      if (refs.length >= _maxSelections) break;
      refs.add(ref);
    }
    return refs;
  }

  /// The evaluation queue, always derived from the current URL. Because it is
  /// a getter there is nothing to synchronise in [didUpdateComponent].
  List<String> get _queueRefs => _parseQueue(component.queue);

  /// Refs the last Continue actually started or resumed. Used to seed the
  /// queue on the first navigation away from Stage 1.
  List<String> get _readyRefs => [
    for (final outcome in _outcomes)
      if (!outcome.failed) outcome.ref,
  ];

  @override
  void initState() {
    super.initState();
    if (_inlineStages.contains(component.stage)) _openStage = component.stage;
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
    _openStage = _inlineStages.contains(component.stage) ? component.stage : null;
    _selectedPropertyExpanded = false;
    _evidenceFuture = null;
    _notice = null;
    _writeError = null;
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
    _future = _open(propertyId);
  });

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
      _future = Future.value(_Started(started.assessment));
      _notice = started.created
          ? 'Assessment started. Stage 1 is recorded as complete because '
                'the property is now bound to it.'
          : 'Your existing assessment for this property was reopened. '
                'Nothing was duplicated.';
    });
  }


  void _toggleStage(String key) => setState(() {
    _openStage = _openStage == key ? null : key;
    _notice = null;
    _writeError = null;
    if (_openStage == 'location_evidence') {
      _evidenceFuture ??= _api.evidence(component.propertyId);
    }
  });


  /// The account's saved properties. One read of the saved list, then one
  /// catalogue read per distinct ref (see [GetAssessmentSelectableProperties]).
  Future<AssessmentSelectableProperties> _loadSelectable() =>
      AppLocator.assessmentSelectableProperties.call();

  /// The account's assessments, keyed by catalogue ref, so a saved property
  /// that already has an assessment can say so before anything is created.
  Future<Map<String, AssessmentRecord>> _loadHistory() async {
    final result = await _api.history(limit: 50, offset: 0);
    if (!result.ok) return const {};
    return {for (final record in result.value!.items) record.propertyId: record};
  }

  /// Re-runs the saved-property read. The shortlist is cleared with it: the
  /// list itself may have changed, so stale refs must not survive a reload.
  void _reloadSelectable() => setState(() {
        _selectableFuture = _loadSelectable();
        _historyFuture = _loadHistory();
        _selectedRefs.clear();
        _outcomes = const [];
        _search = '';
        _notice = null;
        _writeError = null;
      });

  /// Toggles one saved property in the shortlist.
  ///
  /// A property whose details could not be resolved never reaches this
  /// method (its checkbox is disabled), duplicates are impossible because the
  /// toggle checks membership first, and a fourth property cannot be added.
  /// Searching and filtering never touch the selection — the checkbox state
  /// is derived from this list, not from what is currently visible.
  void _toggleSelection(String propertyRef) => setState(() {
        if (_selectedRefs.contains(propertyRef)) {
          _selectedRefs.remove(propertyRef);
        } else if (_selectedRefs.length < _maxSelections) {
          _selectedRefs.add(propertyRef);
        }
        // A changed shortlist invalidates the previous Continue's result.
        _outcomes = const [];
        _notice = null;
        _writeError = null;
      });

  /// The in-page stage panel that belongs to the record's current stage.
  ///
  /// Null when the backend's next stage is one of the separate pages (or when
  /// every stage is recorded), because those are opened by their own links.
  static String? _nextInlineStage(AssessmentRecord record) {
    final key = record.currentStageKey;
    return _inlineStages.contains(key) ? key : null;
  }

  /// The workspace deep link for one property. Naming [stage] is what makes
  /// the journey actually advance: `initState` / `didUpdateComponent` expand
  /// that panel instead of dropping the entrepreneur on a closed stage list.
  ///
  /// Every link also carries the evaluation queue, so "Evaluate" on a second
  /// property keeps the first one reachable and a reload cannot collapse the
  /// shortlist back to a single assessment. Pass [queue] only when seeding the
  /// queue from a fresh Stage 1 Continue; otherwise the current URL is the
  /// source of truth.
  String _workspaceHref(
    String propertyRef,
    String? stage, {
    Iterable<String>? queue,
  }) {
    final refs = (queue ?? _queueRefs).toList();
    final href = StringBuffer(
      '/entrepreneur/assessments?id=${Uri.encodeQueryComponent(propertyRef)}',
    );
    if (stage != null) {
      href.write('&stage=${Uri.encodeQueryComponent(stage)}');
    }
    if (refs.isNotEmpty) {
      href.write('&queue=');
      href.write(refs.map(Uri.encodeQueryComponent).join(','));
    }
    return href.toString();
  }

  /// Continues with EVERY selected property.
  ///
  /// The backend's create-or-resume contract is per property (one `property_id`
  /// per assessment row), so each selection is processed on its own and the
  /// three requests run sequentially on purpose: each is an independent server
  /// transaction that checks the catalogue, resumes the caller's existing
  /// record (never duplicated) or creates a new one only for a property this
  /// account has saved. There is no batch endpoint and no combined assessment
  /// to reuse.
  ///
  /// A per-property failure never aborts the other selections — it is reported
  /// for that property in the overview below.
  ///
  /// One OR several successful selections advance straight into the first
  /// assessment's workspace with its current stage panel open. The full set of
  /// outcomes is kept as an evaluation queue, so the workspace can switch to
  /// every other selected property without returning to Stage 1. A selection
  /// that failed is kept in that queue as an honest "unavailable" row.
  /// Only when EVERY selection failed does the flow stay on Stage 1, where
  /// each refusal is shown. Nothing here merges the records: the backend has
  /// exactly one assessment row per property.
  Future<void> _continueSelected() async {
    if (_busy || _selectedRefs.isEmpty) return;
    setState(() {
      _busy = true;
      _writeError = null;
      _notice = null;
      _outcomes = const [];
    });

    final outcomes = <_SelectionOutcome>[];
    for (final ref in _selectedRefs) {
      // 1. Is there already an assessment for this property?
      final existing = await _api.byProperty(ref);
      if (!mounted) return;
      if (!existing.ok) {
        // Could not even check (network, 403, unknown ref) — report it for
        // this property instead of guessing whether a record exists.
        outcomes.add(_SelectionOutcome(ref: ref, failure: existing.failure));
        continue;
      }
      final record = existing.value;
      if (record != null) {
        outcomes.add(_SelectionOutcome(
          ref: ref,
          title: record.property?.title,
          resumed: true,
          nextStage: _nextInlineStage(record),
        ));
        continue;
      }

      // 2. Otherwise the server creates it — and refuses when the property is
      //    not on this account's saved list.
      final started = await _api.start(ref);
      if (!mounted) return;
      if (!started.ok) {
        outcomes.add(_SelectionOutcome(ref: ref, failure: started.failure));
        continue;
      }
      final startedValue = started.value!;
      outcomes.add(_SelectionOutcome(
        ref: ref,
        title: startedValue.assessment.property?.title,
        resumed: !startedValue.created,
        nextStage: _nextInlineStage(startedValue.assessment),
      ));
    }

    // Refresh the badges from the real records rather than guessing which
    // rows the Continue created.
    final history = await _loadHistory();
    if (!mounted) return;

    // Advance for one OR several selections: open the first successful
    // assessment at its current in-page stage and keep the whole outcome set
    // as the evaluation queue rendered inside the workspace. Only when every
    // selection failed do we stay here, where each refusal is visible instead
    // of navigating to a record that was never created or resumed.
    final ready = outcomes.where((o) => !o.failed).toList();
    if (ready.isNotEmpty) {
      final first = ready.first;
      final queueRefs = ready.map((o) => o.ref).toList();
      setState(() {
        _busy = false;
        _outcomes = outcomes;
        _notice = null;
        _writeError = null;
        _history = history;
      });
      // The queue goes INTO the URL. Even if the router discards this State
      // while matching the new location, the next page still knows about all
      // the assessments the entrepreneur selected.
      context.replace(
        _workspaceHref(first.ref, first.nextStage, queue: queueRefs),
      );
      return;
    }

    setState(() {
      _busy = false;
      _outcomes = outcomes;
      _history = history;
      _notice = 'No assessment could be started. See the reason for each '
          'property below.';
    });
  }



  // ------------------------------------------------------------------ render

  @override
  Component build(BuildContext context) {
    if (component.propertyId.isEmpty) {
      return _stage1();
    }

    return FutureBuilder<_Load>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return _shell(
            title: 'Location Assessment Workspace',
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
            title: 'Location Assessment Workspace',
            child: EmptyState(
              title: 'The assessment could not be loaded',
              body:
                  'The workspace received no response for this property. Try '
                  'again — nothing has been changed.',
              action: ActionButton(
                'Try again',
                onClick: () => _reload(component.propertyId),
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

  Component _shell({
    required String title,
    String? subtitle,
    List<Component> actions = const [],
    required Component child,
  }) => AppLayout(
    role: AppRole.entrepreneur,
    currentRoute: '/entrepreneur/assessments',
    title: title,
    eyebrow: 'Location assessment',
    subtitle: subtitle,
    actions: actions,
    child: child,
  );

  // --------------------------------------------------------------- stage 1 UI

  /// Stage 1 — Select Property.
  ///
  /// The account's real saved properties, read from the authenticated
  /// saved-properties endpoint and resolved against the catalogue. Opening
  /// this screen never starts an assessment: only the Continue action asks
  /// the backend to create or resume one.
  Component _stage1() {
    final selectable = _selectableFuture ??= _loadSelectable();
    _historyFuture ??= _loadHistory().then((records) {
      if (mounted) setState(() => _history = records);
      return records;
    });

    return _shell(
      title: 'Location Assessment',
      subtitle:
          'Choose a saved commercial property to begin your location '
          'assessment.',
      actions: const [
        ActionLink(
          'Assessment History',
          href: '/entrepreneur/assessments/history',
          variant: 'secondary',
        ),
      ],
      child: FutureBuilder<AssessmentSelectableProperties>(
        future: selectable,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return div(classes: 'stack stack--md', [
              Skeleton(variant: 'block'),
              Skeleton(variant: 'row', count: 4),
            ]);
          }
          final data = snapshot.data;
          if (data == null) {
            return EmptyState(
              title: 'Your saved properties did not load',
              body:
                  'The workspace received no response for your saved list. '
                  'Nothing has been changed.',
              action: ActionButton('Try again', onClick: _reloadSelectable),
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
          if (data.hasError) {
            return EmptyState(
              title: 'Your saved properties could not be loaded',
              body: data.errorMessage!,
              action: ActionButton('Try again', onClick: _reloadSelectable),
            );
          }
          if (data.isEmpty) {
            return const EmptyState(
              title: 'No saved properties yet',
              body:
                  'No saved properties yet. Save a property from Explore to '
                  'start a location assessment.',
              action: ActionLink(
                'Explore Properties',
                href: '/entrepreneur/explore',
                variant: 'primary',
              ),
            );
          }
          return _stage1List(data);
        },
      ),
    );
  }

  /// The Stage 1 body: the five-stage order, the saved-property list and the
  /// Continue action.
  Component _stage1List(AssessmentSelectableProperties data) {
    final visible = data.search(_search);
    // The shortlist is resolved against the WHOLE saved list, never the
    // filtered view, so searching cannot hide or drop a selection. Only
    // resolved listings take part — the summary rows render listing data.
    final selectedItems = <SelectableProperty>[
      for (final ref in _selectedRefs)
        for (final item in data.properties)
          if (item.propertyRef == ref && item.property != null) item,
    ];
    final atLimit = _selectedRefs.length >= _maxSelections;
    final canContinue = _selectedRefs.isNotEmpty && !_busy;

    return div(classes: 'stack stack--sections', [
      _stage1Progress(),

      // Saved refs the catalogue no longer holds. Reported, never selectable.
      if (data.unresolvedRefs.isNotEmpty)
        div(classes: 'notice notice-warn', [
          div([
            Component.text(
              '${data.unresolvedRefs.length} saved '
              '${data.unresolvedRefs.length == 1 ? 'property is' : 'properties are'} '
              'no longer in the property catalogue, so they cannot be '
              'assessed. Remove them from your saved list to clear this '
              'notice.',
            ),
          ]),
        ]),

      section(classes: 'panel', [
        div(classes: 'panel__head', [
          span(classes: 'panel__title', [
            Component.text('Your Saved Properties'),
          ]),
          span(
            classes: 'asw-select-count',
            attributes: const {'aria-live': 'polite'},
            [
              Component.text(
                '${_selectedRefs.length} of $_maxSelections selected',
              ),
            ],
          ),
        ]),
        div(classes: 'panel__body stack stack--md', [
          SearchInput(
            label: 'Search saved properties',
            placeholder: 'Search saved properties…',
            ariaLabel: 'Search saved properties',
            onInput: (value) => setState(() => _search = value),
          ),
          if (atLimit)
            div(classes: 'notice notice-info asw-select-limit', [
              Component.text(
                'You have selected the maximum of $_maxSelections properties. '
                'Remove one below to choose a different property.',
              ),
            ]),
          if (visible.isEmpty)
            p(classes: 'body', [
              Component.text(
                _search.trim().isEmpty
                    ? 'None of your saved properties can be assessed right '
                          'now.'
                    : 'No saved property matches “${_search.trim()}”.',
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
              [for (final item in visible) _stage1Card(item, atLimit)],
            ),
        ]),
      ]),

      // Compact shortlist. Replaces the old full-property preview: three
      // oversized images pushed the Continue action off-screen.
      if (selectedItems.isNotEmpty)
        _SelectedSummary(
          items: selectedItems,
          maxCount: _maxSelections,
          onRemove: _toggleSelection,
        ),

      div(classes: 'asw-select__actions', [
        ActionLink(
          'Assessment History',
          href: '/entrepreneur/assessments/history',
          variant: 'secondary',
        ),
        button(
          classes: 'btn btn--primary',
          attributes: {
            'type': 'button',
            if (!canContinue) 'disabled': '',
            'aria-disabled': canContinue ? 'false' : 'true',
          },
          events: events(onClick: () {
            if (_selectedRefs.isEmpty || _busy) return;
            _continueSelected();
          }),
          [
            Component.text(
              _busy
                  ? 'Starting…'
                  : _selectedRefs.length <= 1
                      ? 'Continue Assessment'
                      : 'Continue with ${_selectedRefs.length} assessments',
            ),
          ],
        ),
      ]),

      if (_outcomes.isNotEmpty) _outcomesPanel(),

      if (_notice != null) _successNotice(_notice!),
      if (_writeError != null) _errorNotice(_writeError!),
    ]);
  }

  /// What the backend did for each selected property on Continue, with a way
  /// into every independent assessment. This is navigation between the
  /// selected properties — NOT a cross-property comparison; the backend has
  /// no combined prediction or report contract.
  Component _outcomesPanel() {
    return section(classes: 'panel asw-outcomes', [
      div(classes: 'panel__head', [
        span(classes: 'panel__title', [
          Component.text('Selected assessments'),
        ]),
      ]),
      div(classes: 'panel__body stack stack--md', [
        p(classes: 'small asw-muted', [
          Component.text(
            _outcomes.any((o) => !o.failed)
                ? 'Every selected property has its own independent assessment '
                      'record — its own questionnaire, evidence, prediction '
                      'and report. Continue opens the first one; the '
                      'workspace has a switcher for the rest.'
                : 'Every selected property has its own independent assessment '
                      'record. None of them could be started this time; each '
                      'refusal is shown below.',
          ),
        ]),
        for (final outcome in _outcomes)
          div(
            classes: [
              'asw-outcome',
              if (outcome.failed) 'asw-outcome--failed',
            ].join(' '),
            [
              div(classes: 'asw-outcome__main', [
                span(classes: 'asw-outcome__title', [
                  Component.text(
                    outcome.title ?? 'Property ${outcome.ref}',
                  ),
                ]),
                span(classes: 'small', [
                  Component.text(
                    outcome.failed
                        ? outcome.failure!.message
                        : outcome.resumed
                            ? 'Existing assessment reopened — nothing was '
                                'duplicated.'
                            : 'New assessment created. Stage 1 is recorded as '
                                'complete.',
                  ),
                ]),
              ]),
              if (!outcome.failed)
                ActionLink(
                  'Open assessment',
                  href: _workspaceHref(
                    outcome.ref,
                    outcome.nextStage,
                    queue: _readyRefs,
                  ),
                  variant: 'secondary',
                ),
            ],
          ),
      ]),
    ]);
  }

  /// One saved property as a selectable card.
  ///
  /// The checkbox is the real control: up to three cards can be selected,
  /// the keyboard toggles them like any native checkbox, and a property whose
  /// listing could not be resolved is disabled rather than silently
  /// unselectable. When the shortlist is full the remaining checkboxes are
  /// disabled so a fourth property cannot be added.
  Component _stage1Card(SelectableProperty item, bool atLimit) {
    final property = item.property;
    final unavailable = property == null;
    final selected = _selectedRefs.contains(item.propertyRef);
    final locked = !selected && (atLimit || unavailable);
    final record = _history[item.propertyRef];

    return label(
      classes: [
        'asw-select-card',
        if (selected) 'is-selected',
        if (locked) 'asw-select-card--locked',
      ].join(' '),
      [
        input<bool>(
          type: InputType.checkbox,
          name: 'saved-property',
          value: item.propertyRef,
          checked: selected,
          disabled: locked,
          onChange: (_) => _toggleSelection(item.propertyRef),
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
            div(classes: 'asw-select-card__title-row', [
              span(classes: 'asw-select-card__title', [
                Component.text(property?.title ?? item.propertyRef),
              ]),
              // Only shown when the account really has a record for this
              // property — the history read, not a guess.
              if (record != null)
                Pill(
                  record.isCompleted
                      ? 'Assessment complete'
                      : 'Assessment in progress',
                  tone: record.isCompleted ? 'success' : 'action',
                ),
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

  /// The five-stage order for Stage 1.
  ///
  /// It states the order only. No stage reads as complete here — completion
  /// comes from the backend's persisted record.
  Component _stage1Progress() {
    const stages = [
      ('select_property', 'Select property'),
      ('business_requirements', 'Business preferences'),
      ('location_evidence', 'Location evidence'),
      ('ai_explanation', 'AI explanation'),
      ('assessment_report', 'Assessment report'),
    ];
    return section(
      classes: 'sw-assessment-journey',
      attributes: const {'aria-label': 'Location assessment stages'},
      [
        div(classes: 'sw-assessment-journey__heading', [
          div(classes: 'sw-assessment-journey__heading-text', [
            span(classes: 'sw-assessment-journey__eyebrow', [
              Component.text('YOUR ASSESSMENT JOURNEY'),
            ]),
            h2(classes: 'sw-assessment-journey__title', [
              Component.text('Five stages to your location decision'),
            ]),
          ]),
          div(classes: 'sw-assessment-journey__count', [
            strong([Component.text('0 / 5')]),
            span([Component.text(' completed')]),
          ]),
        ]),
        div(classes: 'sw-assessment-journey__scroll', [
          ol(classes: 'sw-assessment-journey__steps', [
            for (final (index, stage) in stages.indexed)
              li(
                classes:
                    'sw-assessment-journey__step '
                    'sw-assessment-journey__step--'
                    '${index == 0 ? 'current' : 'upcoming'}',
                [
                  div(
                    classes: 'sw-assessment-journey__control',
                    attributes: {
                      'aria-label':
                          'Step ${index + 1}: ${stage.$2} — '
                          '${index == 0 ? 'Current stage' : 'Not started'}',
                    },
                    [
                      span(classes: 'sw-assessment-journey__circle', [
                        Component.text('${index + 1}'),
                      ]),
                      span(classes: 'sw-assessment-journey__step-title', [
                        Component.text(stage.$2),
                      ]),
                      span(classes: 'sw-assessment-journey__step-status', [
                        Component.text(
                          index == 0 ? 'Current stage' : 'Not started',
                        ),
                      ]),
                    ],
                  ),
                ],
              ),
          ]),
        ]),
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
        ActionButton('Try again', onClick: () => _reload(component.propertyId))
            as Component?,
      ),
    };

    return _shell(
      title: 'Location Assessment Workspace',
      subtitle: 'Property ${component.propertyId}',
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
    title: 'Location Assessment Workspace',
    subtitle: 'Assessment not started',
    actions: const [
      ActionLink(
        'Assessment History',
        href: '/entrepreneur/assessments/history',
        variant: 'secondary',
      ),
      ActionLink(
        'Back to Explore',
        href: '/entrepreneur/explore',
        variant: 'secondary',
      ),
    ],
    child: div(classes: 'stack stack--sections', [
      _crumbs(),
      if (_writeError != null) _errorNotice(_writeError!),
      section(classes: 'panel', [
        div(classes: 'panel__head', [
          span(classes: 'panel__title', [
            Component.text('Start this assessment'),
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
    final property = record.property;
    final stage2Open = _openStage == 'business_requirements';
    return _shell(
      // The primary Stage 2 headline is the instrument itself. Stage
      // identification stays as secondary context below, never as a headline.
      title: stage2Open
          ? 'Café planning questionnaire'
          : 'Location Assessment Workspace',
      subtitle: stage2Open
          ? 'Location decision support for your café venture'
          : property == null
              ? 'Property ${record.propertyId}'
              : '${property.title} · ${property.address}, ${property.city}',
      actions: [
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
      child: div(classes: 'stack stack--sections asw-stage2-shell', [
        _crumbs(),

        if (_notice != null) _successNotice(_notice!),

        if (_writeError != null) _errorNotice(_writeError!),

        // --- Journey ------------------------------------------------------
        // ONE progress indicator only: the stepper renders the journey
        // heading, the five stage controls and its own saved-record progress
        // bar. The duplicate "Assessment progress" panel was removed.
        AssessmentJourneyStepper(
          record: record,
          busy: _busy,
          onOpenStage: (stageKey) {
            if (_openStage != stageKey) _toggleStage(stageKey);
          },
        ),

        // Full-width selected property card, matching the mockup. The
        // disclosure, its toggle and the full detail panel are preserved.
        if (property != null)
          _collapsibleSelectedProperty(property, record)
        else
          const EmptyState(
            title: 'Listing no longer available',
            body:
                'This assessment is bound to a property id that is not in '
                'the catalogue any more. The stages and their recorded '
                'progress below are still accurate; the listing details '
                'cannot be shown.',
          ),

        // --- Stage 2 instrument ------------------------------------------
        // Context is secondary; the live persistence status is derived from
        // real in-memory state rather than a permanent "UI PREVIEW" label.
        if (stage2Open) ...[
          div(classes: 'asw-m2-heading', [
            div(classes: 'asw-m2-context', [
              span(classes: 'asw-m2-context__eyebrow', [
                Component.text('STAGE 2 · ENTREPRENEUR M2'),
              ]),
              span(classes: 'asw-m2-context__note', [
                Component.text('Business requirements · Stage 2 of '
                    '${record.totalStages}'),
              ]),
              p(classes: 'small asw-muted', [
                Component.text('The five-stage assessment journey and its '
                    'persisted progress are shown above. M2 confirmation requires '
                    'a verified source binding.'),
              ]),
            ]),
            const Pill('M2 binding required', tone: 'warning'),
          ]),
          _questionnairePanel(record),
        ],

        // Stage 3 hosts the BDJ / QJ / QG review portal; stage 4 hosts the
        // read-only customer questionnaire preview. Each links to the other
        // within the same assessment record.
        if (_openStage == 'location_evidence') _reviewPortal(record),

        if (_openStage == 'ai_explanation') _questionnairePreview(record),

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


  /// Collapsible view of the bound property, NOT the Stage 1 selection form.
  /// The underlying listing and assessment binding remain unchanged.
  Component _collapsibleSelectedProperty(
    CommercialProperty property,
    AssessmentRecord record,
  ) => section(classes: 'panel asw-property-disclosure', [
    div(classes: 'asw-property-disclosure__header', [
      // Only a real catalogue photograph is shown; the style guide forbids a
      // placeholder for listings that have none.
      if (property.imageUrl != null && property.imageUrl!.isNotEmpty)
        img(
          src: property.imageUrl!,
          attributes: {'alt': property.title, 'loading': 'lazy'},
          classes: 'asw-property-disclosure__thumb',
        ),
      div(classes: 'asw-property-disclosure__summary', [
        span(classes: 'eyebrow', [Component.text('Selected property')]),
        strong([Component.text(property.title)]),
        div(classes: 'asw-property-disclosure__facts', [
          span([
            Icon('location_on', size: 'sm'),
            Component.text('${property.address}, ${property.city}'),
          ]),
          span([
            Icon('storefront', size: 'sm'),
            Component.text(property.propertyType),
          ]),
          span([
            Icon('square_foot', size: 'sm'),
            Component.text('${property.sizeSqft.toStringAsFixed(0)} sq ft'),
          ]),
          span([
            Icon('payments', size: 'sm'),
            Component.text('${property.rentalDisplay} / month'),
          ]),
        ]),
        span(classes: 'small asw-muted', [
          Component.text('Property ${record.propertyId}'),
        ]),
      ]),
      button(
        classes: 'btn btn--secondary asw-property-disclosure__toggle',
        attributes: {
          'type': 'button',
          'aria-expanded': _selectedPropertyExpanded ? 'true' : 'false',
          'aria-controls': 'asw-selected-property-details',
          'aria-label': _selectedPropertyExpanded
              ? 'Hide selected property details'
              : 'Show selected property details',
        },
        events: events(onClick: () => setState(
          () => _selectedPropertyExpanded = !_selectedPropertyExpanded,
        )),
        [Component.text(_selectedPropertyExpanded
            ? 'Hide details ▲' : 'Show details ▼')],
      ),
    ]),
    div(
      classes: 'asw-property-disclosure__content',
      attributes: {
        'id': 'asw-selected-property-details',
        if (!_selectedPropertyExpanded) 'hidden': '',
      },
      [
        if (_selectedPropertyExpanded)
          _SelectedPropertyPanel(property: property, record: record),
      ],
    ),
  ]);

  Component _crumbs() => nav(classes: 'crumbs', [
    AppLink(
      to: '/entrepreneur',
      classes: 'crumbs__item crumbs__link',
      children: [Component.text('Home')],
    ),
    span(classes: 'crumbs__sep', [Component.text('›')]),
    AppLink(
      to: '/entrepreneur/assessments',
      classes: 'crumbs__item crumbs__link',
      children: [Component.text('Assessments')],
    ),
    span(classes: 'crumbs__sep', [Component.text('›')]),
    span(classes: 'crumbs__item crumbs__item--current', [
      Component.text('Assessment workspace'),
    ]),
  ]);

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

  // Research surfaces read the same authenticated availability contract.
  // Workspace UUIDs never stand in for an M2 assessment or campaign binding.
  Component _questionnairePanel(AssessmentRecord record) => Project1ReadPanel(
    key: ValueKey('m2-${record.assessmentId}'),
    assessmentId: record.assessmentId, section: 'review',
  );

  Component _reviewPortal(AssessmentRecord record) => div(classes: 'stack stack--md', [
    Project1ReadPanel(key: ValueKey('review-${record.assessmentId}'),
      assessmentId: record.assessmentId, section: 'review'),
    _evidencePanel(record),
  ]);

  Component _questionnairePreview(AssessmentRecord record) => Project1ReadPanel(
    key: ValueKey('questionnaire-${record.assessmentId}'),
    assessmentId: record.assessmentId, section: 'questionnaire',
  );

  Component _evidencePanel(AssessmentRecord record) =>
      section(classes: 'panel asw-inline', [
        div(classes: 'panel__head', [
          span(classes: 'panel__title', [Component.text('Location evidence')]),
          div(classes: 'row row--sm', [
            ActionButton(
              'Reload',
              variant: 'ghost',
              onClick: () => _retryEvidence(record.propertyId),
            ),
            ActionButton(
              'Close',
              variant: 'ghost',
              onClick: () => _toggleStage('location_evidence'),
            ),
          ]),
        ]),
        div(classes: 'panel__body', [_evidenceBody(record)]),
      ]);

  Component _evidenceBody(AssessmentRecord record) =>
      FutureBuilder<ApiResult<EvidencePayload>>(
        future: _evidence(record.propertyId),
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const div(classes: 'stack stack--md', [
              Skeleton(variant: 'row'),
              Skeleton(variant: 'row', count: 4),
            ]);
          }
          final result = snapshot.data;
          if (result == null || !result.ok) {
            // "Evidence failed to load" — distinct from "no evidence exists".
            return EmptyState(
              title: 'Evidence failed to load',
              body:
                  result?.failure?.message ??
                  'The evidence service did not respond.',
              action: ActionButton(
                'Try again',
                onClick: () => _retryEvidence(record.propertyId),
              ),
            );
          }
          return _EvidenceView(evidence: result.value!);
        },
      );
}

// =================================================================== load state

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

/// What the backend actually did for one selected property on Continue.
class _SelectionOutcome {
  const _SelectionOutcome({
    required this.ref,
    this.title,
    this.resumed = false,
    this.failure,
    this.nextStage,
  });

  /// The catalogue ref, preserved exactly as selected.
  final String ref;

  /// The listing title from the record the backend returned; null when the
  /// request failed before a record came back (the ref is shown instead).
  final String? title;

  /// True when an existing record was resumed rather than created.
  final bool resumed;

  /// The backend's refusal for THIS property. Other selections still proceed.
  final AssessmentFailure? failure;

  /// The in-page stage panel to expand when this assessment is opened. Null
  /// for a failed outcome, or when the current stage is one of the pages.
  final String? nextStage;

  bool get failed => failure != null;
}

/// The compact selected-properties summary for Stage 1.
///
/// Deliberately NOT the full listing preview: with up to three properties the
/// oversized images pushed the Continue action off-screen. Each row keeps a
/// small thumbnail, the title, the two figures that matter for a shortlist
/// (monthly rental, floor area) and an explicit remove action.
class _SelectedSummary extends StatelessComponent {
  final List<SelectableProperty> items;
  final int maxCount;
  final void Function(String propertyRef) onRemove;

  const _SelectedSummary({
    required this.items,
    required this.maxCount,
    required this.onRemove,
  });

  @override
  Component build(BuildContext context) => section(classes: 'panel asw-selected', [
    div(classes: 'panel__head', [
      span(classes: 'panel__title', [Component.text('Selected properties')]),
      span(classes: 'asw-select-count', [
        Component.text('${items.length} of $maxCount selected'),
      ]),
    ]),
    div(classes: 'panel__body stack stack--sm', [
      p(classes: 'small asw-muted', [
        Component.text(
          'Each property keeps its own independent assessment — separate '
          'questionnaire, evidence, prediction and report. The assessments '
          'are not combined into one comparison.',
        ),
      ]),
      for (final item in items) _row(item),
    ]),
  ]);

  Component _row(SelectableProperty item) {
    final property = item.property!;
    return div(classes: 'asw-selected__row', [
      if (property.imageUrl != null && property.imageUrl!.isNotEmpty)
        img(
          src: property.imageUrl!,
          attributes: {'alt': property.title, 'loading': 'lazy'},
          classes: 'asw-selected__thumb',
        )
      else
        // No placeholder photograph: the style guide forbids one, and a fake
        // image would misrepresent a listing that has none.
        div(classes: 'asw-selected__noimg', [
          Icon('image_not_supported', size: 'sm'),
        ]),
      div(classes: 'asw-selected__main', [
        span(classes: 'asw-selected__title', [
          Component.text(property.title),
        ]),
        span(classes: 'small', [
          Component.text(
            '${property.rentalDisplay} / month · '
            '${property.sizeSqft.toStringAsFixed(0)} sq ft',
          ),
        ]),
        span(classes: 'small asw-muted', [
          Component.text(
            [
              'Property ${item.propertyRef}',
              if (property.city.isNotEmpty) property.city,
            ].join(' · '),
          ),
        ]),
      ]),
      button(
        classes: 'asw-selected__remove',
        attributes: {
          'type': 'button',
          'aria-label': 'Remove ${property.title} from the selection',
        },
        events: events(onClick: () => onRemove(item.propertyRef)),
        [Component.text('Remove')],
      ),
    ]);
  }
}

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

/// Stage 3's evidence review, over the real analysis row.
///
/// Keeps the five states the spec requires visibly distinct: retrieved,
/// zero matching records, unavailable, incomplete and failed to load (the
/// last is handled by the caller, which owns the request).
class _EvidenceView extends StatelessComponent {
  final EvidencePayload evidence;
  const _EvidenceView({required this.evidence});

  @override
  Component build(BuildContext context) {
    if (!evidence.available) {
      return div(classes: 'stack stack--md', [
        EmptyState(
          title: 'Evidence unavailable',
          body:
              evidence.reason ??
              'The analysis pipeline has no evidence row for this property.',
        ),
        p(classes: 'disclaimer', [
          Component.text(
            'No competitor, accessibility or catchment figure is estimated to '
            'fill this section. The stage stays incomplete until a real '
            'analysis row exists.',
          ),
        ]),
      ]);
    }

    final measured = evidence.groups.fold<int>(
      0,
      (total, group) => total + group.availableCount,
    );
    final total = evidence.groups.fold<int>(
      0,
      (sum, group) => sum + group.metrics.length,
    );

    return div(classes: 'stack stack--md', [
      div(classes: 'asw-evidence__head', [
        div(classes: 'row row--sm', [
          Pill(
            evidence.hasAnyMetric
                ? 'Evidence retrieved'
                : 'No matching records',
            tone: evidence.hasAnyMetric ? 'success' : 'warning',
          ),
          if (measured < total)
            Pill('Incomplete: $measured of $total measured', tone: 'warning'),
        ]),
        dl(classes: 'kv', [
          _fact('Analysis status', evidence.analysisStatus),
          _fact('Reference coverage', evidence.referenceCoverage),
          _fact('Coordinate quality', evidence.coordinateQuality),
          _fact('Self-exclusion', evidence.selfExclusionStatus),
          _fact(
            'Data completeness',
            evidence.dataCompletenessPct == null
                ? null
                : '${evidence.dataCompletenessPct}%',
          ),
          _fact(
            'Feature snapshot',
            assessmentStampOrNull(evidence.featureSnapshotAt),
          ),
          _fact(
            'Inventory snapshot',
            assessmentStampOrNull(evidence.inventorySnapshotAt),
          ),
          _fact(
            'District',
            evidence.district == null
                ? null
                : [
                    evidence.district,
                    evidence.stateDosm,
                  ].where((part) => part != null && part.isNotEmpty).join(', '),
          ),
        ]),
      ]),
      if (!evidence.hasAnyMetric)
        div(classes: 'notice notice-warn', [
          Component.text(
            'The analysis row exists but every mapped field in it is NULL. '
            'That is "no matching records", not "measured zero" — the two mean '
            'different things and this page never collapses them.',
          ),
        ]),
      for (final group in evidence.groups) _group(group),
      _joins(evidence.joinStatus),
      p(classes: 'disclaimer', [
        Component.text(
          'Every figure above is read from the imported geospatial analysis '
          'row for this listing. Fields the pipeline did not measure are shown '
          'as "Not measured" and are excluded from any score rather than '
          'estimated.',
        ),
      ]),
    ]);
  }

  Component _group(EvidenceGroup group) => div(classes: 'asw-evidence__group', [
    div(classes: 'row row--sm', [
      span(classes: 'asw-evidence__label', [Component.text(group.label)]),
      span(classes: 'small asw-muted', [
        Component.text(
          '${group.availableCount} of ${group.metrics.length} measured',
        ),
      ]),
    ]),
    if (group.metrics.isEmpty)
      p(classes: 'small asw-muted', [
        Component.text('No mapped fields in this group.'),
      ])
    else
      table(classes: 'asw-evidence__table', [
        tbody([
          for (final metric in group.metrics)
            tr(classes: metric.isAvailable ? '' : 'is-missing', [
              td([
                Component.text(metric.label),
                if (metric.note != null)
                  span(classes: 'asw-evidence__note', [
                    Component.text(metric.note!),
                  ]),
              ]),
              td([
                Component.text(
                  metric.isAvailable
                      ? _formatValue(metric.value!, metric.unit)
                      : 'Not measured',
                ),
              ]),
            ]),
        ]),
      ]),
  ]);

  Component _joins(Map<String, String?> joinStatus) {
    if (joinStatus.isEmpty) return const span([]);
    const labels = {
      'property': 'Property join',
      'demand': 'Demand join',
      'accessibility': 'Accessibility join',
      'district_income': 'District income join',
    };
    return div(classes: 'asw-evidence__group', [
      span(classes: 'asw-evidence__label', [Component.text('Source joins')]),
      p(classes: 'asw-note', [
        Component.text(
          'Whether each reference source matched this listing. An unmatched '
          'join is why the related figures read "Not measured".',
        ),
      ]),
      div(classes: 'chips', [
        for (final entry in joinStatus.entries)
          Pill(
            '${labels[entry.key] ?? entry.key}: ${entry.value ?? 'unknown'}',
            tone: entry.value == 'MATCHED' ? 'success' : 'warning',
          ),
      ]),
    ]);
  }

  static Component _fact(String label, String? value) => div([
    dt([Component.text(label)]),
    dd([Component.text(value ?? 'Not recorded')]),
  ]);
}

// ==================================================================== helpers

/// Formats a measured value with its unit. Whole counts stay whole; ratios and
/// distances keep two decimals.
String _formatValue(num value, String unit) {
  final whole = value == value.roundToDouble();
  final text = whole
      ? value.toInt().toString()
      : value.toStringAsFixed(2).replaceFirst(RegExp(r'\.?0+$'), '');
  if (unit.isEmpty) return text;
  // Currency reads as a prefix; every other unit reads as a suffix.
  return unit == 'RM' || unit == 'MYR' ? 'RM $text' : '$text $unit';
}
