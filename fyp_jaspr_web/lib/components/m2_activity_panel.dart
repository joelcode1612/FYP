import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import '../data/app_locator.dart';
import '../pages/entrepreneur/activity_history_page.dart';
import 'ui.dart';
import 'saved_assessment_dropdown.dart';

@client
class M2ActivityPanel extends StatefulComponent {
  final String assessmentId;
  const M2ActivityPanel({super.key, this.assessmentId = ''});
  @override
  State<M2ActivityPanel> createState() => _M2ActivityState();
}

class _M2ActivityState extends State<M2ActivityPanel> {
  bool busy = true;
  String? error;
  List<Map<String, dynamic>> assessments = [];
  Map<String, dynamic>? activity;
  int _request = 0;
  String _selected = '';
  @override
  void initState() {
    super.initState();
    _selected = component.assessmentId;
    Future.microtask(() => _load(component.assessmentId));
  }

  Future<void> _load([String? id]) async {
    if (!mounted) return;
    final request = ++_request;
    // Explicit route/option IDs take precedence; refresh retains the user's
    // current selection rather than silently returning to the route default.
    final requestedId =
        id ?? (_selected.isNotEmpty ? _selected : component.assessmentId);
    setState(() {
      _selected = requestedId;
      busy = true;
      error = null;
      activity = null; // Never show a prior assessment's records while loading.
    });
    try {
      final rows = await AppLocator.m2.assessments();
      if (!mounted || request != _request) return;
      // Invalid or duplicate list data is not silently treated as no records.
      final seenIds = <String>{};
      for (final row in rows) {
        if (row['id'] is! String ||
            (row['id'] as String).isEmpty ||
            row['revision'] is! int ||
            !seenIds.add(row['id'] as String)) {
          throw const FormatException('Invalid saved M2 assessment list');
        }
      }

      // An unbound History route defaults to the first server-returned saved
      // M2 record. A direct link keeps its explicit ID (including when the
      // record falls outside the service's bounded 50-item list window).
      final selectedId = requestedId.isNotEmpty || rows.isEmpty
          ? requestedId
          : rows.first['id'] as String? ?? '';
      final value = selectedId.isEmpty
          ? null
          : await AppLocator.m2.activity(selectedId);
      if (!mounted || request != _request) return;
      if (value != null && value['assessment_id'] != selectedId) {
        throw StateError(
          'History response does not match assessment selection',
        );
      }
      setState(() {
        assessments = rows;
        _selected = selectedId;
        activity = value;
      });
    } catch (_) {
      if (mounted && request == _request) {
        setState(() {
          assessments = [];
          activity = null;
          error =
              'Saved activity could not be loaded from the current service. No substitute activity records are shown.';
        });
      }
    } finally {
      if (mounted && request == _request) setState(() => busy = false);
    }
  }

  @override
  void didUpdateComponent(covariant M2ActivityPanel oldComponent) {
    super.didUpdateComponent(oldComponent);
    if (oldComponent.assessmentId != component.assessmentId) {
      _load(component.assessmentId);
    }
  }

  /// Options are derived from the existing authenticated M2 service only.
  /// The mockup's illustrative UUIDs must never be included in this list.
  List<SavedAssessmentChoice> get _savedChoices => [
    for (final record in assessments)
      if (record['id'] is String && record['revision'] is int)
        SavedAssessmentChoice(
          assessmentId: record['id'] as String,
          revision: record['revision'] as int,
        ),
  ];

