import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

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
  final String version;
  final List<String> inputReferences;
  final List<String> outputReferences;

  const AssessmentActivity({
    required this.eventId,
    required this.occurredAtIso,
    required this.engine,
    required this.activityType,
    required this.status,
    required this.title,
    required this.summary,
    required this.actor,
    required this.version,
    this.inputReferences = const [],
    this.outputReferences = const [],
  });
}

/// Not `@client`: it is mounted inside the `@client` route shell, and the
/// `@client` codegen rejects custom model parameters.
class ActivityHistoryPage extends StatefulComponent {
  final String businessName;
  final String assessmentId;
  final List<AssessmentActivity> activities;
  final VoidCallback? onBackToReport;
  final void Function(String eventId)? onViewFullLog;

  const ActivityHistoryPage({
    required this.businessName,
    required this.assessmentId,
    required this.activities,
    this.onBackToReport,
    this.onViewFullLog,
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

  List<AssessmentActivity> get _filtered {
    final items = component.activities.where((event) {
      final date = event.occurredAtIso.length >= 10 ? event.occurredAtIso.substring(0, 10) : '';
      if (_engine.isNotEmpty && event.engine != _engine) return false;
      if (_activityType.isNotEmpty && event.activityType != _activityType) return false;
      if (_status.isNotEmpty && event.status != _status) return false;
      if (_startDate.isNotEmpty && date.compareTo(_startDate) < 0) return false;
      if (_endDate.isNotEmpty && date.compareTo(_endDate) > 0) return false;
      return true;
    }).toList();
    items.sort((a, b) => b.occurredAtIso.compareTo(a.occurredAtIso));
    return items;
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
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final local = parsed.toLocal();
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    return '${local.day} ${months[local.month - 1]} ${local.year}, '
        '$hour:$minute';
  }

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
      onChange: (values) => setState(() {
        setCurrent(values.isEmpty ? '' : values.first);
        _resetSelection();
      }),
      [
        option(
          value: '',
          selected: current.isEmpty,
          [Component.text(allLabel ?? 'All $label')],
        ),
        for (final value in options)
          option(value: value, selected: current == value, [Component.text(value)]),
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
      value: current,
      onChange: (value) => setState(() {
        onValue(value);
        _resetSelection();
      }),
    ),
  ]);

  Component _button(String label, VoidCallback? handler) => button(
    classes: 'sr-button',
    attributes: {'type': 'button', if (handler == null) 'disabled': ''},
    events: events(onClick: () { if (handler != null) handler(); }),
    [Component.text(label)],
  );

  Component _referenceList(String title, List<String> refs) => section(classes: 'sr-detail-section', [
    h4([Component.text(title)]),
    if (refs.isEmpty)
      p([Component.text('No references supplied.')])
    else
      ul([for (final ref in refs) li([Component.text(ref)])]),
  ]);

  Component _details(AssessmentActivity? item) {
    if (item == null) {
      return section(classes: 'sr-card sr-detail', [
        h3([Component.text('Activity Details')]),
        p([Component.text('Select a recorded activity to see its full details.')]),
      ]);
    }
    return section(classes: 'sr-card sr-detail', [
      div(classes: 'sr-panel-heading', [
        h3([Component.text('Activity Details')]),
        _button('View full log (JSON)', component.onViewFullLog == null
            ? null
            : () => component.onViewFullLog!(item.eventId)),
      ]),
      h3([Component.text(item.title)]),
      p(classes: 'sr-subtitle', [Component.text('${_fmt(item.occurredAtIso)} · ${item.engine} · ${item.status}')]),
      section(classes: 'sr-detail-section', [
        h4([Component.text('Activity summary')]),
        p([Component.text(item.summary)]),
      ]),
      _referenceList('Inputs', item.inputReferences),
      _referenceList('Outputs', item.outputReferences),
      section(classes: 'sr-detail-section', [
        h4([Component.text('Engine details')]),
        p([Component.text('Engine: ${item.engine}')]),
        p([Component.text('Activity type: ${item.activityType}')]),
        p([Component.text('Event ID: ${item.eventId}')]),
      ]),
      section(classes: 'sr-detail-section', [
        h4([Component.text('Audit and version history')]),
        p([Component.text('Recorded by: ${item.actor}')]),
        p([Component.text('Version: ${item.version}')]),
        p([Component.text('This projection is read-only. Audit corrections require a new authorized backend event.')]),
      ]),
    ]);
  }

