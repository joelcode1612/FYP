import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

/// Read-only *workflow* preview. Selected radio/checkbox values are ephemeral
/// UI state and never submitted, measured or written to the backend.
///
/// The caller must supply the *verified* versioned Q01-Q13 instruments rather
/// than using the illustrative HTML fixture as questionnaire authority.
class QuestionnairePreviewItem {
  final String id;
  final String shortTitle;
  final String prompt;
  final String help;
  final String construct;
  final String measurementGate;
  final List<String> options;
  final bool multiple;
  final bool blocked;

  /// Inventory grouping shown in the preview rail (e.g. "C. Occasions and
  /// features"). Empty means ungrouped.
  final String group;

  /// Provenance shown in the Question details panel.
  final String source;
  final String version;

  const QuestionnairePreviewItem({
    required this.id,
    required this.shortTitle,
    required this.prompt,
    required this.help,
    required this.construct,
    required this.measurementGate,
    this.options = const [],
    this.multiple = false,
    this.blocked = false,
    this.group = '',
    this.source = 'Existing bank — verify exact item revision',
    this.version = 'Not supplied',
  });
}

class QgCandidatePreview {
  final QuestionnairePreviewItem item;
  final String ownerDisposition;
  final String candidateVersion;
  final String bankEquivalenceStatus;
  final String stimulusStatus;

  const QgCandidatePreview({
    required this.item,
    required this.ownerDisposition,
    required this.candidateVersion,
    required this.bankEquivalenceStatus,
    required this.stimulusStatus,
  });

  bool get ownerAccepted => ownerDisposition == 'OWNER_ACCEPTED_FOR_REVIEW';
}

/// Stage-level component: wrap in the EXISTING AppLayout/topbar and named route.
/// Does not introduce a second application shell or update a persisted stage.
///
/// Not `@client`: it is mounted inside the `@client` workspace page, and the
/// `@client` codegen rejects custom model parameters.
class CustomerQuestionnairePreviewPage extends StatefulComponent {
  final List<QuestionnairePreviewItem> bank;
  final List<QgCandidatePreview> candidates;
  final String assessmentTitle;
  final String assessmentId;
  final String reviewPortalHref;

  const CustomerQuestionnairePreviewPage({
    super.key,
    required this.bank,
    required this.candidates,
    required this.assessmentTitle,
    required this.assessmentId,
    this.reviewPortalHref = '/entrepreneur/assessments/review-portal',
  });

  @override
  State<CustomerQuestionnairePreviewPage> createState() =>
      _CustomerQuestionnairePreviewPageState();
}

