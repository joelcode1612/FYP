import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import 'customer_questionnaire_preview_page.dart';

/// A BDJ interpretation, not an externally verified business outcome.
class BdjReviewFinding {
  final String id;
  final String title;
  final String sourceRefs;
  final String revision;
  final String declaredAnswer;
  final String explanation;
  final String recommendedAction;
  final String verificationStatus;

  /// Optional review detail; defaults keep older call sites compiling.
  final List<String> measurementRequirements;
  final String limitations;
  final int relatedQuestions;
  final int evidenceCount;
  final int notesCount;
  final String updatedAt;
  final String updatedBy;
  final String reviewVersion;
  final String relatedM2;
  final String currentStatus;

  const BdjReviewFinding({
    required this.id,
    required this.title,
    required this.sourceRefs,
    required this.revision,
    required this.declaredAnswer,
    required this.explanation,
    required this.recommendedAction,
    required this.verificationStatus,
    this.measurementRequirements = const [],
    this.limitations = '',
    this.relatedQuestions = 0,
    this.evidenceCount = 0,
    this.notesCount = 0,
    this.updatedAt = '',
    this.updatedBy = 'System',
    this.reviewVersion = 'v1.0',
    this.relatedM2 = '',
    this.currentStatus = '',
  });
}

/// A research question from the existing Q01–Q13 bank, as listed in the
/// review rail. It carries no generated wording of its own.
class QjQuestion {
  final String id;
  final String shortTitle;
  final String construct;
  final String status;

  const QjQuestion({
    required this.id,
    required this.shortTitle,
    required this.construct,
    this.status = 'Pending review',
  });
}

/// This is the entrepreneur-authored three-section Business Description.
/// Keep the content separate from BDJ verification and financial planning.
class BusinessDescriptionSection {
  final String title;
  final List<String> paragraphs;

  const BusinessDescriptionSection({
    required this.title,
    required this.paragraphs,
  });
}

/// QJ/QG candidate shown in the owner/entrepreneur review interface.
/// The actual preview item is shared with CustomerQuestionnairePreviewPage.
class QgReviewCandidate {
  final QgCandidatePreview candidate;
  final String researchQuestion;
  final String respondentDefinition;
  final String stimulusRequirement;
  final String inferenceLimit;
  final String methodologicalNote;

  const QgReviewCandidate({
    required this.candidate,
    required this.researchQuestion,
    required this.respondentDefinition,
    required this.stimulusRequirement,
    required this.inferenceLimit,
    required this.methodologicalNote,
  });

  String get id => candidate.item.id;
}

class ReviewAuditEvent {
  final String candidateId;
  final String title;
  final String note;
  final String actor;
  final DateTime at;

  const ReviewAuditEvent({
    required this.candidateId,
    required this.title,
    required this.note,
    required this.actor,
    required this.at,
  });
}

/// Owner disposition only. This is NOT scientific or fielding authorization.
abstract final class QgOwnerDisposition {
  static const pending = 'PENDING_OWNER_REVIEW';
  static const accepted = 'OWNER_ACCEPTED_FOR_REVIEW';
  static const rejected = 'OWNER_REJECTED';
}

/// Inline body for the existing SITEWISE AppLayout. The existing top bar,
/// sidebar, routes and backend-authoritative journey must stay in the host app.
///
/// Pass [onDispositionChanged] for the host's authenticated, version-checked,
/// server-audited write. Without it, the decision is UI-only and is lost after
/// remounting; it is never represented as a persisted or authorized result.
///
/// Not `@client`: it is mounted inside the `@client` workspace page, and the
/// `@client` codegen rejects custom model parameters.
class ReviewPortalPage extends StatefulComponent {
  final String assessmentTitle;
  final String assessmentId;
  final String batchId;
  final List<BdjReviewFinding> findings;
  final List<BusinessDescriptionSection> descriptionSections;
  final List<QgReviewCandidate> candidates;
  final List<ReviewAuditEvent> auditHistory;
  final List<QjQuestion> qjQuestions;
  final String currentStatus;
  final Future<void> Function(String candidateId, String newDisposition)?
      onDispositionChanged;
  final String questionnairePreviewHref;