  @override
  Component build(BuildContext context) => section(classes: 'stack stack--md', [
    p([
      Component.text(
        'Saved upstream workflow metadata for an assessment you own. Private answers, business text and model payloads are not shown.',
      ),
    ]),
    if (busy)
      p(
        attributes: {'role': 'status'},
        [Component.text('Loading saved activity…')],
      ),
    if (assessments.length == 50)
      p([
        Component.text(
          'Showing the 50 most recent saved assessments. An existing direct M2 link can open an older assessment.',
        ),
      ]),
    div(classes: 'stack stack--sm', [
      ActivityHistoryPage(
        key: ValueKey(_selected),
        businessName: 'Saved M2 assessment',
        assessmentId: _selected,
        assessmentSelector: SavedAssessmentDropdown(
          assessments: _savedChoices,
          selectedAssessmentId: _selected.isEmpty ? null : _selected,
          loading: busy,
          error: error,
          onSelectAssessment: (id) {
            // Only IDs provided by the authenticated M2 list can be selected.
            if (!busy && assessments.any((a) => a['id'] == id)) _load(id);
          },
        ),
        activitiesAvailable: !busy && error == null && activity != null,
        workflowHistory: true,
        sourceCoverage: [
          'M2 / Business Understanding: ${activity == null
              ? 'NOT_VERIFIED — history source unavailable or not selected.'
              : activity?['history_extension'] == 'workflow-history-metadata/1'
              ? 'Persisted records loaded. Creation, answers, candidate-rule evaluation, findings, decisions, review and confirmation only; validation failures and distinct submission attempts are not durably exposed.'
              : 'Legacy M2 receipts loaded. Additional creation, finding, uncertainty and BCB sources are NOT_VERIFIED; the workflow history extension is unavailable.'}',
          'BDJ cloud: NOT_VERIFIED — no owner-scoped durable execution, output-validation or recovery history API. Candidate-rule receipts are not cloud completion.',
          'BCB: ${activity?['bcb_history_available'] == true ? 'Persisted context metadata and latest status snapshots loaded. Currentness is a read-time revision check, not an invalidation event or new authorization.' : 'NOT_VERIFIED — context/history source unavailable or unsupported.'}',
          'QJ: NOT_VERIFIED — no version-bound research processing/route/review history API.',
          'Question Bank / QG: NOT_VERIFIED — no authorized reuse/candidate/technical-review history API.',
          'Scientific / Owner / Fielding: NOT_VERIFIED — independent authorization decisions are not supplied by this history source.',
          'Customer Questionnaire: NOT_VERIFIED — respondent history contains private answers; no authorized assessment-level campaign/session metadata binding is available.',
        ],
        currentSnapshots: [
          for (final b in activity?['bcb_statuses'] as List? ?? const [])
            'Confirmation ${b['confirmation_id']} · revision ${b['assessment_revision']} · ${b['status']} · attempts ${b['attempt_count']} · updated ${b['updated_at']} · reason ${b['last_code'] ?? 'Not recorded'} · context ${b['context_id'] ?? 'None recorded'} · ${b['source_is_current'] == true ? 'source revision current' : 'historical source; not a current handoff'}. Actor not recorded; scientific and Owner authorization not supplied.',
          if (activity?['bcb_statuses_truncated'] == true)
            'Only the latest BCB snapshots in the bounded source window are shown.',
        ],
        availabilityMessage: busy
            ? 'Loading saved activity…'
            : error ??
                  'Select a saved M2 assessment to load its recorded activity.',
        activities: [
          for (final e in activity?['events'] as List? ?? const [])
            AssessmentActivity(
              eventId: '${e['kind']}:${e['event_id']}',
              occurredAtIso: e['occurred_at'] as String,
              engine: e['module'] as String? ?? 'M2',
              activityType: e['kind'] as String,
              status:
                  e['status'] as String? ?? 'Recorded — outcome not supplied',
              title: e['kind'] as String,
              summary:
                  'Persisted ${e['module'] ?? 'M2'} metadata at revision ${e['assessment_revision']}.',
              actor:
                  e['actor_id'] as String? ?? 'Actor not stored on this record',
              version: '${e['assessment_revision']}',
              reason: e['reason'] as String?,
              sourceIsCurrent: e['source_is_current'] as bool?,
              inputReferences: [
                activity!['assessment_id'] as String,
                if (e['source_id'] != null) e['source_id'] as String,
              ],
              outputReferences: [e['event_id'] as String],
            ),
        ],
      ),
      if (activity?['truncated'] == true)
        p([
          Component.text(
            'Only the most recent saved events are shown. Pagination covers this loaded window; the API has no older-history cursor.',
          ),
        ]),
    ]),
    ActionButton(
      'Refresh saved activity',
      onClick: busy ? null : () => _load(_selected),
    ),
    a(href: '/entrepreneur/m2-entry', [
      Component.text('Open M2 questionnaire'),
    ]),
  ]);
}
