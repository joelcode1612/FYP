import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import '../../components/ui.dart' show Icon;
import '../../components/saved_assessment_dropdown.dart'
    show SavedAssessmentChoice;

/// Immutable read-only event projection returned by the existing audit API.
/// Normalize timestamps to UTC ISO 8601 before rendering/sorting.
class AssessmentActivity {
  final String eventId;
  final String occurredAtIso;
  final String engine;
  final String activityType;
  final String status;
  final String title;
  final String summary;
  final String actor;

  /// The assessment revision the event was recorded against. Kept separate
  /// from [version]: a revision is not an engine version, and labelling one
  /// as the other is how "Version 13" used to appear for a ruleset evaluation.
  final int revision;

  /// Engine/ruleset/builder version, when the record actually carries one.
  /// Null means the source does not store a version — never a substituted
  /// revision number.
  final String? version;
  final List<String> inputReferences;
  final List<String> outputReferences;
  final String? reason;
  final bool? sourceIsCurrent;

  const AssessmentActivity({
    required this.eventId,
    required this.occurredAtIso,
    required this.engine,
    required this.activityType,
    required this.status,
    required this.title,
    required this.summary,
    required this.actor,
    required this.revision,
    this.version,
    this.inputReferences = const [],
    this.outputReferences = const [],
    this.reason,
    this.sourceIsCurrent,
  });
}

/// Not `@client`: it is mounted inside the `@client` route shell, and the
/// `@client` codegen rejects custom model parameters. Its interactive state
/// (filters, selection, pagination) is hydrated because the parent
/// `M2ActivityPanel` is the client anchor.
///
/// Layout follows the approved reference
/// (SiteWise_Activity_History_With_Assessment_Selector.html): page heading
/// with back action, assessment picker, identity + context-stats card,
/// filters, workflow coverage, timeline + detail grid, footnote. Rendered
/// inside the existing AppLayout — no sidebar of its own.
///
/// Governance contract unchanged: every event, count and coverage line comes
/// from the panel's authenticated M2 source; nothing is invented, and an
/// unavailable source renders its honest message instead of substitute rows.
class ActivityHistoryPage extends StatefulComponent {
  final String businessName;
  final String assessmentId;
  final List<AssessmentActivity> activities;
  final bool activitiesAvailable;
  final String? availabilityMessage;
  final void Function(String eventId)? onViewFullLog;

  /// Saved assessments come only from the panel's authenticated M2 list. The
  /// dropdown renders those choices as a native <select>; only an id supplied
  /// by the parent may be selected, and the parent owns the subsequent load.
  final List<SavedAssessmentChoice> savedAssessments;
  final String? selectedAssessmentId;
  final void Function(String assessmentId)? onSelectAssessment;
  final bool savedAssessmentsLoading;

  final bool workflowHistory;
  final List<String> sourceCoverage;
  final List<String> currentSnapshots;

  const ActivityHistoryPage({
    required this.businessName,
    required this.assessmentId,
    required this.activities,
    this.activitiesAvailable = true,
    this.availabilityMessage,
    this.onViewFullLog,
    this.savedAssessments = const [],
    this.selectedAssessmentId,
    this.onSelectAssessment,
    this.savedAssessmentsLoading = false,
    this.workflowHistory = false,
    this.sourceCoverage = const [],
    this.currentSnapshots = const [],
    super.key,
  });

  @override
  State<ActivityHistoryPage> createState() => _ActivityHistoryPageState();
}

class _ActivityHistoryPageState extends State<ActivityHistoryPage> {
  String _engine = '';
  String _activityType = '';
  String _status = '';
  String _startDate = '';
  String _endDate = '';
  String? _selectedEventId;
  int _page = 0;
  static const int pageSize = 6;

  @override
  void didUpdateComponent(covariant ActivityHistoryPage oldComponent) {
    super.didUpdateComponent(oldComponent);
    if (oldComponent.assessmentId != component.assessmentId) {
      _engine = _activityType = _status = _startDate = _endDate = '';
      _resetSelection();
    }
  }

  List<AssessmentActivity> get _source => component.activitiesAvailable
      ? component.activities
      : const <AssessmentActivity>[];