  const ReviewPortalPage({
    super.key,
    required this.assessmentTitle,
    required this.assessmentId,
    required this.batchId,
    required this.findings,
    required this.descriptionSections,
    required this.candidates,
    this.auditHistory = const [],
    this.qjQuestions = const [],
    this.currentStatus = 'Pending review',
    this.onDispositionChanged,
    this.questionnairePreviewHref = '/entrepreneur/assessments/customer-preview',
  });

  @override
  State<ReviewPortalPage> createState() => _ReviewPortalPageState();
}

class _ReviewPortalPageState extends State<ReviewPortalPage> {
  final Set<int> _expandedDescriptionSections = <int>{0};
  final Map<String, String> _localDispositions = <String, String>{};
  final List<ReviewAuditEvent> _localEvents = <ReviewAuditEvent>[];
  String _filter = 'all';
  String _search = '';
  String _tab = 'details';
  String _kind = 'bdj';
  final Set<String> _collapsed = <String>{};
  String? _selectedCandidateId;
  String? _error;
  bool _saving = false;

  QjQuestion? _qjById(String id) {
    final matches = component.qjQuestions.where((q) => q.id == id);
    return matches.isEmpty ? null : matches.first;
  }

  BdjReviewFinding? _bdjById(String id) {
    final matches = component.findings.where((f) => f.id == id);
    return matches.isEmpty ? null : matches.first;
  }

  QgReviewCandidate? _qgById(String id) {
    final matches = component.candidates.where((c) => c.id == id);
    return matches.isEmpty ? null : matches.first;
  }

  String _selectedId() {
    if (_selectedCandidateId != null) return _selectedCandidateId!;
    if (_kind == 'qj' && component.qjQuestions.isNotEmpty) {
      return component.qjQuestions.first.id;
    }
    if (_kind == 'qg' && component.candidates.isNotEmpty) {
      return component.candidates.first.id;
    }
    return component.findings.isEmpty ? '' : component.findings.first.id;
  }

  bool _matches(String id, String title) {
    if (_search.trim().isEmpty) return true;
    final needle = _search.trim().toLowerCase();
    return id.toLowerCase().contains(needle) ||
        title.toLowerCase().contains(needle);
  }

  String _disposition(QgReviewCandidate candidate) =>
      _localDispositions[candidate.id] ?? candidate.candidate.ownerDisposition;

  String _statusLabel(String raw) => switch (raw) {
        QgOwnerDisposition.accepted => 'Accepted for review',
        QgOwnerDisposition.rejected => 'Rejected',
        _ => 'Pending review',
      };

  String _statusClass(String raw) => switch (raw) {
        QgOwnerDisposition.accepted => 'pill green',
        QgOwnerDisposition.rejected => 'pill gray',
        _ => 'pill pending',
      };

