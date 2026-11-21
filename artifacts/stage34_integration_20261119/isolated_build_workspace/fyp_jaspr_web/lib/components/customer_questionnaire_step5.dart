import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import 'ui.dart';

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

  /// True while a stage write is in flight.
  final bool busy;

  /// True when the backend already records this stage as complete.
  final bool stageComplete;

  /// Records progress for this stage. Null disables the control.
  final void Function()? onMarkComplete;

  const CustomerQuestionnaireStep5({
    super.key,
    required this.assessmentId,
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

  /// `null` | `publish` | `draft`. Preview-only: never sent anywhere.
  String? _decision;

  /// Which rows have their answer choices expanded, by row index.
  final Set<int> _expanded = <int>{};

  /// Inline feedback under the action stack.
  String? _feedback;
  bool _feedbackError = false;

  /// Respondent preview dialog.
  bool _previewOpen = false;
  int _previewIndex = 0;

  int get _total => questionnaireRows.length;
  int get _core => questionnaireRows.where((row) => !row.extra).length;
  int get _extra => questionnaireRows.where((row) => row.extra).length;

  void _say(String message, {bool error = false}) => setState(() {
    _feedback = message;
    _feedbackError = error;
  });

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
                'Check what customers would see. Review the questions, who '
                'receives them, and whether to share this questionnaire or '
                'save it for later.',
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
                        'The sample questionnaire below shows the questions '
                        'customers would be asked. Check the wording, answer '
                        'choices and who can see each question.',
                      ),
                    ]),
                  ]),
                ]),
                button(
                  classes: 'cq-preview-btn',
                  attributes: const {'type': 'button'},
                  events: events(
                    onClick: () => setState(() {
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
              if (_tab == 'list') _table(),
              if (_tab != 'list') div(classes: 'cq-detail-view', _detailView()),
              div(classes: 'cq-footnote', [
                Icon('info', size: 'sm'),
                span([
                  Component.text(
                    'Showing $_total sample questions: $_core standard and '
                    '$_extra extra. This is illustrative content, not a live '
                    'questionnaire.',
                  ),
                ]),
              ]),
            ]),
            p(classes: 'cq-preview-note', [
              Component.text(
                'Design preview only: the questionnaire and results shown here '
                'are examples. Publishing does not send anything to customers, '
                'and your live SiteWise account is not updated.',
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
                    _summaryRow('Total questions', '$_total'),
                    _summaryRow('Q01 – Q13 (core)', '$_core'),
                    _summaryRow('Approved extra question(s)', '$_extra'),
                    _summaryRow(
                      'Routing & applicability',
                      'Example rules',
                      good: true,
                    ),
                    _summaryRow(
                      'Content check (wording, options, consistency)',
                      'Not verified',
                      good: true,
                    ),
                  ]),
                ]),
              ]),
              section(classes: 'cq-panel', [
                div(classes: 'cq-decision-box', [
                  h3([Icon('flag', size: 'lg'), Component.text('What would you like to do?')]),
                  _decisionOption(
                    'publish',
                    'Publish questionnaire',
                    'Share the questionnaire with customers when it is ready.',
                  ),
                  _decisionOption(
                    'draft',
                    'Do not publish yet',
                    'Keep working on it before sharing it with customers.',
                  ),
                ]),
                div(classes: 'cq-action-stack', [
                  button(
                    classes: 'cq-primary',
                    attributes: const {'type': 'button'},
                    events: events(onClick: _publish),
                    [Icon('send', size: 'sm'), Component.text('Publish Questionnaire')],
                  ),
                  button(
                    classes: 'cq-secondary',
                    attributes: const {'type': 'button'},
                    events: events(onClick: _saveDraft),
                    [Icon('edit', size: 'sm'), Component.text('Save as Draft')],
                  ),
                  if (_feedback != null)
                    p(
                      classes:
                          'cq-action-feedback${_feedbackError ? ' is-error' : ''}',
                      attributes: const {'role': 'status', 'aria-live': 'polite'},
                      [Component.text(_feedback!)],
                    ),
                  // The design's two controls are preview-only, so stage
                  // progress needs its own control. Kept visually quiet and
                  // explicitly separated: it records progress, it does not
                  // publish anything.
                  if (!component.stageComplete && component.onMarkComplete != null)
                    div(classes: 'cq5__progress', [
                      button(
                        classes: 'cq5__progress-btn',
                        attributes: const {'type': 'button'},
                        events: events(
                          onClick: component.busy
                              ? null
                              : component.onMarkComplete,
                        ),
                        [
                          Icon('task_alt', size: 'sm'),
                          Component.text(
                            component.busy
                                ? 'Recording…'
                                : 'Mark this step complete',
                          ),
                        ],
                      ),
                      span([
                        Component.text(
                          'Records progress on assessment '
                          '${component.assessmentId} only. It publishes '
                          'nothing.',
                        ),
                      ]),
                    ])
                  else if (component.stageComplete)
                    p(classes: 'cq5__progress-note', [
                      Icon('check_circle', size: 'sm'),
                      Component.text('This step is recorded as complete.'),
                    ]),
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
      'Understand which customers would see each question in this '
          'demonstration.',
    'details' =>
      'Review the sample answer types and wording before the questionnaire is '
          'released.',
    _ =>
      'Browse all $_total example questions, answer choices and whether each '
          'question is shown to everyone.',
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
          for (var i = 0; i < questionnaireRows.length; i++) ...[
            _row(i, questionnaireRows[i]),
            if (_expanded.contains(i)) _expandedRow(questionnaireRows[i]),
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
        h4([Component.text('${row.id} — Sample answer choices')]),
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
          questionnaireRows.where((row) => row.applicabilityType == 'conditional');
      return [
        div(classes: 'cq-detail-box', [
          h4([Component.text('Questions shown to everyone')]),
          p([
            Component.text(
              '$_core sample questions are currently marked for all '
              'respondents.',
            ),
          ]),
        ]),
        div(classes: 'cq-detail-box', [
          h4([Component.text('Questions shown only to some customers')]),
          p([
            Component.text(
              '$_extra sample question uses a condition. Only eligible '
              'customers would see it.',
            ),
          ]),
          ul([
            for (final row in conditional)
              li([
                strong([Component.text(row.id)]),
                Component.text(' — ${row.question} '),
                em([Component.text('(sample rule: concept interest)')]),
              ]),
          ]),
        ]),
      ];
    }
    // details
    final counts = <String, int>{};
    for (final row in questionnaireRows) {
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

  Component _decisionOption(String value, String title, String detail) {
    final active = _decision == value;
    return label(
      classes: 'cq-decision-option${active ? ' active' : ''}',
      [
        input(
          attributes: {
            'type': 'radio',
            'name': 'cq-decision',
            'value': value,
            if (active) 'checked': '',
          },
          events: events(
            onChange: (_) => setState(() {
              _decision = value;
              _feedback = null;
            }),
          ),
        ),
        span([
          strong([Component.text(title)]),
          small([Component.text(detail)]),
        ]),
      ],
    );
  }

  void _publish() {
    if (_decision != 'publish') {
      _say(
        'Select “Publish questionnaire” above before continuing.',
        error: true,
      );
      return;
    }
    _say('Ready to publish in this preview. No live questionnaire has been published.');
  }

  void _saveDraft() {
    setState(() {
      _decision = 'draft';
      _feedbackError = false;
      _feedback =
          'Draft selected for this preview. Nothing has been sent to SiteWise.';
    });
  }

  Component _previewDialog() {
    final row = questionnaireRows[_previewIndex];
    final last = _previewIndex == questionnaireRows.length - 1;
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
              'Question ${_previewIndex + 1} of ${questionnaireRows.length}',
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