  List<AssessmentActivity> get _filtered {
    final items = _source.where((event) {
      final utc = DateTime.tryParse(
        event.occurredAtIso,
      )?.toUtc().toIso8601String();
      final date = utc?.substring(0, 10) ?? '';
      if (_engine.isNotEmpty && event.engine != _engine) return false;
      if (_activityType.isNotEmpty && event.activityType != _activityType) {
        return false;
      }
      if (_status.isNotEmpty && event.status != _status) return false;
      if (_startDate.isNotEmpty && date.compareTo(_startDate) < 0) {
        return false;
      }
      if (_endDate.isNotEmpty && date.compareTo(_endDate) > 0) {
        return false;
      }
      return true;
    }).toList();
    final unique = <String, AssessmentActivity>{};
    for (final item in items) {
      unique.putIfAbsent(
        '${item.engine}:${item.activityType}:${item.eventId}',
        () => item,
      );
    }
    final ordered = unique.values.toList();
    ordered.sort((left, right) {
      final at = DateTime.tryParse(left.occurredAtIso);
      final bt = DateTime.tryParse(right.occurredAtIso);
      final date = at != null && bt != null
          ? bt.compareTo(at)
          : right.occurredAtIso.compareTo(left.occurredAtIso);
      return date != 0 ? date : right.eventId.compareTo(left.eventId);
    });
    return ordered;
  }

  void _resetSelection() {
    _page = 0;
    _selectedEventId = null;
  }

