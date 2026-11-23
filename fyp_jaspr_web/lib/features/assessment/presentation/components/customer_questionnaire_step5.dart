import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import 'package:sitewise_jaspr_web/shared/presentation/components/ui.dart';

/// Step 5 of the location-assessment workspace: the customer questionnaire
/// review screen.
///
/// This is a faithful port of the supplied design
/// (`SiteWise_Step5_Customer_Questionnaire.html` / `.css`), mounted as the
/// `assessment_report` checkpoint's body. The app's chrome — sidebar, top bar,
/// canvas and type — is untouched: every rule in
/// `web/sitewise_cq_step5.css` is scoped under `.cq5`, and the design's own
/// `:root` palette is re-expressed there in the app's tokens.
///
/// **Provenance of the question rows.** [questionnaireRows] is the design's own
/// illustrative fixture, reproduced verbatim. It is NOT an authoritative
/// instrument: the project's question bank is empty and unapproved, so this
/// screen must never be read as the effective questionnaire. The design's own
/// "Design preview only" note is kept on screen for exactly that reason, and
/// nothing here is sent to the backend.
///
/// Not `@client`: it is mounted inside the `@client` workspace page, and the
/// `@client` codegen rejects components with custom model parameters. Its
/// interactivity is ordinary component state on the client bundle.
class CustomerQuestionnaireStep5 extends StatefulComponent {
  /// The record whose stage 5 is on screen. Shown so the preview cannot be
  /// mistaken for a different assessment's questionnaire.
  final String assessmentId;

  /// Only owner-scoped, source-verified preview records may be passed here.
  /// An empty list is unavailable, never an invitation to load sample data.
  final List<CqRow> rows;

  /// The exact reason the server reported when no questionnaire rows are
  /// available. Shown verbatim so the page never invents a cause.
  final String? blockedReason;

  /// Returns to Stage 4. Null when the caller cannot navigate.
  final void Function()? onBack;

  /// True while a stage write is in flight.
  final bool busy;

  /// True when the backend already records this stage as complete.
  final bool stageComplete;

  /// Records progress for this stage. Null disables the control.
  final void Function()? onMarkComplete;

  const CustomerQuestionnaireStep5({
    super.key,
    required this.assessmentId,
    this.rows = const [],
    this.blockedReason,
    this.onBack,
    this.busy = false,
    this.stageComplete = false,
    this.onMarkComplete,
  });

  @override
  State<CustomerQuestionnaireStep5> createState() =>
      _CustomerQuestionnaireStep5State();
}

/// One row of the illustrative questionnaire.
class CqRow {
  final String id;
  final String question;
  final List<String> options;
  final String type;
  final String applicability;

  /// `all` or `conditional` — drives the applicability chip.
  final String applicabilityType;
  final String status;

  /// The approved extra question appended after Q01–Q13.
  final bool extra;

  const CqRow({
    required this.id,
    required this.question,
    required this.options,
    required this.type,
    required this.applicability,
    this.applicabilityType = 'all',
    this.status = 'Included',
    this.extra = false,
  });
}