class _CustomerQuestionnairePreviewPageState
    extends State<CustomerQuestionnairePreviewPage> {
  String? _activeId;
  final Map<String, Set<String>> _ephemeralSelections = {};

  @override
  Component build(BuildContext context) {
    final accepted = [
      for (final candidate in component.candidates)
        if (candidate.ownerAccepted) candidate,
    ];
    final questions = <QuestionnairePreviewItem>[
      ...component.bank,
      for (final candidate in accepted) candidate.item,
    ];
    if (questions.isEmpty) {
      return div(classes: 'qp-page', [
        div(classes: 'crumb', [
          a(href: component.reviewPortalHref,
              [Component.text('Review Portal')]),
          Component.text('  ›  Customer Questionnaire Preview'),
        ]),
        h1(classes: 'rp-title', [
          Component.text('Customer Questionnaire Preview'),
        ]),
        section(classes: 'qp-empty-card', [
          strong([Component.text('No questionnaire records found')]),
          p([
            Component.text(
              'No versioned question bank and no owner-accepted QG candidate '
              'were supplied for ${component.assessmentId}. No question text is '
              'generated to fill the gap.',
            ),
          ]),
        ]),
        a(href: component.reviewPortalHref, classes: 'qp-back', [
          span(classes: 'material-symbols-rounded', [
            Component.text('arrow_back'),
          ]),
          Component.text('Return to candidate review'),
        ]),
      ]);
    }
    final defaultId = accepted.isNotEmpty
        ? accepted.first.item.id
        : questions.first.id;
    final selectedId = questions.any((question) => question.id == _activeId)
        ? _activeId!
        : defaultId;
    final position =
        questions.indexWhere((question) => question.id == selectedId);
    final selected = questions[position];
    final qg =
        accepted.where((candidate) => candidate.item.id == selected.id);
    final selectedCandidate = qg.isEmpty ? null : qg.first;

    return div(classes: 'qp-page', [
      div(classes: 'crumb', [
        a(href: '/entrepreneur/assessments', [Component.text('Project1')]),
        Component.text('  ›  '),
        a(href: component.reviewPortalHref,
            [Component.text('Review Portal')]),
        Component.text('  ›  Customer Questionnaire Preview'),
      ]),
      h1(classes: 'rp-title', [
        Component.text('Customer Questionnaire Preview'),
      ]),
      p(classes: 'rp-sub', [
        Component.text(
          'Inspect the existing Q01–Q13 research bank alongside '
          'entrepreneur-accepted QG candidate questions before scientific '
          'review.',
        ),
      ]),
      _infoStrip(accepted),
      div(classes: 'qp-grid', [
        _inventory(questions, selectedId),
        _questionCard(selected, selectedCandidate, position, questions.length),
        _aside(selected, selectedCandidate),
      ]),
      p(classes: 'footer-note', [
        Component.text(
          'Source matrix supplied item constructs, not verified exact stems '
          'for every item. Where needed, this page uses clearly marked '
          'illustrative wording or shows a blocked preview; it never presents '
          'an unverified draft as a fielded question. The current local QG '
          'owner acceptance state is a synthetic UI demonstration.',
        ),
      ]),
    ]);
  }

  Component _infoStrip(List<QgCandidatePreview> accepted) =>
      section(classes: 'rp-card qp-info', [
        div(classes: 'rp-summary__main', [
          span(classes: 'rp-ico blue', [
            span(classes: 'material-symbols-rounded', [
              Component.text('quiz'),
            ]),
          ]),
          div([
            h2([
              Component.text(
                '${component.assessmentTitle} — ${component.assessmentId}',
              ),
            ]),
            p(classes: 'small muted', [
              Component.text(
                'Customer questionnaire · Preview only · Not fielding',
              ),
            ]),
          ]),
        ]),
        div(classes: 'rp-summary__cell', [
          span(classes: 'mini-label', [Component.text('Original bank')]),
          p([Component.text('${component.bank.length} Q01–Q13 items')]),
        ]),
        div(classes: 'rp-summary__cell', [
          span(classes: 'mini-label', [
            Component.text('Accepted QG additions'),
          ]),
          p([Component.text('${accepted.length} candidate(s)')]),
        ]),
        div(classes: 'rp-summary__cell', [
          span(classes: 'mini-label', [Component.text('Authorization')]),
          span(classes: 'pill pending', [
            Component.text('Not fielding-approved'),
          ]),
        ]),
      ]);

  Component _qrow(QuestionnairePreviewItem item, String selectedId,
          {required bool isCandidate}) =>
      button(
        classes: 'qp-qrow ${item.id == selectedId ? 'is-active' : ''}',
        attributes: {
          'type': 'button',
          'aria-pressed': item.id == selectedId ? 'true' : 'false',
        },
        events: events(onClick: () => setState(() => _activeId = item.id)),
        [
          span(classes: 'qp-qrow__id', [
            Component.text(isCandidate ? 'QG+' : item.id),
          ]),
          span(classes: 'qp-qrow__title', [Component.text(item.shortTitle)]),
        ],
      );

  Component _inventory(
    List<QuestionnairePreviewItem> questions,
    String selectedId,
  ) {
    final accepted = [
      for (final candidate in component.candidates)
        if (candidate.ownerAccepted) candidate,
    ];
    final groups = <String, List<QuestionnairePreviewItem>>{};
    for (final item in component.bank) {
      groups.putIfAbsent(item.group.isEmpty ? 'Questions' : item.group,
          () => []).add(item);
    }
    return section(classes: 'rp-card qp-inventory', [
      div(classes: 'qp-inventory__head', [
        h3([Component.text('Question inventory')]),
        span(classes: 'pill outline', [
          Component.text('${questions.length}'),
        ]),
      ]),
      p(classes: 'qp-inventory__sub', [
        Component.text(
          '${component.bank.length} research-bank items plus accepted QG drafts',
        ),
      ]),
      for (final entry in groups.entries) ...[
        h4(classes: 'qp-group', [Component.text(entry.key)]),
        for (final item in entry.value)
          _qrow(item, selectedId, isCandidate: false),
      ],
      if (accepted.isNotEmpty)
        div(classes: 'qp-accepted', [
          h4(classes: 'qp-accepted__title', [
            Component.text('+ Accepted QG candidates'),
          ]),
          p(classes: 'qp-accepted__note', [
            Component.text(
              'Separate from the source bank. Shown because the entrepreneur/'
              'owner accepted them for review — not because they passed '
              'scientific checks.',
            ),
          ]),
          for (final candidate in accepted)
            _qrow(candidate.item, selectedId, isCandidate: true),
        ]),
    ]);
  }

  Component _questionCard(
    QuestionnairePreviewItem selected,
    QgCandidatePreview? selectedCandidate,
    int position,
    int total,
  ) {
    return section(classes: 'rp-card qp-question', [
      div(classes: 'qp-question__head', [
        div([
          span(
            classes: selectedCandidate == null ? 'pill blue' : 'pill green',
            [
              Component.text(selectedCandidate == null
                  ? 'Existing bank'
                  : 'Owner accepted · preview only'),
            ],
          ),
          h3([Component.text(selected.id)]),
        ]),
        span(classes: 'pill outline', [
          Component.text(
            '${position + 1} of $total preview items',
          ),
        ]),
      ]),
      div(classes: 'qp-question__body', [
        p(classes: 'qp-eyebrow', [
          Component.text('Question preview — no respondent submission'),
        ]),
        h2(classes: 'qp-prompt', [Component.text(selected.prompt)]),
        p(classes: 'qp-help', [Component.text(selected.help)]),
        if (selected.blocked || selected.options.isEmpty)
          div(classes: 'warning', [
            Component.text('Preview blocked: ${selected.measurementGate}'),
          ])
        else
          for (final (index, option) in selected.options.indexed)
            label(classes: 'qp-opt', [
              input(
                type: selected.multiple
                    ? InputType.checkbox
                    : InputType.radio,
                name: 'preview_${selected.id}',
                checked:
                    _ephemeralSelections[selected.id]?.contains(option) ??
                        false,
                onChange: (_) => _toggleChoice(selected, option),
              ),
              span(classes: 'qp-opt__letter', [
                Component.text(
                  '${String.fromCharCode(65 + index)}.',
                ),
              ]),
              span([Component.text(option)]),
            ]),
        p(classes: 'qp-hint', [
          Component.text(
            'Selections are UI-only and are not saved or submitted.',
          ),
        ]),
        div(classes: 'qp-info', [
          Component.text(selectedCandidate == null
              ? 'Preview-only item: historical bank or scientific wording/'
                  'route checks may still be pending.'
              : 'Owner acceptance is not scientific acceptance. The QG '
                  'equivalence, stimulus, pretest, route and fielding gates '
                  'remain independent.'),
        ]),
        div(classes: 'qp-nav', [
          div(classes: 'qp-nav__top', [
            div(classes: 'qp-dashes', [
              for (var i = 0; i < total; i++)
                span(classes: 'qp-dash ${i <= position ? 'is-on' : ''}', []),
            ]),
          ]),
          div(classes: 'qp-nav__row', [
            span(classes: 'qp-nav__count', [
              Component.text('${position + 1} / $total'),
            ]),
            span(classes: 'grow', []),
            button(
              classes: 'qp-btn qp-btn--ghost',
              attributes: {'type': 'button'},
              events: events(
                onClick: () => setState(_ephemeralSelections.clear),
              ),
              [Component.text('Clear demo selections')],
            ),
            button(
              classes: 'qp-btn',
              attributes: {
                'type': 'button',
                if (position == 0) 'disabled': '',
              },
              events: events(onClick: () {
                if (position > 0) {
                  setState(() => _jump(position - 1));
                }
              }),
              [
                span(classes: 'material-symbols-rounded', [
                  Component.text('chevron_left'),
                ]),
                Component.text('Previous'),
              ],
            ),
            button(
              classes: 'qp-btn qp-btn--primary',
              attributes: {
                'type': 'button',
                if (position == total - 1) 'disabled': '',
              },
              events: events(onClick: () {
                if (position + 1 < total) {
                  setState(() => _jump(position + 1));
                }
              }),
              [
                Component.text('Next'),
                span(classes: 'material-symbols-rounded', [
                  Component.text('chevron_right'),
                ]),
              ],
            ),
          ]),
        ]),
      ]),
    ]);
  }

  void _jump(int index) {
    final accepted = [
      for (final candidate in component.candidates)
        if (candidate.ownerAccepted) candidate,
    ];
    final questions = <QuestionnairePreviewItem>[
      ...component.bank,
      for (final candidate in accepted) candidate.item,
    ];
    if (index >= 0 && index < questions.length) {
      _activeId = questions[index].id;
    }
  }

  Component _qdetail(String label, String value) => div(
        classes: 'qp-detail',
        [
          span(classes: 'qp-detail__label', [Component.text(label)]),
          span(classes: 'qp-detail__value', [Component.text(value)]),
        ],
      );

  Component _aside(
    QuestionnairePreviewItem selected,
    QgCandidatePreview? selectedCandidate,
  ) =>
      div(classes: 'qp-aside', [
        section(classes: 'rp-card rp-panel', [
          div(classes: 'rp-panel__head', [
            span(classes: 'material-symbols-rounded', [
              Component.text('subject'),
            ]),
            h3([Component.text('Question details')]),
          ]),
          p(classes: 'qp-detail__hint', [
            Component.text('Measurement boundaries for the selected item.'),
          ]),
          div(classes: 'rp-panel__body', [
            _qdetail(
              'Source',
              selectedCandidate == null
                  ? selected.source
                  : 'Owner-accepted QG candidate (synthetic demo)',
            ),
            _qdetail('Construct', selected.construct),
            _qdetail(
              'Version',
              selectedCandidate == null ? selected.version : 'QG draft, unverified',
            ),
            _qdetail('Bank / measurement gate', selected.measurementGate),
            _qdetail(
              'Stimulus',
              selectedCandidate?.stimulusStatus ??
                  'Existing bank item — no stimulus change',
            ),
            _qdetail('Fielding authorization', 'NOT AUTHORIZED'),
          ]),
        ]),
        section(classes: 'rp-card rp-panel qp-rules', [
          div(classes: 'rp-panel__head', [
            span(classes: 'material-symbols-rounded', [
              Component.text('rule'),
            ]),
            h3([Component.text('Preview rules')]),
          ]),
          p(classes: 'qp-detail__hint', [
            Component.text('What this demonstration does and does not do.'),
          ]),
          div(classes: 'rp-panel__body', [
            for (final rule in const [
              'Preview only. Answers are temporary UI selections. There is no '
                  'real respondent, submission, measurement calculation, or '
                  'report admission.',
              'Original question IDs remain Q01–Q13.',
              'Owner-accepted QG candidates have distinct IDs.',
              'Rejected and pending candidates do not enter the preview.',
              'Scientific review and pretesting are still required.',
              'QJ routing, context and bank-equivalence gates stay independent.',
            ])
              div(classes: 'qp-rule', [
                span(classes: 'material-symbols-rounded', [
                  Component.text('check_circle'),
                ]),
                span([Component.text(rule)]),
              ]),
            a(href: component.reviewPortalHref, classes: 'qp-back', [
              span(classes: 'material-symbols-rounded', [
                Component.text('arrow_back'),
              ]),
              Component.text('Return to candidate review'),
            ]),
          ]),
        ]),
      ]);

  void _toggleChoice(QuestionnairePreviewItem item, String option) {
    setState(() {
      final choices = _ephemeralSelections.putIfAbsent(item.id, () => <String>{});
      if (item.multiple) {
        if (!choices.add(option)) choices.remove(option);
      } else {
        choices
          ..clear()
          ..add(option);
      }
    });
  }
}