  /// Human-readable timestamp; the stored ISO value stays untouched.
  String _fmt(String iso) {
    final parsed = DateTime.tryParse(iso);
    if (parsed == null) return iso;
    const months = [
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
    final local = parsed.toLocal();
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    return '${local.day} ${months[local.month - 1]} ${local.year}, '
        '$hour:$minute';
  }

  /// Status → badge tone. Unrecognised statuses stay neutral: a status the
  /// backend sends that this build does not classify must not read as success.
  String _tone(String status) {
    final text = status.toLowerCase();
    if (text.contains('completed') || text.contains('persisted')) {
      return 'success';
    }
    if (text.contains('review') || text.contains('pending')) {
      return 'warning';
    }
    if (text.contains('fail')) {
      return 'danger';
    }
    return 'neutral';
  }

  Component _statusBadge(String status) => span(
    [Component.text(status)],
    classes: 'sr-status sr-status--${_tone(status)}',
  );

  Component _icon(String name) => span(
    classes: 'sr-icon',
    attributes: {'aria-hidden': 'true'},
    [Icon(name)],
  );

  Component _button(
    String label,
    VoidCallback? handler, {
    bool primary = false,
    String? icon,
  }) => button(
    classes: 'sr-button${primary ? ' sr-button--primary' : ''}',
    attributes: {'type': 'button', if (handler == null) 'disabled': ''},
    events: events(
      onClick: () {
        if (handler != null) handler();
      },
    ),
    [
      if (icon != null) _icon(icon),
      Component.text(label),
    ],
  );

  Component _selectFilter(
    String label,
    String current,
    List<String> options,
    void Function(String) setCurrent, {
    String? allLabel,
  }) => div(classes: 'sr-filter-field', [
    span(classes: 'sr-label', [Component.text(label)]),
    select(
      classes: 'sr-select',
      disabled: !component.activitiesAvailable,
      onChange: (values) => setState(() {
        setCurrent(values.isEmpty ? '' : values.first);
        _resetSelection();
      }),
      [
        option(value: '', selected: current.isEmpty, [
          Component.text(allLabel ?? 'All $label'),
        ]),
        for (final value in options)
          option(value: value, selected: current == value, [
            Component.text(value),
          ]),
      ],
    ),
  ]);

  Component _dateFilter(
    String label,
    String current,
    void Function(String) onValue,
  ) => div(classes: 'sr-filter-field', [
    span(classes: 'sr-label', [Component.text(label)]),
    input<String>(
      type: InputType.date,
      classes: 'sr-date',
      disabled: !component.activitiesAvailable,
      value: current,
      onChange: (value) => setState(() {
        onValue(value);
        _resetSelection();
      }),
    ),
  ]);

  Component _referenceList(String title, String icon, List<String> refs) =>
      section(classes: 'sr-reference-panel', [
        h4([_icon(icon), Component.text(title)]),
        if (refs.isEmpty)
          p([Component.text('No references supplied.')], classes: 'sr-empty-copy')
        else
          ul(classes: 'sr-reference-list', [
            for (final ref in refs) li([Component.text(ref)]),
          ]),
      ]);

  Component _details(AssessmentActivity? item) {
    final head = section(classes: 'sr-card-head sr-card-head--detail', [
      h2([_icon('description'), Component.text('Activity details')]),
      span(
        classes: 'sr-event-id',
        [Component.text(item == null ? 'Select an event' : 'Event ${item.eventId}')],
      ),
    ]);
    if (item == null) {
      return section(classes: 'sr-card sr-detail', [
        head,
        div(classes: 'sr-detail-placeholder', [
          span(classes: 'sr-icon', attributes: {'aria-hidden': 'true'}, [
            Icon(component.activitiesAvailable ? 'description' : 'report_problem'),
          ]),
          h3([
            Component.text(
              component.activitiesAvailable
                  ? 'No activity selected'
                  : 'Activity unavailable',
            ),
          ]),
          p([
            Component.text(
              component.activitiesAvailable
                  ? 'Select an event in the timeline to see its audit details.'
                  : component.availabilityMessage ??
                        'Activity records are unavailable.',
            ),
          ]),
        ]),
      ]);
    }
    return section(classes: 'sr-card sr-detail', [
      head,
      div(classes: 'sr-detail-content', [
        div(classes: 'sr-detail-title-row', [
          div(classes: 'sr-detail-title-wrap', [
            h3([Component.text(item.title)]),
            p(classes: 'sr-detail-subline', [
              Component.text('${item.engine} · ${_fmt(item.occurredAtIso)}'),
            ]),
          ]),
          _statusBadge(item.status),
        ]),
        section(classes: 'sr-summary-block', [
          h4([_icon('info'), Component.text('What happened')]),
          p([Component.text(item.summary)]),
          if (item.reason != null)
            p([
              Component.text('Recorded reason: ${item.reason}'),
            ], classes: 'sr-reference-list'),
          if (item.sourceIsCurrent != null)
            p([
              Component.text(
                item.sourceIsCurrent!
                    ? 'Source revision matches the current saved revision.'
                    : 'Historical source revision — original outcome retained; not a current handoff.',
              ),
            ]),
        ]),
        div(classes: 'sr-reference-grid', [
          _referenceList('Inputs', 'input', item.inputReferences),
          _referenceList('Outputs', 'output', item.outputReferences),
        ]),
        section(classes: 'sr-info-block', [
          h4([_icon('settings'), Component.text('Processing details')]),
          dl(classes: 'sr-data-list', [
            div([
              dt([Component.text('Engine / module')]),
              dd([Component.text(item.engine)]),
            ]),
            div([
              dt([Component.text('Activity type')]),
              dd([Component.text(item.activityType)]),
            ]),
            div([
              dt([Component.text('Assessment revision')]),
              dd([Component.text('${item.revision}')]),
            ]),
            div([
              dt([Component.text('Engine version')]),
              dd([
                Component.text(
                  item.version ?? 'Not recorded on this event',
                ),
              ]),
            ]),
            div([
              dt([Component.text('Event ID')]),
              dd([Component.text(item.eventId)]),
            ]),
          ]),
        ]),
        section(classes: 'sr-info-block', [
          h4([_icon('schedule'), Component.text('Audit information')]),
          dl(classes: 'sr-data-list', [
            div([
              dt([Component.text('Recorded by')]),
              dd([Component.text(item.actor)]),
            ]),
            div([
              dt([Component.text('Recorded at')]),
              dd([Component.text(_fmt(item.occurredAtIso))]),
            ]),
          ]),
          p([
            Component.text(
              'This projection is read-only. Audit corrections require a new authorized backend event.',
            ),
          ], classes: 'sr-audit-note'),
        ]),
        div(classes: 'sr-detail-actions', [
          _button(
            'View full log (JSON)',
            component.onViewFullLog == null
                ? null
                : () => component.onViewFullLog!(item.eventId),
            primary: true,
            icon: 'code',
          ),
        ]),
      ]),
    ]);
  }

  @override
  Component build(BuildContext context) {
    final engines = <String>{
      if (component.workflowHistory) ...[
        'M2',
        'BDJ',
        'Business Understanding',
        'BCB',
        'QJ',
        'Question Bank / QG',
        'Scientific / Owner / Fielding',
        'Customer Questionnaire',
      ] else ...[
        'BDJ',
        'BCB',
        'QJ',
        'QG',
        'EE-01',
        'Explanation',
        'A10',
      ],
      ...component.activities.map((e) => e.engine),
    }.toList()..sort();
    final types =
        component.activities.map((e) => e.activityType).toSet().toList()
          ..sort();
    final statuses = component.activities.map((e) => e.status).toSet().toList()
      ..sort();
    final all = _filtered;
    final pages = all.isEmpty ? 1 : (all.length + pageSize - 1) ~/ pageSize;
    final page = _page >= pages ? pages - 1 : _page;
    final visible = all.skip(page * pageSize).take(pageSize).toList();
    AssessmentActivity? selected;
    for (final activity in all) {
      if (activity.eventId == _selectedEventId) {
        selected = activity;
        break;
      }
    }
    if (selected == null && visible.isNotEmpty) selected = visible.first;
    final latest = all.isEmpty ? null : all.first;

    return main_(classes: 'sr-workspace', [
      div(classes: 'sr-page-heading', [
        div(classes: 'sr-page-heading__copy', [
          p(classes: 'sr-breadcrumb', [
            Component.text('Assessments › Review portal › Activity history'),
          ]),
          h1([_icon('history'), Component.text('Activity history')]),
          p(classes: 'sr-subtitle', [
            Component.text(
              'See what has happened during this assessment, including '
              'processing steps, decisions and updates. Saved workflow '
              'metadata only — private answers, business text and model '
              'payloads are not shown.',
            ),
          ]),
        ]),
      ]),
      // Native dropdown picker. Unlike the custom button+menu, this stays
      // readable in every state: loading, error, empty, and with real choices.
      section(classes: 'sr-card sr-assessment-picker', [
        div(classes: 'sr-picker-label', [
          span(classes: 'sr-picker-icon', attributes: {'aria-hidden': 'true'}, [
            Icon('folder_open'),
          ]),
          Component.text('Selected assessment'),
        ]),
        div(classes: 'sr-picker-field', [
          select(
            classes: 'sr-select',
            disabled: component.savedAssessmentsLoading ||
                component.onSelectAssessment == null ||
                component.savedAssessments.isEmpty,
            attributes: {
              'aria-label': 'Choose a saved assessment',
              'data-testid': 'saved-assessment-select',
            },
            onChange: (values) {
              final id = values.isEmpty ? '' : values.first;
              if (id.isNotEmpty) component.onSelectAssessment!(id);
            },
            [
              option(
                value: '',
                selected: component.selectedAssessmentId == null,
                [
                  Component.text(
                    component.savedAssessmentsLoading
                        ? 'Loading saved assessments…'
                        : component.savedAssessments.isEmpty
                        ? 'No saved assessments'
                        : 'Select a saved assessment',
                  ),
                ],
              ),
              for (final choice in component.savedAssessments)
                option(
                  value: choice.assessmentId,
                  selected: choice.assessmentId == component.selectedAssessmentId,
                  [Component.text(choice.displayLabel)],
                ),
            ],
          ),
        ]),
      ]),
      section(classes: 'sr-card sr-history-header', [
        div(classes: 'sr-assessment-identity', [
          div(classes: 'sr-assessment-icon', attributes: {'aria-hidden': 'true'}, [
            Icon('insights'),
          ]),
          div(classes: 'sr-assessment-copy', [
            span(classes: 'sr-overline', [Component.text('CURRENT ASSESSMENT')]),
            h2([Component.text(component.businessName)]),
            p([
              Component.text(
                component.assessmentId.isEmpty
                    ? 'No assessment selected · Activity and engine logs'
                    : 'Assessment ${component.assessmentId}',
              ),
            ]),
          ]),
        ]),
        div(classes: 'sr-context-stats', [
          div(classes: 'sr-context-stat', [
            span(classes: 'sr-context-stat__label', [
              Component.text('Recorded activities'),
            ]),
            strong([Component.text('${component.activities.length}')]),
          ]),
          div(classes: 'sr-context-stat', [
            span(classes: 'sr-context-stat__label', [
              Component.text('Modules in current view'),
            ]),
            strong([
              Component.text('${all.map((e) => e.engine).toSet().length}'),
            ]),
          ]),
          div(classes: 'sr-context-stat', [
            span(classes: 'sr-context-stat__label', [
              Component.text('Latest matching activity'),
            ]),
            strong([
              Component.text(
                latest == null ? 'No matching activity' : _fmt(latest.occurredAtIso),
              ),
            ]),
          ]),
        ]),
      ]),
      section(classes: 'sr-card sr-filters', [
        div(classes: 'sr-section-heading', [
          div([
            h2([_icon('filter_list'), Component.text('Filter activities')]),
            p([
              Component.text(
                'Narrow the history by module, action, status, or date.',
              ),
            ]),
          ]),
          _button(
            'Reset filters',
            !component.activitiesAvailable
                ? null
                : () => setState(() {
                    _engine = '';
                    _activityType = '';
                    _status = '';
                    _startDate = '';
                    _endDate = '';
                    _resetSelection();
                  }),
            icon: 'restart_alt',
          ),
        ]),
        div(classes: 'sr-filter-grid', [
          _selectFilter(
            'Engine / module',
            _engine,
            engines,
            (v) => _engine = v,
            allLabel: 'All engines',
          ),
          _selectFilter(
            'Activity type',
            _activityType,
            types,
            (v) => _activityType = v,
            allLabel: 'All activities',
          ),
          _selectFilter(
            'Status',
            _status,
            statuses,
            (v) => _status = v,
            allLabel: 'All statuses',
          ),
          _dateFilter('Start date', _startDate, (v) => _startDate = v),
          _dateFilter('End date', _endDate, (v) => _endDate = v),
        ]),
      ]),
      if (component.workflowHistory)
        section(classes: 'sr-card sr-coverage', [
          div(classes: 'sr-coverage-group', [
            h3([Component.text('Workflow history coverage')]),
            p([
              Component.text(
                'Coverage describes available sources, not workflow execution or authorization. Missing history does not mean NOT_STARTED, FAILED or COMPLETED.',
              ),
            ]),
            ul([
              for (final source in component.sourceCoverage)
                li([Component.text(source)]),
            ]),
          ]),
          div(classes: 'sr-coverage-group', [
            h3([
              Component.text('Latest BCB status snapshots — not attempt history'),
            ]),
            p([
              Component.text(
                'Earlier failed build attempts may have been overwritten by recovery. No synthetic failure or invalidation events are created.',
              ),
            ]),
            if (component.currentSnapshots.isEmpty)
              p([
                Component.text(
                  'No BCB status snapshot was loaded; execution is not verified.',
                ),
              ])
            else
              ul([
                for (final snapshot in component.currentSnapshots)
                  li([Component.text(snapshot)]),
              ]),
          ]),
        ]),
      div(classes: 'sr-history-grid', [
        section(classes: 'sr-card sr-timeline', [
          div(classes: 'sr-card-head', [
            div([
              h2([_icon('timeline'), Component.text('Activity timeline')]),
              p([
                Component.text(
                  component.activitiesAvailable
                      ? '${all.length} matching '
                          '${all.length == 1 ? 'activity' : 'activities'}'
                          ' · Newest first'
                      : 'Timeline unavailable',
                ),
              ]),
            ]),
          ]),
          if (!component.activitiesAvailable)
            div(
              classes: 'sr-list-message',
              attributes: {'role': 'status'},
              [
                Component.text(
                  component.availabilityMessage ??
                      'Activity records are unavailable.',
                ),
              ],
            )
          else if (visible.isEmpty)
            div(classes: 'sr-empty-history', [
              span(classes: 'sr-icon', attributes: {'aria-hidden': 'true'}, [
                Icon('filter_list_off'),
              ]),
              h3([
                Component.text(
                  _source.isEmpty
                      ? 'No activities recorded yet'
                      : 'No matching activities',
                ),
              ]),
              p([
                Component.text(
                  _source.isEmpty
                      ? 'This assessment has no recorded events to show.'
                      : 'Try clearing some filters.',
                ),
              ]),
            ])
          else
            div(classes: 'sr-event-list', [
              for (final event in visible)
                button(
                  classes: selected?.eventId == event.eventId
                      ? 'sr-event selected'
                      : 'sr-event',
                  attributes: {
                    'type': 'button',
                    'data-event-id': event.eventId,
                    'aria-pressed':
                        '${selected?.eventId == event.eventId}',
                  },
                  events: events(
                    onClick: () =>
                        setState(() => _selectedEventId = event.eventId),
                  ),
                  [
                    div(classes: 'sr-event-top', [
                      strong([Component.text(event.title)]),
                      _statusBadge(event.status),
                    ]),
                    p(classes: 'sr-event-meta', [
                      Component.text(
                        '${event.engine} · ${_fmt(event.occurredAtIso)}',
                      ),
                    ]),
                    p(classes: 'sr-event-summary', [
                      Component.text(event.summary),
                    ]),
                  ],
                ),
            ]),
          div(classes: 'sr-pagination', [
            _button(
              '‹ Previous',
              page > 0
                  ? () => setState(() {
                      _page = page - 1;
                      _selectedEventId = null;
                    })
                  : null,
            ),
            span([
              Component.text(
                component.activitiesAvailable
                    ? 'Page ${page + 1} of $pages'
                    : 'Pagination unavailable',
              ),
            ]),
            _button(
              'Next ›',
              page + 1 < pages
                  ? () => setState(() {
                      _page = page + 1;
                      _selectedEventId = null;
                    })
                  : null,
            ),
          ]),
        ]),
        _details(selected),
      ]),
      p(classes: 'sr-footnote', [
        _icon('info'),
        Component.text(
          'Engine completion is not scientific acceptance, owner approval, report admission, or evidence sufficiency. All events must be backend-sourced.',
        ),
      ]),
    ]);
  }
}