  Future<void> _decide(String candidateId, String status) async {
    if (_saving) return;
    final match = component.candidates.where((c) => c.id == candidateId);
    if (match.isEmpty) return;
    if (_disposition(match.first) == status) return;

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final callback = component.onDispositionChanged;
      if (callback != null) {
        // A rejected/failed backend write must NOT change the visible state.
        await callback(candidateId, status);
      }
      if (!mounted) return;
      setState(() {
        _localDispositions[candidateId] = status;
        _localEvents.add(
          ReviewAuditEvent(
            candidateId: candidateId,
            title: status == QgOwnerDisposition.accepted
                ? 'Candidate accepted for scientific review'
                : 'Candidate rejected by owner',
            note: callback == null
                ? 'Temporary local UI demo only; no backend audit was written.'
                : 'Backend callback completed; reload authoritative audit for confirmation.',
            actor: callback == null ? 'Local demo user' : 'Owner decision callback',
            at: DateTime.now().toUtc(),
          ),
        );
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = 'Decision not saved: $error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Component build(BuildContext context) {
    final id = _selectedId();
    return div(classes: 'rp-page', [
      div(classes: 'crumb', [
        a(href: '/entrepreneur/assessments', [Component.text('Project1')]),
        Component.text('  ›  Review Portal'),
      ]),
      h1(classes: 'rp-title', [Component.text('BDJ, QJ & QG Review Portal')]),
      p(classes: 'rp-sub', [
        Component.text(
          'Review generated questions, business understanding and attribute interpretations.',
        ),
      ]),
      _summaryCard(),
      _kpiStrip(),
      if (_totalItems == 0)
        section(classes: 'rp-card rp-empty-state', [
          span(classes: 'material-symbols-rounded', [
            Component.text('search_off'),
          ]),
          h2([Component.text('No review records found')]),
          p([
            Component.text(
              'No BDJ findings, QJ questions or QG candidates were supplied '
              'for this assessment. Nothing is displayed rather than an '
              'invented item.',
            ),
          ]),
        ])
      else
        div(classes: 'rp-grid', [
          _rail(),
          _detailCard(id),
          _aside(id),
        ]),
      if (_error != null)
        div(classes: 'warning', [Component.text(_error!)]),
      p(classes: 'footer-note', [
        Component.text(
          component.onDispositionChanged == null
              ? 'Local demonstration only: decisions and log changes are temporary and are not saved to a backend.'
              : 'Owner decisions require authenticated backend enforcement, version checks and an authoritative audit history.',
        ),
      ]),
    ]);
  }

  int get _totalItems =>
      component.findings.length +
      component.qjQuestions.length +
      component.candidates.length;

  int get _reviewedItems {
    var reviewed = 0;
    for (final question in component.qjQuestions) {
      if (question.status.toLowerCase() == 'reviewed') reviewed += 1;
    }
    for (final candidate in component.candidates) {
      if (_disposition(candidate) != QgOwnerDisposition.pending) reviewed += 1;
    }
    return reviewed;
  }

  Component _summaryCard() => section(classes: 'rp-card rp-summary', [
        div(classes: 'rp-summary__main', [
          span(classes: 'rp-ico blue', [
            span(classes: 'material-symbols-rounded', [
              Component.text('description'),
            ]),
          ]),
          div([
            h2([
              Component.text(
                '${component.assessmentTitle} — ${component.assessmentId}',
              ),
            ]),
            p(classes: 'small muted', [
              Component.text('Location assessment · Candidate review'),
            ]),
          ]),
        ]),
        div(classes: 'rp-summary__cell', [
          span(classes: 'mini-label', [Component.text('Candidate batch')]),
          p([Component.text(component.batchId)]),
        ]),
        div(classes: 'rp-summary__cell', [
          span(classes: 'mini-label', [Component.text('Review stage')]),
          span(classes: 'pill blue', [Component.text('Review candidates')]),
        ]),
        div(classes: 'rp-summary__cell', [
          span(classes: 'mini-label', [Component.text('Current status')]),
          span(classes: 'pill pending', [
            span(classes: 'material-symbols-rounded pill__ico', [
              Component.text('schedule'),
            ]),
            Component.text(component.currentStatus),
          ]),
        ]),
      ]);

  Component _kpiStrip() {
    final percent = _totalItems == 0
        ? 0
        : ((_reviewedItems / _totalItems) * 100).round();
    Component tile(String icon, String value, String label, String note,
            {String accent = 'blue'}) =>
        div(classes: 'rp-kpi', [
          span(classes: 'rp-ico $accent', [
            span(classes: 'material-symbols-rounded', [Component.text(icon)]),
          ]),
          div(classes: 'rp-kpi__body', [
            div(classes: 'rp-kpi__row', [
              span(classes: 'rp-kpi__label', [Component.text(label)]),
              span(classes: 'rp-kpi__value', [Component.text(value)]),
            ]),
            p(classes: 'rp-kpi__note', [Component.text(note)]),
          ]),
        ]);
    return div(classes: 'rp-kpis', [
      tile('layers', '${component.findings.length}', 'BDJ Findings',
          'Business attribute interpretations'),
      tile('forum', '${component.qjQuestions.length}', 'QJ Questions',
          'Research questions (from bank)'),
      tile('auto_awesome', '${component.candidates.length}', 'QG Candidates',
          'AI-generated question proposals'),
      div(classes: 'rp-kpi', [
        span(classes: 'rp-ico blue', [
          span(classes: 'material-symbols-rounded', [
            Component.text('task_alt'),
          ]),
        ]),
        div(classes: 'rp-kpi__body', [
          div(classes: 'rp-kpi__row', [
            span(classes: 'rp-kpi__label', [Component.text('Review Progress')]),
            span(classes: 'rp-kpi__value', [
              Component.text('$_reviewedItems / $_totalItems ($percent%)'),
            ]),
          ]),
          p(classes: 'rp-kpi__note', [Component.text('items reviewed (all types)')]),
          div(classes: 'rp-bar', [
            div(
              classes: 'rp-bar__fill',
              attributes: {'style': 'width:$percent%'},
              const [],
            ),
          ]),
        ]),
      ]),
    ]);
  }

  // ------------------------------------------------------------- left rail

  Component _chip(String key, String label, int count) => button(
        classes: 'rp-chip ${_filter == key ? 'is-active' : ''}',
        attributes: {'type': 'button'},
        events: events(onClick: () => setState(() {
          _filter = key;
          if (key != 'all') _kind = key;
        })),
        [Component.text('$label ($count)')],
      );

  Component _groupHead(String key, String title, int count, String icon) => button(
        classes: 'rp-group__head',
        attributes: {
          'type': 'button',
          'aria-expanded': _collapsed.contains(key) ? 'false' : 'true',
        },
        events: events(onClick: () => setState(() {
          if (!_collapsed.add(key)) _collapsed.remove(key);
        })),
        [
          span(classes: 'material-symbols-rounded rp-group__ico', [
            Component.text(icon),
          ]),
          strong([Component.text('$title ($count)')]),
          span(classes: 'material-symbols-rounded rp-group__chev', [
            Component.text(_collapsed.contains(key) ? 'expand_more' : 'expand_less'),
          ]),
        ],
      );

  Component _row({
    required String kind,
    required String id,
    required String title,
    String tag = '',
    String pillText = '',
    String pillClass = 'pill gray',
    String meta = '',
  }) {
    final selected = _selectedId() == id && _kind == kind;
    return button(
      classes: 'rp-row ${selected ? 'is-active' : ''}',
      attributes: {
        'type': 'button',
        'aria-pressed': selected ? 'true' : 'false',
      },
      events: events(onClick: () => setState(() {
        _kind = kind;
        _selectedCandidateId = id;
        _tab = 'details';
      })),
      [
        div(classes: 'rp-row__main', [
          span(classes: 'rp-row__id', [Component.text(id)]),
          span(classes: 'rp-row__title', [Component.text(title)]),
          if (meta.isNotEmpty)
            span(classes: 'rp-row__meta', [Component.text(meta)]),
        ]),
        span(classes: 'rp-row__end', [
          if (tag.isNotEmpty)
            span(classes: 'rp-tag', [Component.text(tag)]),
          if (pillText.isNotEmpty)
            span(classes: pillClass, [Component.text(pillText)]),
        ]),
      ],
    );
  }

  Component _rail() {
    final bdj = [
      for (final f in component.findings)
        if (_matches(f.id, f.title)) f,
    ];
    final qj = [
      for (final q in component.qjQuestions)
        if (_matches(q.id, q.shortTitle)) q,
    ];
    final qg = [
      for (final c in component.candidates)
        if (_matches(c.id, c.candidate.item.shortTitle)) c,
    ];

    return section(classes: 'rp-card rp-rail', [
      div(classes: 'rp-chips', [
        _chip('all', 'All items', _totalItems),
        _chip('bdj', 'BDJ', component.findings.length),
        _chip('qj', 'QJ', component.qjQuestions.length),
        _chip('qg', 'QG', component.candidates.length),
      ]),
      div(classes: 'rp-search', [
        span(classes: 'material-symbols-rounded', [
          Component.text('search'),
        ]),
        input(
          type: InputType.text,
          classes: 'rp-search__input',
          attributes: {
            'placeholder': 'Search by keyword, ID or construct…',
            'aria-label': 'Search review items',
          },
          events: events<String>(
            onInput: (value) => setState(() => _search = value),
          ),
        ),
        span(classes: 'material-symbols-rounded rp-search__filter', [
          Component.text('filter_list'),
        ]),
      ]),
      if (_filter == 'all' || _filter == 'bdj') ...[
        _groupHead('bdj', 'BDJ – Business Attribute Findings',
            component.findings.length, 'layers'),
        if (!_collapsed.contains('bdj'))
          for (final finding in bdj)
            _row(
              kind: 'bdj',
              id: finding.id,
              title: finding.title,
              meta: finding.sourceRefs,
              pillText: finding.currentStatus.isEmpty
                  ? finding.verificationStatus
                  : finding.currentStatus,
            ),
        if (bdj.isEmpty)
          p(classes: 'rp-empty', [Component.text('No BDJ findings match.')]),
      ],
      if (_filter == 'all' || _filter == 'qj') ...[
        div(classes: 'rp-group__sep', []),
        _groupHead('qj', 'QJ – Research Questions',
            component.qjQuestions.length, 'forum'),
        if (!_collapsed.contains('qj'))
          for (final question in qj)
            _row(
              kind: 'qj',
              id: question.id,
              title: question.shortTitle,
              tag: question.construct,
              pillText: question.status == 'Reviewed' ? 'Reviewed' : 'Pending',
              pillClass: question.status == 'Reviewed'
                  ? 'pill green'
                  : 'pill pending',
            ),
        if (qj.isEmpty)
          p(classes: 'rp-empty', [Component.text('No QJ questions match.')]),
      ],
      if (_filter == 'all' || _filter == 'qg') ...[
        div(classes: 'rp-group__sep', []),
        _groupHead('qg', 'QG – Generated Question Candidates',
            component.candidates.length, 'auto_awesome'),
        if (!_collapsed.contains('qg'))
          for (final candidate in qg)
            _row(
              kind: 'qg',
              id: candidate.id,
              title: candidate.candidate.item.shortTitle,
              tag: candidate.candidate.item.construct,
              pillText: _statusLabel(_disposition(candidate)),
              pillClass: _statusClass(_disposition(candidate)),
            ),
        if (qg.isEmpty)
          p(classes: 'rp-empty', [Component.text('No QG candidates match.')]),
      ],
      if (_filter == 'all' && component.candidates.isNotEmpty)
        button(
          classes: 'rp-rail__more',
          attributes: {'type': 'button'},
          events: events(onClick: () => setState(() => _filter = 'qg')),
          [
            Component.text(
              'View all ${component.candidates.length} QG candidates',
            ),
            span(classes: 'material-symbols-rounded', [
              Component.text('chevron_right'),
            ]),
          ],
        ),
    ]);
  }

  // --------------------------------------------------------- centre column

  Component _tabButton(String key, String label) => button(
        classes: 'rp-tab ${_tab == key ? 'is-active' : ''}',
        attributes: {'type': 'button'},
        events: events(onClick: () => setState(() => _tab = key)),
        [Component.text(label)],
      );

  Component _drow(String icon, String label, String value) => div(
        classes: 'rp-drow',
        [
          span(classes: 'rp-drow__ico', [
            span(classes: 'material-symbols-rounded', [
              Component.text(icon),
            ]),
          ]),
          span(classes: 'rp-drow__label', [Component.text(label)]),
          span(classes: 'rp-drow__value', [Component.text(value)]),
        ],
      );

  List<Component> _detailRows(String id) {
    final finding = _bdjById(id);
    final question = _qjById(id);
    final candidate = _qgById(id);

    if (_tab == 'related') {
      final related = finding?.relatedM2 ?? '';
      return [
        _drow('link', 'Related questions',
            finding?.relatedQuestions.toString() ?? '0'),
        _drow('dataset', 'Related M2 items',
            related.isEmpty ? 'Not supplied' : related),
      ];
    }
    if (_tab == 'evidence') {
      return [
        _drow('menu_book', 'Source references',
            finding?.sourceRefs ?? 'Not supplied'),
        _drow('fact_check', 'Evidence items',
            (finding?.evidenceCount ?? 0).toString()),
      ];
    }
    if (_tab == 'notes') {
      return [
        _drow('sticky_note_2', 'Notes',
            (finding?.notesCount ?? 0) == 0
                ? 'No notes recorded for this item.'
                : '${finding!.notesCount} notes recorded.'),
      ];
    }
    if (finding != null) {
      return [
        _drow('description', 'Finding (Interpretation)', finding.declaredAnswer),
        _drow('query_stats', 'Explanation (Rationale)', finding.explanation),
        _drow(
          'checklist',
          'Measurement Requirements',
          finding.measurementRequirements.isEmpty
              ? 'Not supplied'
              : finding.measurementRequirements.join('\n'),
        ),
        _drow('menu_book', 'Source References', finding.sourceRefs),
        _drow(
          'warning',
          'Limitations / Uncertainty',
          finding.limitations.isEmpty
              ? 'Not supplied'
              : finding.limitations,
        ),
        _drow('flag', 'Recommended Action', finding.recommendedAction),
      ];
    }
    if (question != null) {
      return [
        _drow('help', 'Research question', question.shortTitle),
        _drow('category', 'Construct', question.construct),
        _drow('verified', 'Review status', question.status),
        _drow('menu_book', 'Source', 'Existing Q01–Q13 bank item'),
      ];
    }
    if (candidate != null) {
      return [
        _drow('help', 'Entrepreneur research question',
            candidate.researchQuestion),
        _drow('category', 'Construct', candidate.candidate.item.construct),
        _drow('groups', 'Respondents', candidate.respondentDefinition),
        _drow('campaign', 'Stimulus', candidate.stimulusRequirement),
        _drow('rule', 'Inference', candidate.inferenceLimit),
        _drow('fact_check', 'Question bank check',
            candidate.candidate.bankEquivalenceStatus),
        _drow('info', 'Methodological note', candidate.methodologicalNote),
      ];
    }
    return [
      const p(classes: 'rp-empty', [
        Component.text('Select an item from the list to review it.'),
      ]),
    ];
  }

  Component _detailCard(String id) {
    final finding = _bdjById(id);
    final question = _qjById(id);
    final candidate = _qgById(id);
    final title = finding?.title ??
        question?.shortTitle ??
        candidate?.candidate.item.shortTitle ??
        'No item selected';
    final kindLabel = finding != null
        ? 'BDJ Finding'
        : question != null
            ? 'QJ Question'
            : 'QG Candidate';
    final statusText = candidate != null
        ? _statusLabel(_disposition(candidate))
        : finding != null
            ? (finding.currentStatus.isEmpty
                ? finding.verificationStatus
                : finding.currentStatus)
            : (question?.status ?? '');
    final disposition = candidate == null ? '' : _disposition(candidate);
    final canDecide = candidate != null && !_saving;

    return section(classes: 'rp-card rp-detail', [
      div(classes: 'rp-detail__head', [
        div([
          div(classes: 'rp-detail__eyebrow', [
            span(classes: 'pill blue', [Component.text(kindLabel)]),
            span(classes: 'rp-detail__id', [Component.text(id)]),
          ]),
          h2([Component.text(title)]),
        ]),
        if (statusText.isNotEmpty)
          span(classes: 'pill gray', [Component.text(statusText)]),
      ]),
      div(classes: 'rp-tabs', [
        _tabButton('details', 'Review Details'),
        _tabButton('related',
            'Related Questions (${finding?.relatedQuestions ?? 0})'),
        _tabButton('evidence',
            'Evidence & Sources (${finding?.evidenceCount ?? 0})'),
        _tabButton('notes', 'Notes (${finding?.notesCount ?? 0})'),
      ]),
      div(classes: 'rp-detail__body', _detailRows(id)),
      div(classes: 'rp-actions', [
        button(
          classes: 'rp-btn rp-btn--approve',
          attributes: {
            'type': 'button',
            if (!canDecide || disposition == QgOwnerDisposition.accepted)
              'disabled': '',
          },
          events: events(onClick: () {
            if (candidate != null) {
              _decide(candidate.id, QgOwnerDisposition.accepted);
            }
          }),
          [
            span(classes: 'material-symbols-rounded', [
              Component.text('check'),
            ]),
            Component.text(
              _saving ? 'Saving…' : 'Approve',
            ),
          ],
        ),
        button(
          classes: 'rp-btn rp-btn--reject',
          attributes: {
            'type': 'button',
            if (!canDecide || disposition == QgOwnerDisposition.rejected)
              'disabled': '',
          },
          events: events(onClick: () {
            if (candidate != null) {
              _decide(candidate.id, QgOwnerDisposition.rejected);
            }
          }),
          [
            span(classes: 'material-symbols-rounded', [
              Component.text('close'),
            ]),
            Component.text('Reject'),
          ],
        ),
        button(
          classes: 'rp-btn rp-btn--ghost',
          attributes: {'type': 'button'},
          events: events(onClick: () {
            setState(() {
              _localEvents.add(
                ReviewAuditEvent(
                  candidateId: id,
                  title: 'Note added',
                  note: 'Local demonstration note; nothing was saved.',
                  actor: 'Local demo user',
                  at: DateTime.now().toUtc(),
                ),
              );
            });
          }),
          [
            span(classes: 'material-symbols-rounded', [
              Component.text('chat'),
            ]),
            Component.text('Add note'),
          ],
        ),
        if (candidate == null)
          span(classes: 'rp-actions__note', [
            Component.text('Owner decision applies to QG candidates only.'),
          ]),
      ]),
    ]);
  }

  String _fmt(DateTime at) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final local = at.toLocal();
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    return '${local.day} ${months[local.month - 1]} ${local.year}, '
        '$hour:$minute';
  }

  Component _infoRow(String label, String value) => div(
        classes: 'rp-info__row',
        [
          span(classes: 'rp-info__label', [Component.text(label)]),
          span(classes: 'rp-info__value', [Component.text(value)]),
        ],
      );

  Component _aside(String id) {
    final finding = _bdjById(id);
    final question = _qjById(id);
    final candidate = _qgById(id);
    final timeline = <ReviewAuditEvent>[
      for (final event in component.auditHistory)
        if (event.candidateId == id) event,
      for (final event in _localEvents)
        if (event.candidateId == id) event,
    ]..sort((x, y) => x.at.compareTo(y.at));

    final itemType = finding != null
        ? 'BDJ Finding'
        : question != null
            ? 'QJ Question'
            : 'QG Candidate';
    final currentStatus = candidate != null
        ? _statusLabel(_disposition(candidate))
        : finding != null
            ? (finding.currentStatus.isEmpty
                ? finding.verificationStatus
                : finding.currentStatus)
            : (question?.status ?? 'Not supplied');
    final updatedAt = finding?.updatedAt ?? '';
    final updatedBy = finding?.updatedBy ?? 'System';
    final version = finding?.reviewVersion ?? 'v1.0';
    final relatedM2 = finding?.relatedM2 ?? '';

    return div(classes: 'rp-aside', [
      section(classes: 'rp-card rp-panel', [
        div(classes: 'rp-panel__head', [
          span(classes: 'material-symbols-rounded', [
            Component.text('history'),
          ]),
          h3([Component.text('Review History')]),
        ]),
        div(classes: 'rp-panel__body', [
          if (timeline.isEmpty)
            p(classes: 'rp-empty', [
              Component.text('No authoritative review events were supplied.'),
            ])
          else
            for (final event in timeline)
              div(classes: 'rp-event', [
                span(classes: 'rp-event__dot', []),
                div([
                  strong([Component.text(event.title)]),
                  p(classes: 'rp-event__when', [
                    Component.text(
                      '${_fmt(event.at)} · ${event.actor}',
                    ),
                  ]),
                  p(classes: 'rp-event__note', [
                    Component.text(event.note),
                  ]),
                ]),
              ]),
        ]),
      ]),
      section(classes: 'rp-card rp-panel', [
        div(classes: 'rp-panel__head', [
          span(classes: 'material-symbols-rounded', [
            Component.text('info'),
          ]),
          h3([Component.text('Item Information')]),
        ]),
        div(classes: 'rp-panel__body', [
          _infoRow('Item type', itemType),
          _infoRow('Item ID', id.isEmpty ? '—' : id),
          if (relatedM2.isNotEmpty) _infoRow('Related M2', relatedM2),
          _infoRow('Current status', currentStatus),
          if (updatedAt.isNotEmpty) _infoRow('Last updated', updatedAt),
          _infoRow('Updated by', updatedBy),
          _infoRow('Review version', version),
        ]),
      ]),
      if (component.descriptionSections.isNotEmpty)
        section(classes: 'rp-card rp-panel', [
          div(classes: 'rp-panel__head', [
            span(classes: 'material-symbols-rounded', [
              Component.text('notes'),
            ]),
            h3([Component.text('Business Description')]),
          ]),
          div(classes: 'rp-panel__body', [
            for (final (index, item) in component.descriptionSections.indexed)
              div(classes: 'rp-desc', [
                button(
                  classes: 'rp-desc__head',
                  attributes: {
                    'type': 'button',
                    'aria-expanded':
                        _expandedDescriptionSections.contains(index)
                            ? 'true'
                            : 'false',
                  },
                  events: events(onClick: () => setState(() {
                    if (!_expandedDescriptionSections.add(index)) {
                      _expandedDescriptionSections.remove(index);
                    }
                  })),
                  [strong([Component.text(item.title)])],
                ),
                if (_expandedDescriptionSections.contains(index))
                  for (final paragraph in item.paragraphs)
                    p(classes: 'rp-desc__text', [
                      Component.text(paragraph),
                    ]),
              ]),
          ]),
        ]),
      a(
        href: component.questionnairePreviewHref,
        classes: 'rp-link',
        [
          Component.text('Customer questionnaire preview'),
          span(classes: 'material-symbols-rounded', [
            Component.text('arrow_forward'),
          ]),
        ],
      ),
    ]);
  }
}