  @override
  Component build(BuildContext context) {
    final engines = <String>{'BDJ', 'BCB', 'QJ', 'QG', 'EE-01', 'Explanation', 'A10',
      ...component.activities.map((e) => e.engine)}.toList()..sort();
    final types = component.activities.map((e) => e.activityType).toSet().toList()..sort();
    final statuses = component.activities.map((e) => e.status).toSet().toList()..sort();
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

    return main_(classes: 'sr-workspace', [
      div(classes: 'sr-page-heading', [
        p(classes: 'sr-breadcrumb', [Component.text('Project1 › Review Portal › Activity History')]),
        h1([Component.text('Activity History')]),
        p(classes: 'sr-subtitle', [Component.text('A record of processing activities, decisions and updates with engine-level tracking.')]),
      ]),
      section(classes: 'sr-card sr-history-header', [
        div([
          h3([Component.text(component.businessName)]),
          p([Component.text('Assessment ${component.assessmentId} · Activity and engine logs')]),
        ]),
        _button('Back to report', component.onBackToReport),
      ]),
      section(classes: 'sr-card sr-filters', [
        h3([Component.text('Filters')]),
        div(classes: 'sr-filter-grid', [
          _selectFilter('Engine / Module', _engine, engines, (v) => _engine = v,
              allLabel: 'All engines'),
          _selectFilter(
              'Activity type', _activityType, types, (v) => _activityType = v,
              allLabel: 'All activities'),
          _selectFilter('Status', _status, statuses, (v) => _status = v,
              allLabel: 'All status'),
          _dateFilter('Start date', _startDate, (v) => _startDate = v),
          _dateFilter('End date', _endDate, (v) => _endDate = v),
          _button('Reset', () => setState(() {
            _engine = ''; _activityType = ''; _status = ''; _startDate = ''; _endDate = '';
            _resetSelection();
          })),
        ]),
      ]),
      div(classes: 'sr-history-grid', [
        section(classes: 'sr-card sr-timeline', [
          h3([Component.text('Activity Timeline (${all.length})')]),
          if (visible.isEmpty)
            p([Component.text('No recorded activity matches these filters.')])
          else
            for (final event in visible)
              button(
                classes: selected?.eventId == event.eventId ? 'sr-event selected' : 'sr-event',
                attributes: {'type': 'button'},
                events: events(onClick: () => setState(() => _selectedEventId = event.eventId)),
                [
                  div(classes: 'sr-event-heading', [
                    strong([Component.text(event.title)]),
                    span(classes: 'sr-status', [Component.text(event.status)]),
                  ]),
                  p([Component.text('${event.engine} · ${_fmt(event.occurredAtIso)}')]),
                  p([Component.text(event.summary)]),
                ],
              ),
          div(classes: 'sr-pagination', [
            _button('Previous', page > 0 ? () => setState(() { _page = page - 1; _selectedEventId = null; }) : null),
            span([Component.text('Page ${page + 1} of $pages')]),
            _button('Next', page + 1 < pages ? () => setState(() { _page = page + 1; _selectedEventId = null; }) : null),
          ]),
        ]),
        _details(selected),
      ]),
      p(classes: 'sr-footnote', [Component.text('Engine completion is not scientific acceptance, owner approval, report admission, or evidence sufficiency. All events must be backend-sourced.')]),
    ]);
  }
}