/// The design's fixture, verbatim. Illustrative only — see the class doc.
const List<CqRow> questionnaireRows = [
  CqRow(
    id: 'Q01',
    question: 'How often do you visit a café?',
    options: ['Daily', 'Several times a week', 'Once a week', 'Less often'],
    type: 'Single choice',
    applicability: 'All respondents',
  ),
  CqRow(
    id: 'Q02',
    question: 'How do you usually hear about a new café?',
    options: [
      'Social media',
      'Friends / family',
      'Online review',
      'Walk-in discovery',
    ],
    type: 'Multiple choice',
    applicability: 'All respondents',
  ),
  CqRow(
    id: 'Q03',
    question: 'When do you usually visit a café?',
    options: [
      'Weekday daytime',
      'Weekday evening',
      'Weekend daytime',
      'Weekend evening',
    ],
    type: 'Single choice',
    applicability: 'All respondents',
  ),
  CqRow(
    id: 'Q04',
    question:
        'How important are the following factors when choosing a café? '
        '(for example: taste, price, and location)',
    options: ['Rating scale 1–5'],
    type: 'Rating (1–5)',
    applicability: 'All respondents',
  ),
  CqRow(
    id: 'Q05',
    question: 'Which type of café do you prefer?',
    options: [
      'Coffee-focused',
      'Café with meals',
      'Dessert café',
      'No preference',
    ],
    type: 'Single choice',
    applicability: 'All respondents',
  ),
  CqRow(
    id: 'Q06',
    question: 'How much would you usually spend during a café visit?',
    options: ['Under RM10', 'RM10–RM19', 'RM20–RM29', 'RM30 or more'],
    type: 'Single choice',
    applicability: 'All respondents',
  ),
  CqRow(
    id: 'Q07',
    question: 'Which café menu items would you buy?',
    options: ['Coffee', 'Tea', 'Pastries', 'Light meals'],
    type: 'Multiple choice',
    applicability: 'All respondents',
  ),
  CqRow(
    id: 'Q08',
    question: 'How far would you travel to visit a café you like?',
    options: [
      'Under 5 minutes',
      '5–15 minutes',
      '15–30 minutes',
      'Over 30 minutes',
    ],
    type: 'Single choice',
    applicability: 'All respondents',
  ),
  CqRow(
    id: 'Q09',
    question: 'How do you usually travel to cafés?',
    options: ['Walk', 'Car', 'Public transport', 'Other'],
    type: 'Single choice',
    applicability: 'All respondents',
  ),
  CqRow(
    id: 'Q10',
    question: 'How important is convenient parking when choosing a café?',
    options: [
      'Not important',
      'Slightly important',
      'Important',
      'Very important',
    ],
    type: 'Rating (1–5)',
    applicability: 'All respondents',
  ),
  CqRow(
    id: 'Q11',
    question: 'What would encourage you to visit a new café?',
    options: [
      'Good reviews',
      'Interesting menu',
      'Promotion',
      'Convenient location',
    ],
    type: 'Multiple choice',
    applicability: 'All respondents',
  ),
  CqRow(
    id: 'Q12',
    question: 'Which café atmosphere do you prefer?',
    options: ['Quiet', 'Social', 'Family-friendly', 'No preference'],
    type: 'Single choice',
    applicability: 'All respondents',
  ),
  CqRow(
    id: 'Q13',
    question: 'How likely are you to recommend a café you enjoy?',
    options: ['Very unlikely', 'Unlikely', 'Likely', 'Very likely'],
    type: 'Single choice',
    applicability: 'All respondents',
  ),
  CqRow(
    id: 'Q14',
    question:
        'How interested are you in a café that offers specialty coffee and '
        'local desserts?',
    options: [
      'Very interested',
      'Somewhat interested',
      'Neutral',
      'Not interested',
    ],
    type: 'Single choice',
    applicability: 'Conditional (concept interest)',
    applicabilityType: 'conditional',
    extra: true,
  ),
];

