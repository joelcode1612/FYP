import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import 'package:sitewise_jaspr_web/core/di/app_locator.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/stage5_composed_api.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/stage5_composed_questionnaire.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/stage5_publication_api.dart';
import 'package:sitewise_jaspr_web/shared/presentation/components/ui.dart';

/// Step 5 of the location-assessment workspace: the composed questionnaire.
///
/// **What this screen shows.** The real composed document for this assessment,
/// retrieved from `GET /assessments/{m2_id}/stage5/composed-questionnaire`:
/// the 13 governed core questions with the server's substitution applied, every
/// additional question that already carries an owner approval, the objective
/// each one is bound to, the owner's own intended answer as entrepreneur-only
/// metadata, and an explicit statement of what is still unresolved.
///
/// **What it does not do.** It retrieves; it never composes, approves or
/// regenerates. There is no per-question control on the fixed core, because the
/// fixed core is not individually reviewable — what it needs is a scientific
/// approval recorded elsewhere. The Publish control is rendered **disabled**
/// with the server's blockers beside it: publication and customer fielding are
/// separate decisions that this document cannot make.
///
/// **States are kept apart.** "Your declaration moved" (stale) is not "the
/// service is down" (error) and neither is "no additional question is eligible"
/// (a valid, fully explained document). An empty Section B is always explained
/// by requirement and exclusion codes rather than by a blank list.
///
/// Not `@client`: it is mounted inside the `@client` workspace page, and the
/// `@client` codegen rejects components with custom model parameters. Its
/// interactivity is ordinary component state on the client bundle.
class CustomerQuestionnaireStep5 extends StatefulComponent {
  /// The marketplace assessment this checkpoint belongs to. Shown so the
  /// document cannot be mistaken for a different assessment's questionnaire.
  final String assessmentId;

  /// A directly known M2 assessment id. When empty the component resolves the
  /// marketplace→M2 link itself, which is the normal Stage 5 path.
  final String m2AssessmentId;

  /// The governed composed-questionnaire transport. Defaults to the real
  /// authenticated client; a component test substitutes a recorded document.
  final Stage5ComposedPort api;

  /// The publication transport. Defaults to the real authenticated client; a
  /// component test substitutes a recorded report.
  ///
  /// Publication is a distinct operation with its own database principal
  /// (`p1_cq_publisher`), so it is a separate port rather than a method on
  /// [api]: the composed read runs as the M2 runtime and must not acquire the
  /// ability to mint the instrument it renders.
  final Stage5PublicationPort publication;

  /// Returns to Stage 4. Null when the caller cannot navigate.
  final void Function()? onBack;

  /// True while a stage write is in flight. Disables the reload control.
  final bool busy;

  const CustomerQuestionnaireStep5({
    super.key,
    required this.assessmentId,
    this.m2AssessmentId = '',
    this.api = const Stage5ComposedApi(),
    this.publication = const Stage5PublicationApi(),
    this.onBack,
    this.busy = false,
  });

  @override
  State<CustomerQuestionnaireStep5> createState() =>
      _CustomerQuestionnaireStep5State();
}

/// Which of the mutually exclusive states the panel is in.
enum _Phase { loading, ready, stale, blocked, failed }

