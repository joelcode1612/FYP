import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/ui.dart';
import '../../data/app_locator.dart';
import '../../data/assessment_api.dart';
import '../../data/assessment_format.dart';
import '../../layouts/app_layout.dart';

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

  const AssessmentWorkspacePage({
    super.key,
    required this.propertyId,
    this.stage = '',
  });

  @override
  State<AssessmentWorkspacePage> createState() => _AssessmentWorkspaceState();
}

class _AssessmentWorkspaceState extends State<AssessmentWorkspacePage> {
  static const _api = AssessmentApi();

  /// The two stages whose body lives inside the workspace. The other three
  /// hand over to pages that already exist.
  static const _inlineStages = {'business_requirements', 'location_evidence'};

  late Future<_Load> _future = _open(component.propertyId);

  /// Which in-page stage panel is expanded. Seeded from `?stage=` in
  /// [initState] so a shared link lands on the panel it names.
  String? _openStage;

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

  @override
  void initState() {
    super.initState();
    if (_inlineStages.contains(component.stage)) _openStage = component.stage;
    if (_openStage == 'location_evidence' && component.propertyId.isNotEmpty) {
      _evidenceFuture = _api.evidence(component.propertyId);
    }
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
  /// arrives before a round trip), then PATCHes. On failure the typed values
  /// are kept exactly as entered.
  ///
  /// [completeStage] records stage 2 in the same request; the server applies
  /// the requirements first, so the stage is completed only against values it
  /// has just validated.
  Future<void> _saveRequirements(
    AssessmentRecord record, {
    bool completeStage = false,
  }) async {
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
    final result = completeStage
        ? await _api.saveRequirementsAndComplete(
            record.assessmentId,
            draft.toPayload(),
            'business_requirements',
          )
        : await _api.saveRequirements(record.assessmentId, draft.toPayload());
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
      _notice = completeStage
          ? 'Business requirements saved and stage 2 recorded as complete. '
                '${updated.completedStages} of ${updated.totalStages} '
                'stages done.'
          : 'Business requirements saved to this assessment and applied to '
                'your ranking preferences.';
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
      _evidenceFuture ??= _api.evidence(component.propertyId);
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
    _draft = _RequirementsDraft(
      businessType: prefs.businessType,
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

  // ------------------------------------------------------------------ render

  @override
  Component build(BuildContext context) {
    if (component.propertyId.isEmpty) {
      return _shell(
        title: 'Location Assessment Workspace',
        subtitle:
            'A five-stage assessment of one commercial property, saved to your '
            'account as you go.',
        child: const EmptyState(
          title: 'No property selected',
          body:
              'The workspace assesses one listing at a time, so it needs a '
              'property to work on. Choose a listing from Explore, from your '
              'recommendations or from your saved properties, then open its '
              'assessment.',
          action: ActionLink(
            'Browse commercial properties',
            href: '/entrepreneur/explore',
            variant: 'primary',
          ),
        ),
      );
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
    currentRoute: '/entrepreneur/assessment',
    title: title,
    eyebrow: 'Location assessment',
    subtitle: subtitle,
    actions: actions,
    child: child,
  );

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
    // Cached for the requirements form's seed. Assigning during build is safe:
    // it is a plain field write and never schedules a rebuild.
    _record = record;
    final property = record.property;
    return _shell(
      title: 'Location Assessment Workspace',
      subtitle: property == null
          ? 'Property ${record.propertyId}'
          : '${property.title} · ${property.address}, ${property.city}',
      actions: [
        ActionLink(
          'Property detail',
          href: '/entrepreneur/property-detail?id=${record.propertyId}',
          variant: 'secondary',
        ),
      ],
      child: div(classes: 'stack stack--sections', [
        _crumbs(),
        if (_notice != null) _successNotice(_notice!),
        if (_writeError != null) _errorNotice(_writeError!),
        _ProgressPanel(record: record),
        div(classes: 'asw-grid', [
          div(classes: 'stack stack--md', [
            for (final stage in record.stages) ...[
              _StageCard(
                stage: stage,
                propertyId: record.propertyId,
                open: _openStage == stage.key,
                busy: _busy,
                onToggle: _inlineStages.contains(stage.key)
                    ? () => _toggleStage(stage.key)
                    : null,
                onComplete: !stage.isComplete && !stage.isUnavailable
                    ? () => _completeStage(record, stage.key)
                    : null,
              ),
              if (_openStage == stage.key &&
                  stage.key == 'business_requirements')
                _requirementsPanel(record),
              if (_openStage == stage.key && stage.key == 'location_evidence')
                _evidencePanel(record),
            ],
          ]),
          div(classes: 'stack stack--md', [
            if (property != null)
              _SelectedPropertyPanel(property: property, record: record)
            else
              const EmptyState(
                title: 'Listing no longer available',
                body:
                    'This assessment is bound to a property id that is not in '
                    'the catalogue any more. The stages and their recorded '
                    'progress below are still accurate; the listing details '
                    'cannot be shown.',
              ),
            _NextActionPanel(
              record: record,
              busy: _busy,
              onOpenStage: _toggleStage,
            ),
            _CapabilityPanel(capabilities: record.capabilities),
          ]),
        ]),
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

  Component _crumbs() => nav(classes: 'crumbs', [
    AppLink(
      to: '/entrepreneur',
      classes: 'crumbs__item crumbs__link',
      children: [Component.text('Home')],
    ),
    span(classes: 'crumbs__sep', [Component.text('›')]),
    AppLink(
      to: '/entrepreneur/explore',
      classes: 'crumbs__item crumbs__link',
      children: [Component.text('Explore')],
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

  // ------------------------------------------------------------- stage 2 body

  Component _requirementsPanel(AssessmentRecord record) {
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
            onClick: _busy
                ? null
                : () => _saveRequirements(record, completeStage: true),
          ),
          ActionButton(
            'Save requirements only',
            variant: 'secondary',
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
                attributes: {
                  'type': 'radio',
                  'name': 'aswPropertyType',
                  if (option == draft.propertyType) 'checked': '',
                },
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

  // ------------------------------------------------------------- stage 3 body

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

/// One stage card: number, title, description, status, action.
class _StageCard extends StatelessComponent {
  final AssessmentStage stage;
  final String propertyId;
  final bool open;
  final bool busy;

  /// Non-null only for the two stages whose body is inside the workspace.
  final void Function()? onToggle;

  /// Non-null only while the stage can still be completed.
  final void Function()? onComplete;

  const _StageCard({
    required this.stage,
    required this.propertyId,
    required this.open,
    required this.busy,
    this.onToggle,
    this.onComplete,
  });

  @override
  Component build(BuildContext context) {
    final description = _stageDescriptions[stage.key]?.$2 ?? '';
    return section(classes: 'panel asw-stage asw-stage--${stage.status}', [
      div(classes: 'asw-stage__head', [
        span(classes: 'asw-stage__no', [Component.text('${stage.number}')]),
        div(classes: 'grow stack stack--xs', [
          div(classes: 'row row--sm', [
            span(classes: 'asw-stage__title', [Component.text(stage.title)]),
            _StatusPill(stage: stage),
          ]),
          p(classes: 'small', [Component.text(description)]),
          if (stage.completedAt != null)
            span(classes: 'small asw-muted', [
              Component.text(
                'Completed ${assessmentStamp(stage.completedAt!)}',
              ),
            ]),
          if (stage.isUnavailable && stage.unavailableReason != null)
            span(classes: 'small asw-stage__reason', [
              Component.text(stage.unavailableReason!),
            ]),
        ]),
      ]),
      div(classes: 'asw-stage__actions', [_action()]),
    ]);
  }

  Component _action() {
    final actions = <Component>[];

    switch (stage.key) {
      case 'select_property':
        actions.add(
          ActionLink(
            'Open property detail',
            href: '/entrepreneur/property-detail?id=$propertyId',
            variant: 'secondary',
          ),
        );
      case 'business_requirements':
        if (onToggle != null) {
          actions.add(
            ActionButton(
              open ? 'Close requirements' : 'Open requirements',
              variant: stage.isComplete ? 'secondary' : 'primary',
              onClick: busy ? null : onToggle,
            ),
          );
        }
      case 'location_evidence':
        if (onToggle != null) {
          actions.add(
            ActionButton(
              open ? 'Close evidence' : 'Review evidence',
              variant: stage.isComplete ? 'secondary' : 'primary',
              onClick: busy ? null : onToggle,
            ),
          );
        }
      case 'ai_explanation':
        actions.add(
          ActionLink(
            'Open explanation',
            href: '/entrepreneur/explanation?property=$propertyId',
            variant: stage.isUnavailable ? 'ghost' : 'secondary',
          ),
        );
      case 'assessment_report':
        actions.add(
          ActionLink(
            'Open report',
            href: '/entrepreneur/report?id=$propertyId',
            variant: stage.isUnavailable ? 'ghost' : 'secondary',
          ),
        );
    }

    if (onComplete != null) {
      actions.add(
        ActionButton(
          busy ? 'Saving…' : 'Mark stage complete',
          variant: 'secondary',
          onClick: busy ? null : onComplete,
        ),
      );
    }

    if (actions.isEmpty) {
      return span(classes: 'small asw-muted', [
        Component.text('Nothing to do here.'),
      ]);
    }
    return div(classes: 'actions-row', actions);
  }
}

class _StatusPill extends StatelessComponent {
  final AssessmentStage stage;
  const _StatusPill({required this.stage});

  @override
  Component build(BuildContext context) {
    final (label, tone) = switch (stage.status) {
      'complete' => ('Complete', 'success'),
      'current' => ('Current stage', 'action'),
      'unavailable' => ('Unavailable', 'warning'),
      _ => ('Not started', 'neutral'),
    };
    return Pill(label, tone: tone);
  }
}

/// Overall progress, computed from the persisted counts — never a constant.
class _ProgressPanel extends StatelessComponent {
  final AssessmentRecord record;
  const _ProgressPanel({required this.record});

  @override
  Component build(BuildContext context) {
    final current = record.stages.where((stage) => stage.isCurrent).firstOrNull;
    final incomplete = record.stages
        .where((stage) => !stage.isComplete)
        .toList();
    // The bar width comes from a 5%-bucketed utility class, and progress is
    // always a multiple of 20 here, so the bucket is exact.
    final bucket = (record.progressPercent / 5).round() * 5;

    return section(classes: 'panel asw-progress', [
      div(classes: 'asw-progress__head', [
        div(classes: 'stack stack--xs', [
          span(classes: 'eyebrow', [Component.text('Assessment progress')]),
          span(classes: 'asw-progress__count', [
            Component.text(
              '${record.completedStages} of ${record.totalStages} stages '
              'completed',
            ),
          ]),
        ]),
        div(classes: 'stack stack--xs asw-progress__meta', [
          StatusBadge(
            record.isCompleted ? 'Completed' : 'In progress',
            tone: record.isCompleted ? 'success' : 'action',
          ),
          span(classes: 'small asw-muted', [
            Component.text('${record.progressPercent}%'),
          ]),
        ]),
      ]),
      div(classes: 'progress-track', [i(classes: 'w-$bucket', [])]),
      div(classes: 'asw-progress__foot', [
        span(classes: 'small', [
          Component.text(
            current == null
                ? 'Every stage is recorded.'
                : 'Current stage: ${current.number} — ${current.title}',
          ),
        ]),
        if (incomplete.isNotEmpty)
          span(classes: 'small asw-muted', [
            Component.text(
              'Remaining: ${incomplete.map((stage) => stage.title).join(' · ')}',
            ),
          ]),
      ]),
      if (record.updatedAt != null)
        span(classes: 'small asw-muted', [
          Component.text('Last updated ${assessmentStamp(record.updatedAt!)}'),
        ]),
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
          href: '/entrepreneur/map?id=${property.id}',
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

/// What to do next, taken from the backend's derived verdict.
class _NextActionPanel extends StatelessComponent {
  final AssessmentRecord record;
  final bool busy;
  final void Function(String) onOpenStage;

  const _NextActionPanel({
    required this.record,
    required this.busy,
    required this.onOpenStage,
  });

  @override
  Component build(BuildContext context) {
    final action = record.nextAction;
    final explanation = switch (action.kind) {
      'view_report' =>
        'Every stage is recorded. The report summarises the assessment data '
            'that now exists.',
      'blocked' =>
        'The next stage cannot be completed yet: ${action.reason ?? 'the '
                'backend did not say why'}. Nothing is estimated to fill the gap.',
      _ =>
        'Stage ${record.currentStage} is next. Completing it writes a '
            'timestamp to your assessment record.',
    };

    return section(classes: 'panel asw-next', [
      div(classes: 'panel__head', [
        span(classes: 'panel__title', [Component.text('Next action')]),
      ]),
      div(classes: 'panel__body stack stack--md', [
        p(classes: 'body', [Component.text(explanation)]),
        div(classes: 'actions-row', [_primary(action)]),
        // The secondary action always returns to the property, as specified.
        ActionLink(
          'Back to the property',
          href: '/entrepreneur/property-detail?id=${record.propertyId}',
          variant: 'ghost',
        ),
      ]),
    ]);
  }

  Component _primary(AssessmentNextAction action) {
    if (action.isReport) {
      return ActionLink(
        'Open assessment report',
        href: '/entrepreneur/report?id=${record.propertyId}',
        variant: 'primary',
      );
    }
    if (action.isBlocked) {
      return ActionButton(
        'Blocked: ${action.label}',
        variant: 'secondary',
        onClick: null,
      );
    }
    final stage = record.stageByKey(action.stageKey);
    if (stage?.isComplete ?? true) {
      return ActionButton(action.label, variant: 'primary', onClick: null);
    }
    // Stages 2 and 3 open inside the workspace; the other three are pages.
    return switch (action.stageKey) {
      'business_requirements' || 'location_evidence' => ActionButton(
        action.label.isEmpty ? 'Continue' : 'Continue: ${action.label}',
        variant: 'primary',
        onClick: busy ? null : () => onOpenStage(action.stageKey),
      ),
      'select_property' => ActionLink(
        'Open property detail',
        href: '/entrepreneur/property-detail?id=${record.propertyId}',
        variant: 'primary',
      ),
      'ai_explanation' => ActionLink(
        'Open explanation',
        href: '/entrepreneur/explanation?property=${record.propertyId}',
        variant: 'primary',
      ),
      _ => ActionLink(
        'Open report',
        href: '/entrepreneur/report?id=${record.propertyId}',
        variant: 'primary',
      ),
    };
  }
}

/// The runtime capability verdicts. These explain why stages 4 and 5 are
/// unavailable, using the server's own probe rather than a hardcoded flag.
class _CapabilityPanel extends StatelessComponent {
  final AssessmentCapabilities capabilities;
  const _CapabilityPanel({required this.capabilities});

  @override
  Component build(BuildContext context) => section(classes: 'panel', [
    div(classes: 'panel__head', [
      span(classes: 'panel__title', [
        Component.text('Decision-support capabilities'),
      ]),
    ]),
    div(classes: 'panel__body stack stack--sm', [
      p(classes: 'asw-note', [
        Component.text(
          'Probed on the server for this request. A capability that is off '
          'blocks its stage rather than being replaced with an estimate.',
        ),
      ]),
      _row('Trained suitability model', capabilities.model),
      _row('Explanation (model + SHAP)', capabilities.explanation),
      _row('Report generator', capabilities.report),
    ]),
  ]);

  static Component _row(String label, AssessmentCapability capability) =>
      div(classes: 'asw-cap', [
        div(classes: 'row row--sm', [
          span(classes: 'small grow', [Component.text(label)]),
          Pill(
            capability.available ? 'Available' : 'Unavailable',
            tone: capability.available ? 'success' : 'warning',
          ),
        ]),
        if (!capability.available && capability.reason != null)
          p(classes: 'small asw-muted', [Component.text(capability.reason!)]),
        if (capability.available && capability.modelVersion != null)
          p(classes: 'small asw-muted', [
            Component.text('Version ${capability.modelVersion}'),
          ]),
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