class _CustomerQuestionnaireStep5State
    extends State<CustomerQuestionnaireStep5> {
  /// `list` | `routing` | `details`.
  String _tab = 'list';

  /// Which rows have their answer choices expanded, by row index.
  final Set<int> _expanded = <int>{};

  /// Respondent preview dialog.
  bool _previewOpen = false;
  int _previewIndex = 0;

  int get _total => component.rows.length;
  int get _core => component.rows.where((row) => !row.extra).length;
  int get _extra => component.rows.where((row) => row.extra).length;

  @override
  void didUpdateComponent(covariant CustomerQuestionnaireStep5 oldComponent) {
    super.didUpdateComponent(oldComponent);
    if (oldComponent.assessmentId != component.assessmentId ||
        !identical(oldComponent.rows, component.rows)) {
      _previewOpen = false;
      _previewIndex = 0;
      _expanded.clear();
      _tab = 'list';
    }
  }

  @override
  Component build(BuildContext context) {
    return div(classes: 'cq5', [
      section(attributes: const {'aria-label': 'Customer questionnaire review'}, [
        div(classes: 'cq-heading', [
          div(classes: 'cq-heading-icon', [
            Icon('assignment', size: 'lg'),
          ]),
          div([
            div(classes: 'cq-heading-eyebrow', [
              Component.text('Step 5 of 5'),
            ]),
            h2([Component.text('Customer Questionnaire')]),
            p([
              Component.text(
                'Review available questionnaire records for this assessment. '
                'This page cannot publish or collect answers.',
              ),
            ]),
          ]),
        ]),
        div(classes: 'cq-layout', [
          div(classes: 'cq-main', [
            section(classes: 'cq-panel', [
              div(classes: 'cq-panel-head', [
                div(classes: 'cq-panel-title', [
                  Icon('assignment', size: 'lg'),
                  div([
                    h3([Component.text('Customer questionnaire preview')]),
                    p([
                      Component.text(
                        'Review verified questions and their sources. Questionnaire content is unavailable until linked records are verified.',
                      ),
                    ]),
                  ]),
                ]),
                button(
                  classes: 'cq-preview-btn',
                  attributes: const {'type': 'button'},
                  events: events(
                    onClick: component.rows.isEmpty ? null : () => setState(() {
                      _previewIndex = 0;
                      _previewOpen = true;
                    }),
                  ),
                  [Icon('visibility', size: 'sm'), Component.text('Preview as Respondent')],
                ),
              ]),
              div(
                classes: 'cq-tabs',
                attributes: const {
                  'role': 'group',
                  'aria-label': 'Questionnaire views',
                },
                [
                  _tabButton('list', 'list', 'Question list', '($_total)'),
                  _tabButton('routing', 'groups', 'Who sees each question', ''),
                  _tabButton('details', 'info', 'Question details', ''),
                ],
              ),
              div(
                classes: 'cq-view-copy',
                attributes: const {'aria-live': 'polite'},
                [Component.text(_viewCopy())],
              ),
              if (component.rows.isEmpty)
                div(classes: 'cq-blocked', [
                  strong([Component.text('Questionnaire unavailable')]),
                  p([
                    Component.text(
                      (component.blockedReason ?? '').trim().isNotEmpty
                          ? component.blockedReason!.trim()
                          : 'Questionnaire records are unavailable for this assessment. No sample questions are substituted.',
                    ),
                  ]),
                  if (RegExp(r'^[A-Z0-9_]{6,80}$')
                      .hasMatch((component.blockedReason ?? '').trim()))
                    p([
                      Component.text(
                        'The server could not verify a questionnaire source for this '
                        'assessment. No questions are shown, and nothing is published '
                        'or fielded.',
                      ),
                    ]),
                  if (component.onBack != null)
                    button(
                      classes: 'cq-secondary',
                      attributes: const {'type': 'button'},
                      events: events(onClick: component.onBack),
                      [Icon('arrow_back', size: 'sm'), Component.text('Back to Stage 4')],
                    ),
                ])
              else if (_tab == 'list') _table(),
              if (component.rows.isNotEmpty && _tab != 'list') div(classes: 'cq-detail-view', _detailView()),
              div(classes: 'cq-footnote', [
                Icon('info', size: 'sm'),
                span([
                  Component.text(
                    'Showing $_total verified preview items. A preview does not authorize fielding.',
                  ),
                ]),
              ]),
            ]),
            p(classes: 'cq-preview-note', [
              Component.text(
                'Read-only preview for assessment ${component.assessmentId}. No customer answers are collected.',
              ),
            ]),
          ]),
          aside(
            classes: 'cq-aside',
            attributes: const {
              'aria-label': 'Questionnaire review summary and decision',
            },
            [
              section(classes: 'cq-panel', [
                div(classes: 'cq-summary-box', [
                  h3([Icon('assignment', size: 'lg'), Component.text('Questionnaire Review Summary')]),
                  dl(classes: 'cq-summary-list', [
                    _summaryRow('Total questions', component.rows.isEmpty ? 'Unavailable' : '$_total'),
                    _summaryRow('Q01 – Q13 (core)', component.rows.isEmpty ? 'Unavailable' : '$_core'),
                    _summaryRow('Accepted draft question(s)', component.rows.isEmpty ? 'Unavailable' : '$_extra'),
                    _summaryRow(
                      'Routing & applicability',
                      'Unavailable',
                    ),
                    _summaryRow(
                      'Content check (wording, options, consistency)',
                      'Not verified',
                    ),
                  ]),
                ]),
              ]),
              section(classes: 'cq-panel', [
                div(classes: 'cq-decision-box', [
                  h3([Component.text('Preview only')]),
                  p([Component.text('Publication and questionnaire completion are unavailable. No questions are sent to customers.')]),
                ]),
              ]),
            ],
          ),
        ]),
      ]),
      if (_previewOpen) _previewDialog(),
    ]);
  }

  String _viewCopy() => switch (_tab) {
    'routing' =>
      'Review the verified applicability information available for each question.',
    'details' =>
      'Review the answer types and wording available in this preview.',
    _ =>
      'Browse the available questions and answer choices.',
  };

  Component _tabButton(String key, String icon, String label, String suffix) {
    final on = _tab == key;
    return button(
      classes: 'cq-tab${on ? ' is-active' : ''}',
      attributes: {
        'type': 'button',
        'aria-pressed': on.toString(),
      },
      events: events(onClick: () => setState(() => _tab = key)),
      [
        Icon(icon, size: 'sm'),
        Component.text(' $label'),
        if (suffix.isNotEmpty) span(attributes: const {'id': 'cq-total-badge'}, [
          Component.text(' $suffix'),
        ]),
      ],
    );
  }

  Component _table() => div(classes: 'cq-table-wrap', [
    table(
      classes: 'cq-table',
      attributes: const {'aria-describedby': 'cq-preview-note'},
      [
        thead([
          tr([
            th([Component.text('#')]),
            th([Component.text('Question')]),
            th([Component.text('Type')]),
            th([Component.text('Applicability')]),
            th([Component.text('Status')]),
            th(attributes: const {'aria-label': 'Expand row'}, []),
          ]),
        ]),
        tbody([
          for (var i = 0; i < component.rows.length; i++) ...[
            _row(i, component.rows[i]),
            if (_expanded.contains(i)) _expandedRow(component.rows[i]),
          ],
        ]),
      ],
    ),
  ]);

  Component _row(int index, CqRow row) {
    final open = _expanded.contains(index);
    return tr([
      td([
        span(
          classes: 'cq-qid${row.extra ? ' cq-extra' : ''}',
          [Component.text(row.id)],
        ),
      ]),
      td([
        div(classes: 'cq-question', [Component.text(row.question)]),
        div(classes: 'cq-options', [
          Component.text(row.options.join(' • ')),
        ]),
      ]),
      td([
        span(classes: 'cq-type', [
          Icon(_typeIcon(row.type), size: 'sm'),
          Component.text(' ${row.type}'),
        ]),
      ]),
      td([
        span(
          classes:
              'cq-chip cq-chip--${row.applicabilityType == 'conditional' ? 'conditional' : 'all'}',
          [Component.text(row.applicability)],
        ),
      ]),
      td([
        span(classes: 'cq-chip cq-chip--included', [
          Icon('check_circle', size: 'sm'),
          Component.text(' ${row.status}'),
        ]),
      ]),
      td([
        button(
          classes: 'cq-expand',
          attributes: {
            'type': 'button',
            'aria-expanded': open.toString(),
            'aria-label': 'Show answer choices for ${row.id}',
          },
          events: events(
            onClick: () => setState(() {
              if (open) {
                _expanded.remove(index);
              } else {
                _expanded.add(index);
              }
            }),
          ),
          [Icon(open ? 'expand_less' : 'expand_more', size: 'sm')],
        ),
      ]),
    ]);
  }

  Component _expandedRow(CqRow row) => tr(classes: 'cq-inline-details', [
    td(attributes: const {'colspan': '6'}, [
      div(classes: 'cq-detail-box', [
        h4([Component.text('${row.id} — Answer choices')]),
        p([Component.text(row.options.join(' • '))]),
      ]),
    ]),
  ]);

  static String _typeIcon(String type) {
    if (type.startsWith('Multiple')) return 'checklist';
    if (type.startsWith('Rating')) return 'bar_chart';
    return 'radio_button_checked';
  }

  List<Component> _detailView() {
    if (_tab == 'routing') {
      final conditional =
          component.rows.where((row) => row.applicabilityType == 'conditional');
      return [
        div(classes: 'cq-detail-box', [
          h4([Component.text('Questions shown to everyone')]),
          p([
            Component.text(
              '$_core questions are marked for all '
              'respondents.',
            ),
          ]),
        ]),
        div(classes: 'cq-detail-box', [
          h4([Component.text('Questions shown only to some customers')]),
          p([
            Component.text(
              '$_extra draft question(s) use a condition. Only eligible '
              'customers would see it.',
            ),
          ]),
          ul([
            for (final row in conditional)
              li([
                strong([Component.text(row.id)]),
                Component.text(' — ${row.question} '),
                em([Component.text('(${row.applicability})')]),
              ]),
          ]),
        ]),
      ];
    }
    // details
    final counts = <String, int>{};
    for (final row in component.rows) {
      counts[row.type] = (counts[row.type] ?? 0) + 1;
    }
    return [
      div(classes: 'cq-detail-box', [
        h4([Component.text('How customers can respond')]),
        ul([
          for (final entry in counts.entries)
            li([
              Component.text(
                '${entry.key} — ${entry.value} '
                '${entry.value == 1 ? 'question' : 'questions'}',
              ),
            ]),
        ]),
      ]),
      div(classes: 'cq-detail-box', [
        h4([Component.text('Before you share')]),
        p([
          Component.text(
            'Read each question in plain language. Check answer choices for '
            'missing or overlapping options. Check that each question appears '
            'only for the people it applies to.',
          ),
        ]),
      ]),
    ];
  }

  Component _summaryRow(String label, String value, {bool good = false}) =>
      div(classes: 'cq-summary-row', [
        dt([Component.text(label)]),
        dd([
          span(
            classes: good ? 'cq-summary-good' : '',
            [Component.text(value)],
          ),
        ]),
      ]);

  Component _previewDialog() {
    final row = component.rows[_previewIndex];
    final last = _previewIndex == component.rows.length - 1;
    final multiple = row.type.startsWith('Multiple');
    return div(classes: 'cq5__scrim', [
      div(
        classes: 'respondent-dialog',
        attributes: const {
          'role': 'dialog',
          'aria-modal': 'true',
          'aria-labelledby': 'respondent-title',
        },
        [
          div(classes: 'respondent-dialog-head', [
            div([
              p(classes: 'stage-guidance-kicker', [
                Component.text('CUSTOMER VIEW · DEMONSTRATION'),
              ]),
              h2([Component.text('Questionnaire preview')]),
              p([
                Component.text(
                  'This is an example of what customers might see. Your '
                  'answers will not be collected.',
                ),
              ]),
            ]),
            button(
              classes: 'dialog-close',
              attributes: const {
                'type': 'button',
                'aria-label': 'Close questionnaire preview',
              },
              events: events(onClick: () => setState(() => _previewOpen = false)),
              [Component.text('✕')],
            ),
          ]),
          div(classes: 'respondent-question-number', [
            Component.text(
              'Question ${_previewIndex + 1} of ${component.rows.length}',
            ),
          ]),
          h3(classes: 'respondent-question-title', [
            Component.text(row.question),
          ]),
          fieldset([
            legend(classes: 'sr-only', [
              Component.text('Choose an answer for the sample question'),
            ]),
            for (final option in row.options)
              label([
                input(attributes: {'type': multiple ? 'checkbox' : 'radio', 'name': 'respondent-option'}),
                span([Component.text(option)]),
              ]),
          ]),
          div(classes: 'respondent-dialog-actions', [
            button(
              classes: 'outline-button',
              attributes: {'type': 'button', if (_previewIndex == 0) 'disabled': ''},
              events: events(
                onClick: _previewIndex == 0
                    ? null
                    : () => setState(() => _previewIndex--),
              ),
              [Component.text('Previous')],
            ),
            button(
              classes: 'blue-button',
              attributes: const {'type': 'button'},
              events: events(
                onClick: () => setState(() {
                  if (last) {
                    _previewOpen = false;
                  } else {
                    _previewIndex++;
                  }
                }),
              ),
              [Component.text(last ? 'Finish preview' : 'Next question')],
            ),
          ]),
        ],
      ),
    ]);
  }
}