class _CustomerQuestionnaireStep5State
    extends State<CustomerQuestionnaireStep5> {
  _Phase _phase = _Phase.loading;
  ComposedQuestionnaire? _document;

  /// The server's own refusal sentence or failure message, rendered verbatim.
  String? _message;

  /// The machine-readable code behind [_message], when there was one. Shown as
  /// a quiet monospace tag so a reader can quote it, never used as wording.
  String? _code;

  /// Expanded rows of the fixed-core table, by item id.
  final Set<String> _expanded = <String>{};

  /// Which of the three preserved views is on screen:
  /// `list` | `routing` | `details`.
  String _tab = 'list';

  /// Respondent preview dialog.
  bool _previewOpen = false;
  int _previewIndex = 0;

  // -- publication (DD-096) --------------------------------------------------
  //
  // The resolved M2 assessment id, which is what the publication routes take.
  // Kept so the publish control does not have to re-resolve the link.
  String? _m2Id;

  // The server's own answer to "what would publishing do", read as the
  // publication principal. Null means "not asked yet", which is different from
  // "asked and refused" and is never rendered as the latter.
  PublicationReport? _publication;

  /// True while a publish request is in flight.
  bool _publishing = false;

  /// Outcome of the last publish attempt. Kept apart from [_message] on
  /// purpose: a publish refusal is a property of the document's readiness, not
  /// a failure to load it, and must not blank the questionnaire.
  String? _publishNote;
  String? _publishCode;

  // -- candidate target (fielding plan) --------------------------------------
  //
  // How many candidates the entrepreneur intends to field this questionnaire
  // to. It is their own planning figure, never a count of responses the server
  // has collected.
  //
  // It is **not** a publication gate. It used to be, and because the figure
  // lived only in this component's state it made the publish control look
  // broken for anyone who had not typed a number -- while the number itself
  // reached no server and changed nothing about the instrument. Publication
  // readiness is now the server's answer (see [_publication]); the target
  // remains as a planning note. Null means "not set yet", which is different
  // from zero and is never rendered as zero.
  int? _candidateTarget;

  /// The value the slider and number box are showing but that has not been
  /// committed with "Set" yet.
  int _candidateDraft = 100;

  // -- business context (BCB) ------------------------------------------------
  //
  // Resolved because the questionnaire is composed against a *confirmed*
  // declaration whose business context is what the research questions are
  // supposed to describe. It is reported, not enforced: the composed route
  // itself gates on the confirmation, so a BCB read failure must degrade the
  // provenance line rather than blank a document the server already composed.
  String _contextId = '';
  String _contextStatus = 'UNRESOLVED';
  bool _contextSourceCurrent = false;
  String? _contextError;

  /// Guards the asynchronous read against a newer one. Switching assessment
  /// while a request is in flight must not paint the previous assessment's
  /// questionnaire under the new heading.
  int _loadRequest = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateComponent(covariant CustomerQuestionnaireStep5 oldComponent) {
    super.didUpdateComponent(oldComponent);
    if (oldComponent.assessmentId != component.assessmentId ||
        oldComponent.m2AssessmentId != component.m2AssessmentId) {
      _expanded.clear();
      _previewOpen = false;
      _previewIndex = 0;
      _document = null;
      _load();
    }
  }

  /// Resolves the M2 binding, then retrieves the composed document.
  ///
  /// Every step can independently make the view wrong, so nothing is shown
  /// until the link, the draft revision and the current confirmation agree.
  Future<void> _load() async {
    final request = ++_loadRequest;
    setState(() {
      _phase = _Phase.loading;
      _document = null;
      _message = null;
      _code = null;
      _contextId = '';
      _contextStatus = 'UNRESOLVED';
      _contextSourceCurrent = false;
      _contextError = null;
      // Publication readiness belongs to the previous assessment until the new
      // one is read; keeping it would show one assessment's release id under
      // another assessment's heading.
      _m2Id = null;
      _publication = null;
      _publishNote = null;
      _publishCode = null;
    });

    try {
      final String m2Id;
      if (component.m2AssessmentId.isNotEmpty) {
        m2Id = component.m2AssessmentId;
      } else {
        final linked = await AppLocator.m2.linkForMarketplace(
          component.assessmentId,
        );
        final linkedId = linked?['m2_assessment_id'];
        if (linkedId is! String || linkedId.isEmpty) {
          _block(
            'No M2 research record is linked to this assessment, so there is no '
            'composed questionnaire to retrieve. Complete the business '
            'declaration in Stage 2 first.',
          );
          return;
        }
        m2Id = linkedId;
      }

      final draft = await AppLocator.m2.read(m2Id);
      if (!mounted || request != _loadRequest) return;
      _m2Id = m2Id;

      final confirmation = await AppLocator.m2.currentConfirmation(m2Id);
      if (!mounted || request != _loadRequest) return;
      final confirmationId = confirmation?['id'];
      if (confirmation == null ||
          confirmation['assessment_revision'] != draft.revision ||
          confirmationId is! String ||
          confirmationId.isEmpty) {
        _stale(
          'Your business declaration has moved since it was confirmed '
          '(revision ${draft.revision}). The questionnaire is composed against a '
          'confirmed revision, so nothing is shown until you confirm the current '
          'declaration again in Stage 2.',
        );
        return;
      }

      // Business context for this confirmation. Non-fatal by design: the
      // composed route does not require it, so a failure here must not hide a
      // document the server already composed. It is reported in the summary and
      // in the routing view instead.
      try {
        final status = await AppLocator.m2.contextStatus(
          m2Id,
          confirmationId,
          draft.revision,
        );
        if (!mounted || request != _loadRequest) return;
        final contextId = status['context_id'];
        _contextId = contextId is String ? contextId : '';
        _contextStatus = status['status'] as String? ?? 'UNKNOWN';
        _contextSourceCurrent = status['source_is_current'] == true;
      } on Object catch (error) {
        if (!mounted || request != _loadRequest) return;
        _contextStatus = 'UNRESOLVED';
        _contextError = '$error';
      }

      final result = await component.api.read(
        assessmentId: m2Id,
        expectedRevision: draft.revision,
        confirmationId: confirmationId,
      );
      if (!mounted || request != _loadRequest) return;

      if (!result.ok) {
        final failure = result.failure!;
        if (isStaleComposedSource(failure.code)) {
          _stale(
            'The questionnaire was composed against an earlier revision of your '
            'declaration. Re-read the current confirmation to see the '
            'questionnaire for revision ${draft.revision}.',
          );
        } else if (isUnreadableAssessment(failure.code)) {
          _block(
            'This assessment\'s questionnaire could not be read by this account. '
            'It is not shown rather than shown empty.',
          );
        } else {
          _fail(failure.message, failure.code);
        }
        return;
      }

      final document = result.value!;
      // The server echoes the binding it composed against. A mismatch means the
      // payload belongs to another assessment or revision, which must never be
      // rendered under this heading.
      if (document.assessmentId != m2Id ||
          document.assessmentRevision != draft.revision) {
        _fail(
          'The server returned a questionnaire composed for a different '
          'assessment or revision, so it was not shown.',
          null,
        );
        return;
      }

      setState(() {
        _document = document;
        _phase = _Phase.ready;
      });

      // Publication readiness, asked after the document is shown rather than
      // before: the questionnaire is the reason the reader is here, and a
      // publication service that is down must not hide it. The failure is
      // recorded on the publish card only.
      await _loadPublication(m2Id, request);
    } on Object catch (error) {
      if (!mounted || request != _loadRequest) return;
      _fail('The questionnaire could not be retrieved: $error', null);
    }
  }

  void _stale(String message) {
    if (!mounted) return;
    setState(() {
      _phase = _Phase.stale;
      _message = message;
      _code = null;
      _document = null;
    });
  }

  void _block(String message) {
    if (!mounted) return;
    setState(() {
      _phase = _Phase.blocked;
      _message = message;
      _code = null;
      _document = null;
    });
  }

  void _fail(String message, String? code) {
    if (!mounted) return;
    setState(() {
      _phase = _Phase.failed;
      _message = message;
      _code = code;
      _document = null;
    });
  }

  List<ComposedItem> get _items => _document?.items ?? const <ComposedItem>[];

  @override
  Component build(BuildContext context) {
    return div(classes: 'cq5', [
      section(
        attributes: const {'aria-label': 'Customer questionnaire review'},
        [
          _heading(),
          _metaStrip(),
          div(classes: 'cqr-layout', [
            div(classes: 'cqr-main', [_mainCard()]),
            _aside(),
          ]),
        ],
      ),
      if (_previewOpen && _items.isNotEmpty) _previewDialog(),
    ]);
  }

  /// One header: the stage, the object, and the one thing this page cannot do.
  ///
  /// The previous layout opened with an icon block, an eyebrow, an `h2` and a
  /// paragraph, and then repeated all four in the panel head underneath. The
  /// second copy is gone; nothing it said was lost, because the composition
  /// facts it described now live in the meta strip and the footer.
  Component _heading() => div(classes: 'cqr-head', [
    div(classes: 'cqr-head__main', [
      span(classes: 'cqr-head__icon', [Icon('assignment', size: 'lg')]),
      div([
        div(classes: 'cqr-head__eyebrow', [Component.text('Step 5 of 5')]),
        h2([Component.text('Customer Questionnaire')]),
        p(classes: 'cqr-head__sub', [Component.text(_headerLine(_document))]),
      ]),
    ]),
    button(
      classes: 'cqr-head__act',
      attributes: {'type': 'button', if (_items.isEmpty) 'disabled': ''},
      events: events(
        onClick: _items.isEmpty
            ? null
            : () => setState(() {
                _previewIndex = 0;
                _previewOpen = true;
              }),
      ),
      [Icon('visibility', size: 'sm'), Component.text('Preview as Respondent')],
    ),
  ]);

  /// States the count and the revision when there is a document, and states the
  /// absence when there is not. Never a zero standing in for "not loaded".
  ///
  /// DD-096: this page publishes the instrument. Saying it "cannot publish the
  /// questionnaire" above a working Publish button was the last surviving
  /// sentence from the hard-disabled version. Collecting answers is still not
  /// this page's job, and publishing still does not start fielding.
  String _headerLine(ComposedQuestionnaire? document) {
    if (document == null) {
      return 'The composed wording is shown here once it is retrieved. Nothing '
          'is published until it is retrieved.';
    }
    return '${document.totalCount} questions composed for revision '
        '${document.assessmentRevision}. Publishing this page fixes the '
        'instrument; it does not start fielding or collect answers.';
  }

  /// The five composition facts, as one strip beside the document they describe.
  ///
  /// This replaces the seven-row summary list that used to sit in the rail. A
  /// summary of the document is a property of the document, not a decision, so
  /// it belongs next to the questions rather than in the column that holds the
  /// publication gate.
  Component _metaStrip() {
    final document = _document;
    final checked = document?.validation.passed;
    final contextCurrent = _contextStatus == 'PERSISTED' && _contextSourceCurrent;
    return div(
      classes: 'cqr-meta',
      attributes: const {'aria-label': 'Composition summary'},
      [
        _metaCell(
          'Questions',
          document == null ? 'Unavailable' : '${document.totalCount}',
          sub: document == null
              ? 'no composed document'
              : '${document.fixedCoreCount} core + ${document.additionalCount} '
                    'additional',
        ),
        _metaCell(
          'Revision',
          document == null ? 'Unavailable' : '${document.assessmentRevision}',
          sub: 'composed against',
        ),
        _metaCell(
          'Composition',
          document == null
              ? 'Not run'
              : checked == true
              ? 'PASS'
              : 'FAILED',
          sub: document == null
              ? 'nothing checked yet'
              : '${document.validation.checkCount} checks · population '
                    '${_pretty(document.populationStatus).toLowerCase()}',
          tone: document == null ? null : (checked == true ? 'ok' : 'warn'),
        ),
        _metaCell(
          'Excluded',
          document == null ? 'Unavailable' : '${document.excludedCount}',
          sub: 'candidate(s) not eligible',
        ),
        _metaCell(
          'Business context (BCB)',
          _contextStatus == 'PERSISTED' ? 'Persisted' : _contextStatus,
          sub: _contextStatus == 'PERSISTED'
              ? '${_short(_contextId)} · ${contextCurrent ? 'current' : 'not current'}'
              : (_contextError ?? 'no context resolved'),
          tone: contextCurrent ? 'ok' : 'warn',
        ),
      ],
    );
  }

  Component _metaCell(
    String label,
    String value, {
    String? sub,
    String? tone,
  }) => div(classes: 'cqr-meta__cell', [
    div(classes: 'cqr-meta__k', [Component.text(label)]),
    div(
      classes: 'cqr-meta__v${tone == null ? '' : ' cqr-meta__v--$tone'}',
      [Component.text(value)],
    ),
    if (sub != null) div(classes: 'cqr-meta__sub', [Component.text(sub)]),
  ]);

  /// The main column: view tabs, the document's own verdicts, then the view.
  Component _mainCard() {
    final document = _document;
    return section(classes: 'cqr-card', [
      _tabs(),
      ..._body(),
      _foot(document),
    ]);
  }

  Component _tabs() => div(
    classes: 'cqr-tabs',
    attributes: const {'role': 'group', 'aria-label': 'Questionnaire views'},
    [
      _tabButton('list', 'Question list', _items.length),
      _tabButton('routing', 'Who sees each question', null),
      _tabButton('details', 'Question details', null),
      span(classes: 'cqr-tabs__end', [
        Component.text('Read-only · wording as composed'),
      ]),
    ],
  );

  /// One view tab. Underlined rather than boxed: three bordered buttons above
  /// the first question read as three actions, and only one of them changes the
  /// page.
  Component _tabButton(String key, String label, int? count) {
    final on = _tab == key;
    return button(
      classes: 'cqr-tab${on ? ' is-active' : ''}',
      attributes: {'type': 'button', 'aria-pressed': on.toString()},
      events: events(onClick: () => setState(() => _tab = key)),
      [
        Component.text(label),
        if (count != null) span(classes: 'cqr-tab__n', [Component.text('$count')]),
      ],
    );
  }

  /// The one honesty statement this page makes, said once.
  Component _foot(ComposedQuestionnaire? document) => div(classes: 'cqr-foot', [
    Icon('info', size: 'sm'),
    span([
      Component.text(
        document == null
            ? 'Composition is not authorisation. No questionnaire is displayed, '
                  'and nothing is published or fielded.'
            : 'Composition is not authorisation. Showing ${document.totalCount} '
                  'composed item(s) at revision ${document.assessmentRevision} does '
                  'not permit fielding, and no customer answer is collected or '
                  'stored by this page.',
      ),
    ]),
  ]);

  // ------------------------------------------------------------------ body

  List<Component> _body() {
    switch (_phase) {
      case _Phase.loading:
        return [
          div(classes: 'cqr-pad', [
            div(
              classes: 'cq-blocked',
              attributes: const {'aria-busy': 'true'},
              [
                strong([Component.text('Composing the questionnaire…')]),
                p([
                  Component.text(
                    'Resolving your confirmed declaration and the composed '
                    'document. No questions are shown until both agree.',
                  ),
                ]),
              ],
            ),
          ]),
        ];
      case _Phase.stale:
        return [
          div(classes: 'cqr-pad', [
            _notice(
              title: 'Your declaration moved',
              message: _message,
              icon: 'history',
              actionLabel: 'Re-read questionnaire',
            ),
          ]),
        ];
      case _Phase.blocked:
        return [
          div(classes: 'cqr-pad', [
            _notice(
              title: 'Questionnaire not available for this assessment',
              message: _message,
              icon: 'lock',
              actionLabel: 'Check again',
            ),
          ]),
        ];
      case _Phase.failed:
        return [
          div(classes: 'cqr-pad', [
            _notice(
              title: 'The questionnaire could not be loaded',
              message: _message,
              code: _code,
              icon: 'error',
              actionLabel: 'Try again',
              failed: true,
            ),
          ]),
        ];
      case _Phase.ready:
        final document = _document!;
        return [
          // The document's own verdicts stay above the tabs: they are properties
          // of the document, not of the view you happen to be looking at.
          _statusLine(document),
          ...switch (_tab) {
            'routing' => [div(classes: 'cqr-pad', _routingView(document))],
            'details' => [div(classes: 'cqr-pad', _detailsView(document))],
            _ => _listView(document),
          },
        ];
    }
  }

  Component _notice({
    required String title,
    required String? message,
    required String icon,
    required String actionLabel,
    String? code,
    bool failed = false,
  }) {
    return div(classes: 'cq-blocked${failed ? ' is-error' : ''}', [
      // The icon is a sibling of the text node rather than a prefix inside the
      // same string: a leading space would make the heading unaddressable by an
      // exact text finder.
      strong([Icon(icon, size: 'sm'), Component.text(title)]),
      p([
        Component.text(
          (message ?? '').trim().isNotEmpty
              ? message!.trim()
              : 'No cause was reported.',
        ),
      ]),
      if (code != null && code.isNotEmpty)
        p(classes: 'cq-code', [Component.text(code)]),
      if (component.onBack != null)
        button(
          classes: 'cq-secondary',
          attributes: const {'type': 'button'},
          events: events(onClick: component.onBack),
          [Icon('arrow_back', size: 'sm'), Component.text('Back to Stage 4')],
        ),
      button(
        classes: 'cq-secondary',
        attributes: {'type': 'button', if (component.busy) 'disabled': ''},
        events: events(onClick: component.busy ? null : _load),
        [Icon('refresh', size: 'sm'), Component.text(actionLabel)],
      ),
    ]);
  }

  /// The "Question list" tab: both sections plus the reasons the document is
  /// incomplete. This is the view the design called "Question list".
  List<Component> _listView(ComposedQuestionnaire document) {
    return [
      ..._fixedCoreSection(document),
      ..._additionalSection(document),
      ..._requirementsSection(document),
    ];
  }

  /// The "Who sees each question" tab.
  ///
  /// The composed contract carries **no** per-respondent applicability field —
  /// no `routing`, no `audience`, no `applicability`. The design's original tab
  /// was filled with an illustrative fixture that said "All respondents" for
  /// every row, which was invented. This view therefore reports the routing
  /// determinants the document actually contains (question class, construct,
  /// population state, and for additional questions the admitted objective they
  /// are bound to) and states plainly what is not recorded.
  List<Component> _routingView(ComposedQuestionnaire document) {
    final core = document.fixedCore;
    final extra = document.additional;

    final byClass = <String, List<String>>{};
    for (final item in core) {
      final key = item.questionClass ?? 'NOT_RECORDED';
      (byClass[key] ??= <String>[]).add(item.itemId);
    }
    final byConstruct = <String, List<String>>{};
    for (final item in core) {
      final key = item.construct ?? 'NOT_RECORDED';
      (byConstruct[key] ??= <String>[]).add(item.itemId);
    }

    return [
      div(classes: 'cq-detail-box', [
        h4([Component.text('Per-respondent routing is not recorded')]),
        p([
          Component.text(
            'This document records which questions exist, not which customer '
            'would be shown them. It carries no applicability, audience or '
            'branch condition, so none is displayed — and because nothing here '
            'is authorised for fielding, no respondent routing exists to '
            'describe yet.',
          ),
        ]),
      ]),
      div(classes: 'cq-detail-box', [
        h4([Component.text('Core questions by question class')]),
        p([
          Component.text(
            'The governed class is what decides how a core question is treated '
            'in an instrument. It is not an audience.',
          ),
        ]),
        ul([
          for (final entry in byClass.entries)
            li([
              strong([Component.text(_pretty(entry.key))]),
              Component.text(' — ${entry.value.join(', ')}'),
            ]),
        ]),
      ]),
      div(classes: 'cq-detail-box', [
        h4([Component.text('Core questions by construct')]),
        ul([
          for (final entry in byConstruct.entries)
            li([
              strong([Component.text(_pretty(entry.key))]),
              Component.text(' — ${entry.value.join(', ')}'),
            ]),
        ]),
      ]),
      div(classes: 'cq-detail-box', [
        h4([Component.text('What an additional question is bound to')]),
        if (extra.isEmpty)
          p([
            Component.text(
              'No additional question is in this document, so there is no '
              'objective binding to show.',
            ),
          ])
        else
          ul([
            for (final item in extra)
              li([
                strong([Component.text(item.itemId)]),
                Component.text(
                  ' — objective ${_short(item.objectiveId)}, '
                  'admission ${_short(item.objectiveAdmissionId)}, '
                  'review ${_pretty(item.reviewDecision ?? 'NOT_RECORDED')}',
                ),
              ]),
          ]),
      ]),
      div(classes: 'cq-detail-box', [
        h4([Component.text('Business context this was composed against')]),
        p([
          Component.text(
            _contextStatus == 'PERSISTED' && _contextSourceCurrent
                ? 'A persisted business context is current for this confirmation '
                      '(${_short(_contextId)}). It is the declaration the '
                      'questions describe; it is not a routing rule.'
                : 'No current persisted business context was resolved for this '
                      'confirmation (status $_contextStatus'
                      '${_contextError == null ? '' : '; $_contextError'}). The '
                      'composed document is still shown, because composition is '
                      'gated on the confirmation, not on the context.',
          ),
        ]),
      ]),
    ];
  }

  /// The "Question details" tab: per item, what the server recorded.
  List<Component> _detailsView(ComposedQuestionnaire document) {
    final byFormat = <String, int>{};
    for (final item in document.items) {
      byFormat[item.responseFormat] = (byFormat[item.responseFormat] ?? 0) + 1;
    }
    return [
      div(classes: 'cq-detail-box', [
        h4([Component.text('How customers can respond')]),
        ul([
          for (final entry in byFormat.entries)
            li([
              Component.text(
                '${_pretty(entry.key)} — ${entry.value} '
                '${entry.value == 1 ? 'question' : 'questions'}',
              ),
            ]),
        ]),
      ]),
      for (final item in document.items) _itemDetailBox(item),
      div(classes: 'cq-detail-box', [
        h4([Component.text('Before you share')]),
        p([
          Component.text(
            'Read each question in plain language and check that its answer '
            'codes are complete. Routing, scientific approval and publication '
            'remain unavailable: this screen cannot grant any of them.',
          ),
        ]),
      ]),
    ];
  }

  Component _itemDetailBox(ComposedItem item) => div(classes: 'cq-detail-box', [
    h4([
      Component.text(
        '${item.itemId} — ${_pretty(item.questionClass ?? item.source)}',
      ),
    ]),
    p([Component.text(item.stem)]),
    if ((item.stemTemplate ?? '').trim().isNotEmpty &&
        item.stemTemplate != item.stem)
      p([Component.text('Template: ${item.stemTemplate}')]),
    p([
      Component.text(
        'Response: ${_pretty(item.responseFormat)} · '
        'construct ${_pretty(item.construct ?? '—')} · '
        'population ${_pretty(item.populationStatus ?? '—')}',
      ),
    ]),
    p([
      Component.text(
        'Measurement ${_pretty(item.measurementStatus ?? '—')} · '
        'approval ${_pretty(item.approvalState)} · '
        'review controls ${item.reviewControls}',
      ),
    ]),
    if (item.options.isNotEmpty)
      p([
        Component.text(
          'Answer codes: ${item.options.map((o) => o.display).join(', ')}',
        ),
      ]),
    if (item.unresolvedSlots.isNotEmpty)
      ul([
        for (final slot in item.unresolvedSlots)
          li([
            strong([Component.text(slot.token)]),
            Component.text(
              ' — needs ${slot.source}'
              '${slot.required ? ' (required)' : ' (optional)'}: ${slot.reason}',
            ),
          ]),
      ]),
    if (item.isAdditional)
      p([
        Component.text(
          'Objective ${_short(item.objectiveId)} · '
          'admission ${_short(item.objectiveAdmissionId)} · '
          'semantic basis ${_pretty(item.semanticBasis ?? '—')} · '
          'structural ${_pretty(item.structuralStatus ?? '—')} · '
          'semantic ${_pretty(item.semanticStatus ?? '—')} · '
          'provenance ${_pretty(item.provenanceStatus ?? '—')}',
        ),
      ]),
  ]);

  /// The document's own verdicts, stated before any question.
  ///
  /// A dot line rather than a row of pills: four filled pills above the first
  /// question read as four actions, and these are four facts about the document.
  Component _statusLine(ComposedQuestionnaire document) => div(
    classes: 'cqr-status',
    attributes: const {'aria-label': 'Composition status'},
    [
      _statusItem(
        'Composition ${_pretty(document.compositionStatus).toLowerCase()}',
        good: document.compositionValid,
      ),
      _statusItem(
        'Population ${_pretty(document.populationStatus).toLowerCase()}',
      ),
      _statusItem(
        document.additionalCount == 0
            ? 'No additional question eligible'
            : '${document.additionalCount} additional approved',
        good: document.additionalCount > 0,
      ),
      if (document.excludedCount > 0)
        _statusItem('${document.excludedCount} candidate(s) excluded'),
      if (document.blockingRequirements.isNotEmpty)
        _statusItem(
          '${document.blockingRequirements.length} blocking requirement(s)',
          warn: true,
        ),
      if (!document.validation.passed)
        _statusItem(
          'Validation failed (${document.validation.failureCount})',
          warn: true,
        ),
    ],
  );

  Component _statusItem(String label, {bool good = false, bool warn = false}) =>
      span(classes: 'cqr-status__i', [
        span(
          classes:
              'cqr-dot${good
                  ? ' cqr-dot--ok'
                  : warn
                  ? ' cqr-dot--warn'
                  : ''}',
          const [],
        ),
        Component.text(label),
      ]);

  List<Component> _fixedCoreSection(ComposedQuestionnaire document) {
    final items = document.fixedCore;
    return [
      _sectionHead(
        'Core questions',
        '${items.length}',
        'Q01–Q13 · governed · not editable here',
      ),
      if (items.isEmpty)
        div(classes: 'cqr-pad', [
          div(classes: 'cq-blocked', [
            strong([Component.text('The governed core is empty')]),
            p([
              Component.text(
                'The composition service returned no fixed-core question, which is '
                'a server-side condition. Nothing is substituted here.',
              ),
            ]),
          ]),
        ])
      else
        div(classes: 'cqr-list', [
          for (final item in items) _coreRow(item),
        ]),
    ];
  }

  /// One governed question: id, wording, option preview, one format label.
  ///
  /// The six-column table this replaces carried two columns — measurement and
  /// approval — whose value was identical on all thirteen rows, and a third
  /// whose text was clipped by the panel edge at 1280px. Those constants are now
  /// stated once in the section head, and the wording gets the width instead.
  Component _coreRow(ComposedItem item) {
    final open = _expanded.contains(item.itemId);
    return div(classes: 'cqr-row-wrap', [
      div(classes: 'cqr-row', [
        span(classes: 'cqr-id', [Component.text(item.itemId)]),
        div([
          p(classes: 'cqr-stem', [Component.text(item.stem)]),
          if (item.hasUnresolvedRequiredSlot)
            span(classes: 'cqr-flag', [
              Component.text(
                'Unresolved: '
                '${item.unresolvedSlots.where((slot) => slot.required).map((slot) => slot.token).join(', ')}',
              ),
            ])
          else if (item.options.isNotEmpty)
            div(classes: 'cqr-opts', [
              Component.text(
                item.options.map((opt) => opt.display).join(' · '),
              ),
            ]),
        ]),
        span(classes: 'cqr-fmt', [
          Component.text(_shortFormat(item.responseFormat)),
        ]),
        button(
          classes: 'cqr-chev',
          attributes: {
            'type': 'button',
            'aria-expanded': open.toString(),
            'aria-label': 'Show details for ${item.itemId}',
          },
          events: events(
            onClick: () => setState(() {
              if (open) {
                _expanded.remove(item.itemId);
              } else {
                _expanded.add(item.itemId);
              }
            }),
          ),
          [Icon(open ? 'expand_less' : 'chevron_right', size: 'sm')],
        ),
      ]),
      if (open) _coreDetail(item),
    ]);
  }

  Component _coreDetail(ComposedItem item) => div(classes: 'cqr-inline', [
    div(classes: 'cq-detail-box', [
      h4([Component.text('${item.itemId} — governed record')]),
      if ((item.stemTemplate ?? '').trim().isNotEmpty &&
          item.stemTemplate != item.stem)
        p([Component.text('Template: ${item.stemTemplate}')]),
      p([
        Component.text(
          'Construct: ${item.construct ?? 'not recorded'} · '
          'Class: ${item.questionClass ?? 'not recorded'}',
        ),
      ]),
      p([
        Component.text(
          'Review controls: ${item.reviewControls} · '
          'Authority to activate: '
          '${_pretty(item.authorityToActivate ?? 'NOT_RECORDED')}',
        ),
      ]),
      if (item.unresolvedSlots.isNotEmpty)
        ul([
          for (final slot in item.unresolvedSlots)
            li([
              strong([Component.text(slot.token)]),
              Component.text(
                ' — needs ${slot.source}${slot.required ? ' (required)' : ' (optional)'}: ${slot.reason}',
              ),
            ]),
        ]),
      p([
        Component.text(
          'Fielding authorised: ${item.fieldingAuthorized ? 'yes' : 'no'} · '
          'Publication authorised: '
          '${item.publicationAuthorized ? 'yes' : 'no'}',
        ),
      ]),
    ]),
  ]);

  /// A short, readable form of the response format for the row's right column.
  /// The full server token stays in the details view, unedited.
  static String _shortFormat(String raw) {
    if (raw.contains('MATRIX')) return 'Matrix';
    if (raw.contains('MULTI')) return 'Multi-select';
    return 'Single choice';
  }

  List<Component> _additionalSection(ComposedQuestionnaire document) {
    final items = document.additional;
    return [
      _sectionHead(
        'Additional questions',
        '${items.length}',
        'Approved by you in Stage 4',
      ),
      if (items.isEmpty)
        div(classes: 'cqr-pad', [
          div(classes: 'cq-blocked', [
            strong([Component.text('No additional question is included')]),
            p([
              Component.text(
                document.admittedObjectiveCount == 0
                    ? 'No research objective has been admitted for this '
                          'confirmation, so no additional question can be generated.'
                    : 'No generated question currently meets every eligibility '
                          'condition. The exclusions below state which condition '
                          'each one failed.',
              ),
            ]),
          ]),
        ])
      else
        for (final item in items) _additionalCard(item),
    ];
  }

  Component _additionalCard(
    ComposedItem item,
  ) => div(classes: 'cqr-add', [
    div(classes: 'cqr-add__head', [
      span(classes: 'cqr-id cqr-id--extra', [Component.text(item.itemId)]),
      span(classes: 'cqr-add__ok', [
        Component.text(_pretty(item.reviewDecision ?? 'APPROVED')),
      ]),
      if ((item.executionMode ?? '').isNotEmpty)
        span(classes: 'cqr-add__mode', [
          Component.text(_pretty(item.executionMode!)),
        ]),
    ]),
    p(classes: 'cqr-stem', [Component.text(item.stem)]),
    if (item.options.isNotEmpty)
      div(classes: 'cqr-add__opts', [
        for (final option in item.options)
          span(classes: 'cqr-opt', [Component.text(option.display)]),
      ]),
    p(classes: 'cqr-add__bind', [
      Component.text(
        'Objective ${_short(item.objectiveId)} · '
        'admission ${_short(item.objectiveAdmissionId)} · '
        'basis ${_pretty(item.semanticBasis ?? 'NOT_RECORDED')} · '
        'structural ${_pretty(item.structuralStatus ?? '—')} · '
        'semantic ${_pretty(item.semanticStatus ?? '—')} · '
        'provenance ${_pretty(item.provenanceStatus ?? '—')}',
      ),
    ]),
    if (item.hasScopedIntendedOption)
      div(classes: 'cqr-intended', [
        strong([Component.text('Your intended answer')]),
        span([Component.text(item.ownerIntendedOption!)]),
        small([
          Component.text(
            'Entrepreneur-only metadata. This is not a customer answer, is never '
            'preselected for a respondent, and is not read by any measurement.',
          ),
        ]),
      ]),
  ]);

  List<Component> _requirementsSection(ComposedQuestionnaire document) {
    final blocking = document.blockingRequirements;
    final exclusions = document.excludedCandidates;
    if (blocking.isEmpty && exclusions.isEmpty) {
      return [
        div(classes: 'cqr-block cqr-block--clear', [
          h4(classes: 'cqr-block__h', [
            Icon('check_circle', size: 'sm'),
            Component.text('What is still missing'),
          ]),
          p(classes: 'cqr-block__d', [
            Component.text(
              'The document reports no blocking requirement and no excluded '
              'candidate.',
            ),
          ]),
        ]),
      ];
    }
    return [
      // One card, not a section head plus a detail box. These rows are the
      // reason the publish control is closed, so they sit where the reader is
      // already looking for that answer.
      div(classes: 'cqr-block', [
        h4(classes: 'cqr-block__h', [
          Icon('report_problem', size: 'sm'),
          Component.text('What is still missing'),
        ]),
        for (final requirement in blocking)
          div(classes: 'cqr-block__item', [
            // The headline names the item and the reason in one line; the
            // server's own sentence goes below it, never concatenated onto it,
            // so the two cannot read as a single run-on statement.
            div(classes: 'cqr-block__t', [
              Component.text(
                (requirement.itemId ?? '').isNotEmpty
                    ? '${requirement.itemId} · ${requirement.label}'
                    : requirement.label,
              ),
              span(classes: 'cqr-block__code', [
                Component.text(requirement.code),
              ]),
            ]),
            p(classes: 'cqr-block__d', [Component.text(requirement.detail)]),
          ]),
        if (exclusions.isNotEmpty) ...[
          h4(classes: 'cqr-block__h cqr-block__h--sub', [
            Component.text('Excluded candidates (${exclusions.length})'),
          ]),
          for (final exclusion in exclusions)
            div(classes: 'cqr-block__item', [
              div(classes: 'cqr-block__t', [
                Component.text(
                  'Candidate ${_short(exclusion.candidateId)} · '
                  '${exclusion.label}',
                ),
                span(classes: 'cqr-block__code', [
                  Component.text(exclusion.reason),
                ]),
              ]),
            ]),
        ],
      ]),
    ];
  }

  /// A quiet group header: the title, its count, and at most one qualifier.
  ///
  /// The paragraph that used to follow each of these repeated copy that is
  /// already in the tab, the footer and the section itself.
  Component _sectionHead(String title, String count, String note) => div(
    classes: 'cqr-sec',
    [
      h3([Component.text(title)]),
      span(classes: 'cqr-sec__n', [Component.text(count)]),
      span(classes: 'cqr-sec__note', [Component.text(note)]),
    ],
  );

  // ----------------------------------------------------------------- aside

  Component _aside() {
    final document = _document;
    final target = _candidateTarget;
    final publishable = document?.isPublishable ?? false;
    return aside(
      classes: 'cqr-rail',
      attributes: const {'aria-label': 'Publication readiness'},
      [
        section(classes: 'cqr-card', [
          div(classes: 'cqr-card__head', [
            h3([Component.text('Readiness')]),
            span(classes: 'cqr-card__state', [
              Component.text(
                (_publication?.isAlreadyPublished ?? false)
                    ? 'Published'
                    : _publishAvailable
                    ? 'Ready'
                    : 'Not publishable',
              ),
            ]),
          ]),
          // The three conditions of [_publishAvailable], in the order the reader
          // can act on them.
          //
          // The previous layout stated the same three facts twice: as a bullet
          // list, and again as one run-on caption under the button. A reader who
          // set a target and saw the button stay closed read it as a broken
          // control. A checklist says which condition is missing, and the caption
          // keeps the full sentence for anyone reading with a screen reader.
          div(classes: 'cqr-gate', [
            _gateRow(
              met: target != null,
              title: 'Candidate target',
              detail: 'How many people you intend to field to. Your own plan; '
                  'it is not required to publish.',
              value: target == null ? 'Not planned' : '$target',
            ),
            _gateRow(
              met: publishable,
              title: 'Accepted for fielding',
              detail: publishable
                  ? 'Scientifically accepted and authorised for fielding.'
                  : 'Publishing the instrument and fielding it to real customers '
                        'are separate. Nothing in this document is scientifically '
                        'accepted, so it cannot be fielded.',
              value: publishable ? 'Yes' : 'Not accepted',
            ),
            _gateRow(
              met: _publication?.isPublishable ?? false,
              title: 'Publication service',
              detail: _publicationDetail(),
              value: _publicationValue(),
            ),
          ]),
          _candidateTargetBlock(),
          div(classes: 'cqr-gate__act', [
            button(
              classes: 'cq-publish',
              attributes: {
                'type': 'button',
                if (!_publishAvailable) 'disabled': '',
                'aria-disabled': (!_publishAvailable).toString(),
              },
              events: events(onClick: _publishAvailable ? _publish : null),
              [Component.text('Publish Questionnaire')],
            ),
            small(classes: 'cqr-gate__cap', [
              Component.text(_publishCaption(document)),
            ]),
          ]),
        ]),
      ],
    );
  }

  /// What the publication service actually said, in one line.
  ///
  /// A null report is "not read yet" or "could not be read", and the two are
  /// distinguished by [_publishCode] rather than collapsed into "unavailable".
  String _publicationDetail() {
    final report = _publication;
    if (report == null) {
      return _publishCode == null
          ? 'Reading publication readiness from the server.'
          : 'Publication readiness could not be read ($_publishCode).';
    }
    if (report.isAlreadyPublished) {
      return 'Release ${_short(report.releaseId)} is already published for '
          'this declaration; publishing again writes nothing.';
    }
    if (report.isPublished) {
      return 'Release ${_short(report.releaseId)} published. Customer fielding '
          'is still disabled.';
    }
    return '${report.authorizedCount} of ${report.questionCount} questions '
        'authorised. Publishing runs as ${report.principal}.';
  }

  String _publicationValue() {
    final report = _publication;
    if (report == null) return 'Unknown';
    if (report.isAlreadyPublished) return 'Published';
    if (report.isPublished) return 'Published';
    return report.authorizedCount > 0 ? 'Available' : 'Not ready';
  }

  Component _gateRow({    required bool met,
    required String title,
    required String detail,
    required String value,
  }) => div(classes: 'cqr-gate__row', [
    span(classes: 'cqr-gate__ico${met ? ' is-met' : ' is-unmet'}', [
      Icon(met ? 'check_circle' : 'cancel', size: 'sm'),
    ]),
    div([
      div(classes: 'cqr-gate__k', [Component.text(title)]),
      p(classes: 'cqr-gate__d', [Component.text(detail)]),
    ]),
    div(
      classes:
          'cqr-gate__v${met ? ' cqr-gate__v--met' : ' cqr-gate__v--unmet'}',
      [Component.text(value)],
    ),
  ]);

  // --------------------------------------------------------------- helpers

  /// True when the server says this questionnaire can be published now.
  ///
  /// Two conditions, both answered by the server rather than by this component:
  /// the document is publishable (nothing in it is unauthorised), and the
  /// publication report admits at least one authorised question. The previous
  /// version also required a locally typed candidate target and a hard-coded
  /// `false` "endpoint wired" flag, which is why the control could never open
  /// (DD-096).
  bool get _publishAvailable =>
      !_publishing && (_publication?.isPublishable ?? false);

  /// Every condition still missing, in the order the reader can act on them.
  ///
  /// Listing all of them matters here: a reader who fixes one and sees the
  /// button stay closed would otherwise read it as a broken control.
  String _publishCaption(ComposedQuestionnaire? document) {
    if (document == null) {
      return 'Unavailable until a composed questionnaire is retrieved.';
    }
    if (_publishing) return 'Publishing…';
    if (_publishNote != null) return _publishNote!;
    final report = _publication;
    if (report == null) {
      return _publishCode == null
          ? 'Reading publication readiness…'
          : 'Disabled: publication readiness could not be read '
                '($_publishCode).';
    }
    if (report.isAlreadyPublished) {
      return 'Already published. This questionnaire is unchanged since release '
          '${_short(report.releaseId)}, so publishing again would write '
          'nothing.';
    }
    if (report.isPublished) {
      return 'Published as release ${_short(report.releaseId)} '
          '(${report.authorizedCount} of ${report.questionCount} questions '
          'authorised). Customer fielding is still disabled.';
    }
    final missing = <String>[
      if (!document.isPublishable)
        'the document is not publishable — nothing in it is scientifically '
            'accepted or authorised for fielding',
      if (report.authorizedCount < 1)
        'no question survived authorisation, so the release would be empty',
    ];
    if (missing.isEmpty) return 'Ready to publish.';
    return 'Disabled: ${missing.join('; ')}.';
  }

  // -- candidate target -------------------------------------------------------

  /// Smallest and largest candidate target. The upper bound is a ceiling on the
  /// input, not a claim that any study this size has been run.
  static const int _candidateMin = 1;
  static const int _candidateMax = 9999;

  /// Clamps free-text entry into the accepted range. An unparseable value keeps
  /// the previous draft rather than silently becoming 1.
  int _clampCandidate(String raw) {
    final parsed = int.tryParse(raw.trim());
    if (parsed == null) return _candidateDraft;
    if (parsed < _candidateMin) return _candidateMin;
    if (parsed > _candidateMax) return _candidateMax;
    return parsed;
  }

  /// The publication gate: how many candidates this questionnaire is fielded to.
  ///
  /// A draft value is always visible, but only "Set" commits it. Until it is
  /// committed the publish control stays closed — that is the purpose of the
  /// control, not a side effect of it.
  Component _candidateTargetBlock() {
    final committed = _candidateTarget;
    return div(classes: 'cq-candidate', [
      // The gate row directly above already names this control and shows its
      // committed value, so the block only carries the control's own state. The
      // two inputs keep their own `aria-label`, so nothing is lost to a reader
      // who arrives at the slider first.
      div(classes: 'cq-candidate__head', [
        span(
          classes:
              'cq-candidate__state ${committed == null ? 'is-locked' : 'is-ready'}',
          [Component.text(committed == null ? 'Not set' : 'Set')],
        ),
      ]),
      input(
        type: InputType.range,
        classes: 'cq-candidate__range',
        attributes: {
          'min': '$_candidateMin',
          'max': '$_candidateMax',
          'step': '1',
          'value': '$_candidateDraft',
          'aria-label': 'Candidate target',
        },
        events: events<String>(
          onInput: (value) => setState(() {
            _candidateDraft = _clampCandidate(value);
          }),
        ),
      ),
      div(classes: 'cq-candidate__row', [
        input(
          type: InputType.number,
          classes: 'cq-candidate__num',
          attributes: {
            'min': '$_candidateMin',
            'max': '$_candidateMax',
            'step': '1',
            'value': '$_candidateDraft',
            'aria-label': 'Candidate target, exact number',
          },
          events: events<String>(
            onInput: (value) => setState(() {
              _candidateDraft = _clampCandidate(value);
            }),
          ),
        ),
        span(classes: 'cq-candidate__unit', [Component.text('candidates')]),
        button(
          classes: 'cq-candidate__set',
          attributes: const {'type': 'button'},
          events: events(
            onClick: () => setState(() {
              _candidateTarget = _candidateDraft;
            }),
          ),
          [Component.text(committed == null ? 'Set' : 'Update')],
        ),
      ]),
      div(classes: 'cq-candidate__meta', [
        span([
          Component.text('Range $_candidateMin – $_candidateMax'),
        ]),
        span([
          if (committed == null)
            Component.text('Draft · not set')
          else ...[
            strong([Component.text('$committed')]),
            Component.text(' candidates to invite'),
          ],
        ]),
      ]),
    ]);
  }

  /// Asks the publication service what publishing would do. Read-only.
  ///
  /// A failure here is recorded, never thrown: the composed document is already
  /// on screen and is still valid, so an unavailable publication service must
  /// degrade the publish card rather than the page.
  Future<void> _loadPublication(String m2Id, int request) async {
    try {
      final result = await component.publication.preview(assessmentId: m2Id);
      if (!mounted || request != _loadRequest) return;
      setState(() {
        _publication = result.ok ? result.value : null;
        _publishCode = result.ok ? null : result.failure?.code;
        _publishNote = result.ok
            ? null
            : (result.failure?.message ??
                  'Publication readiness could not be read.');
      });
    } on Object catch (error) {
      if (!mounted || request != _loadRequest) return;
      setState(() {
        _publication = null;
        _publishCode = null;
        _publishNote = 'Publication readiness could not be read: $error';
      });
    }
  }

  /// Publishes this questionnaire as the publication principal.
  ///
  /// The server decides: it re-builds the manifest from the confirmed
  /// declaration, verifies it, and refuses if anything is unresolved. Nothing
  /// here constructs wording, and nothing here can grant fielding authority --
  /// the response carries `runtimeActivated` and
  /// `productionFieldingAuthorized`, both false while customer fielding is
  /// disabled.
  Future<void> _publish() async {
    final m2Id = _m2Id;
    if (m2Id == null || _publishing) return;
    setState(() {
      _publishing = true;
      _publishNote = null;
      _publishCode = null;
    });
    try {
      final result = await component.publication.publish(assessmentId: m2Id);
      if (!mounted) return;
      if (!result.ok) {
        final failure = result.failure!;
        setState(() {
          _publishing = false;
          _publishCode = failure.code;
          _publishNote = failure.message;
        });
        return;
      }
      setState(() {
        _publishing = false;
        _publication = result.value;
        _publishCode = null;
        _publishNote = null;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _publishing = false;
        _publishCode = null;
        _publishNote = 'The publication request could not be completed: $error';
      });
    }
  }

  static String _pretty(String raw) {
    if (raw.isEmpty) return '—';
    return raw
        .split('_')
        .where((part) => part.isNotEmpty)
        .map((part) => part[0].toUpperCase() + part.substring(1).toLowerCase())
        .join(' ');
  }

  /// Abbreviates an identifier for display without hiding which one it is.
  static String _short(String? raw) {
    final value = (raw ?? '').trim();
    if (value.isEmpty) return 'not recorded';
    return value.length <= 8 ? value : value.substring(0, 8);
  }

  // -------------------------------------------------------- respondent view

  Component _previewDialog() {
    final items = _items;
    final item = items[_previewIndex];
    final last = _previewIndex == items.length - 1;
    final multiple = item.responseFormat.contains('MULTI');
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
                Component.text('CUSTOMER VIEW · NOT FIELDED'),
              ]),
              h2([Component.text('Questionnaire preview')]),
              p([
                Component.text(
                  'This is how the composed question would be shown. No answer '
                  'is collected, stored or counted, and nothing here is '
                  'published.',
                ),
              ]),
            ]),
            button(
              classes: 'dialog-close',
              attributes: const {
                'type': 'button',
                'aria-label': 'Close questionnaire preview',
              },
              events: events(
                onClick: () => setState(() => _previewOpen = false),
              ),
              [Component.text('✕')],
            ),
          ]),
          div(classes: 'respondent-question-number', [
            Component.text(
              'Question ${_previewIndex + 1} of ${items.length} · ${item.itemId}',
            ),
          ]),
          h3(classes: 'respondent-question-title', [Component.text(item.stem)]),
          fieldset([
            legend(classes: 'sr-only', [
              Component.text('Choose an answer for the previewed question'),
            ]),
            // No option is preselected, including an additional question whose
            // owner-intended option is known: that value is entrepreneur-only
            // metadata and must never appear as a respondent's answer.
            for (final option in item.options)
              label([
                input(
                  attributes: {
                    'type': multiple ? 'checkbox' : 'radio',
                    'name': 'respondent-option',
                  },
                ),
                span([Component.text(option.display)]),
              ]),
            if (item.options.isEmpty)
              p([
                Component.text(
                  'This question carries no answer options in the composed '
                  'document.',
                ),
              ]),
          ]),
          div(classes: 'respondent-dialog-actions', [
            button(
              classes: 'outline-button',
              attributes: {
                'type': 'button',
                if (_previewIndex == 0) 'disabled': '',
              },
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
