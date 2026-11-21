import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import 'package:sitewise_jaspr_web/shared/presentation/components/ui.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/assessment_api.dart';
import 'package:sitewise_jaspr_web/data/assessment_report.dart';
import 'package:sitewise_jaspr_web/features/recommendations/data/full_analysis_actions.dart';

/// Step 5 — the assembled assessment report, laid out as the supplied
/// `SiteWise_Final_Report.html` document: a numbered section index, a sticky
/// jump bar, KPI strip, then one card per section.
///
/// **Nothing here is invented.** Every figure comes from the report payload
/// (`GET /api/v1/assessments/{id}/report`), from the persisted assessment
/// record, or from the decisions the entrepreneur made in Step 4. Where the
/// payload marks a section unavailable, the section renders the server's own
/// reason instead of a placeholder number — which is exactly what the source
/// document's "no admitted results" states are for.
///
/// The Step-4 decisions are **session-only** (no endpoint persists them yet),
/// so the decision register is labelled as such rather than presented as a
/// stored history.
final class AssessmentReportView extends StatelessComponent {
  final AssessmentReportPayload report;
  final AssessmentRecord record;

  /// The question register derived in Step 4, reused here so the report and
  /// the review step can never disagree about which questions exist.
  final List<({String id, String question, String group})> register;

  /// `id → 'approve' | 'reject'`, from this session only.
  final Map<String, String> decisions;

  /// Label/value pairs for the declared business (Step 2 answers, formatted).
  final List<(String, String)> scope;

  /// The research objective shown in Step 4.
  final String objective;

  /// Questions the entrepreneur added themselves in Step 4.
  final List<String> extraQuestions;

  /// Where Back goes. The report is reached from the entry page and from the
  /// step-5 checkpoint, so the caller names the destination rather than the
  /// document assuming one.
  final String backLabel;
  final VoidCallback onBack;

  const AssessmentReportView({
    super.key,
    required this.report,
    required this.record,
    required this.register,
    required this.decisions,
    required this.scope,
    required this.objective,
    required this.extraQuestions,
    this.backLabel = 'Back',
    required this.onBack,
  });

  /// Section id, index, title, one-line purpose. The nav and the sections read
  /// the same list, so a section can never exist without a jump target.
  static const List<(String, String, String, String)> _sections = [
    (
      'asw-rpt-overview',
      '01',
      'Assessment overview',
      'What this report covers and what it can safely conclude.',
    ),
    (
      'asw-rpt-business',
      '02',
      'Business description',
      'The business you declared in Step 2, at the version the report used.',
    ),
    (
      'asw-rpt-findings',
      '03',
      'Business findings and uncertainties',
      'Finding decisions recorded for this assessment.',
    ),
    (
      'asw-rpt-decisions',
      '04',
      'Research and question decisions',
      'The research objective and every question decision in this session.',
    ),
    (
      'asw-rpt-questionnaire',
      '05',
      'Customer questionnaire',
      'Fielded customer responses admitted to this report.',
    ),
    (
      'asw-rpt-extras',
      '06',
      'Additional questions',
      'Questions you added yourself during question review.',
    ),
    (
      'asw-rpt-evidence',
      '07',
      'Evidence and scoring',
      'Measured location evidence, the requirement checks and the model output.',
    ),
    (
      'asw-rpt-coverage',
      '08',
      'Report coverage',
      'Which report sections the backend could actually fill for this record.',
    ),
    (
      'asw-rpt-sources',
      '09',
      'Sources and limitations',
      'Where each section came from, and what is still missing.',
    ),
  ];

  @override
  Component build(BuildContext context) {
    return div(classes: 'asw-rpt', [
      _toolbar(),
      _jumpBar(),
      for (final (id, index, title, purpose) in _sections)
        _section(id, index, title, purpose, _bodyFor(id)),
      _actions(),
    ]);
  }

  // ------------------------------------------------------------------ chrome

  Component _toolbar() {
    final generated = _date(report.generatedAt);
    return div(classes: 'asw-rpt__bar', [
      div(classes: 'asw-rpt__barleft', [
        span(classes: 'asw-rpt__stamp', [
          Component.text('Report assembled $generated'),
        ]),
        Pill(
          record.isCompleted ? 'Assessment complete' : 'Assessment in progress',
          tone: record.isCompleted ? 'success' : 'warning',
        ),
        Pill(
          report.requirementsVersion > 0
              ? 'Preferences v${report.requirementsVersion}'
              : 'No preferences saved',
          tone: 'neutral',
        ),
      ]),
      div(classes: 'asw-rpt__barright', [
        ActionButton(
          'Print / Save PDF',
          variant: 'secondary',
          icon: 'print',
          onClick: printPage,
        ),
      ]),
    ]);
  }

  /// Sticky jump bar. Each chip scrolls to its section; the sections are all on
  /// this page, so the navigation never leaves the assessment.
  Component _jumpBar() => nav(
    classes: 'asw-rpt__nav',
    attributes: const {'aria-label': 'Jump to a report section'},
    [
      for (final section in _sections)
        button(
          classes: 'asw-rpt__navlink',
          attributes: {'type': 'button'},
          events: events(onClick: () => scrollToId(section.$1)),
          [Component.text(section.$3)],
        ),
    ],
  );

  Component _section(
    String id,
    String index,
    String title,
    String purpose,
    List<Component> body,
  ) => section(classes: 'asw-rpt__section', attributes: {'id': id}, [
    div(classes: 'asw-rpt__sechead', [
      span(classes: 'asw-rpt__secindex', [Component.text(index)]),
      div(classes: 'asw-rpt__seccopy', [
        h2(classes: 'asw-rpt__sectitle', [Component.text(title)]),
        p(classes: 'asw-rpt__secdesc', [Component.text(purpose)]),
      ]),
    ]),
    ...body,
  ]);

  /// The document's only navigation: back to whatever opened it. Stage
  /// completion deliberately does not live here — the report is a read-only
  /// destination, and the checkpoint owns that decision.
  Component _actions() => div(classes: 'asw-rpt__actions', [
    ActionButton(
      backLabel,
      variant: 'secondary',
      icon: 'arrow_back',
      onClick: onBack,
    ),
    div(classes: 'asw-rpt__actionright', [
      span(classes: 'asw-rpt__footnote', [
        Component.text(
          'Printing uses the browser dialog, so the PDF matches this page.',
        ),
      ]),
    ]),
  ]);

  // ----------------------------------------------------------------- bodies

  List<Component> _bodyFor(String id) => switch (id) {
    'asw-rpt-overview' => _overview(),
    'asw-rpt-business' => _business(),
    'asw-rpt-findings' => _findings(),
    'asw-rpt-decisions' => _decisions(),
    'asw-rpt-questionnaire' => _questionnaire(),
    'asw-rpt-extras' => _extras(),
    'asw-rpt-evidence' => _evidence(),
    'asw-rpt-coverage' => _coverage(),
    _ => _sources(),
  };

  List<Component> _overview() {
    final groups = report.evidenceGroups;
    final measuredGroups = groups
        .where((group) => AssessmentReportPayload.measuredMetrics(group) > 0)
        .length;
    final checks = report.requirementMatching;
    final preferenceCount = report.questionnaire.asMap?.length ?? 0;

    return [
      div(classes: 'asw-rpt__kpis', [
        _kpi(
          icon: 'fact_check',
          label: 'Saved preference answers',
          value: preferenceCount == 0 ? '—' : '$preferenceCount',
          foot: preferenceCount == 0
              ? 'Step 2 has no saved answers for this assessment.'
              : 'Declared in Step 2 · preferences v${report.requirementsVersion}',
        ),
        _kpi(
          icon: 'travel_explore',
          label: 'Evidence groups with data',
          value: groups.isEmpty ? '—' : '$measuredGroups / ${groups.length}',
          foot: groups.isEmpty
              ? 'No location analysis is stored for this property.'
              : 'Catchment, access and competitor metrics.',
          tone: 'teal',
        ),
        _kpi(
          icon: 'rule',
          label: 'Requirement checks supported',
          value: checks.total == 0 ? '—' : '${checks.matched} / ${checks.total}',
          foot: checks.total == 0
              ? 'Nothing could be checked from the stored data.'
              : '${checks.mismatched} not met · ${checks.unknown} not verified',
        ),
        _kpi(
          icon: 'shield',
          label: 'Overall suitability score',
          value: 'Not established',
          foot: 'No approved composite scoring contract exists.',
          tone: 'gray',
        ),
      ]),
      _card(
        icon: 'menu_book',
        title: 'How to read this report',
        trailing: Pill('Decision support', tone: 'neutral'),
        children: [
          _legend('Supported', 'success', 'A stored value satisfies the rule.'),
          _legend(
            'Not met',
            'danger',
            'A stored value fails the rule — worth reconsidering.',
          ),
          _legend(
            'Not verified',
            'warning',
            'The data needed to judge this was not measured.',
          ),
          p(classes: 'asw-rpt__note', [
            strong([Component.text('Interpretation rule: ')]),
            Component.text(
              'stated interest is not purchasing behaviour, and a location '
              'match is not a forecast. Every figure here traces to a stored '
              'record you can inspect in Steps 2–4.',
            ),
          ]),
        ],
      ),
    ];
  }

  List<Component> _business() {
    if (scope.isEmpty) {
      return [
        _empty(
          title: 'No business description is stored',
          body:
              report.questionnaire.reason ??
              'Step 2 has not saved any business preferences for this '
                  'assessment, so there is nothing to describe.',
        ),
      ];
    }
    final property = record.property;
    return [
      _card(
        icon: 'storefront',
        title: 'Declared business',
        trailing: Pill('From Step 2', tone: 'neutral'),
        children: [
          dl(classes: 'asw-rpt__defs', [
            for (final (label, value) in scope)
              div(classes: 'asw-rpt__def', [
                dt([Component.text(label)]),
                dd([Component.text(value)]),
              ]),
          ]),
          p(classes: 'asw-rpt__note', [
            strong([Component.text('Version: ')]),
            Component.text(
              'preferences v${report.requirementsVersion}. The report reads the '
              'saved answers only; changing them in Step 2 changes this '
              'section on the next read.',
            ),
          ]),
        ],
      ),
      if (property != null)
        _card(
          icon: 'home_work',
          title: 'Bound property',
          trailing: Pill('Catalogue record', tone: 'neutral'),
          children: [
            dl(classes: 'asw-rpt__defs', [
              _def('Listing', property.title),
              _def('Address', '${property.address}, ${property.city}'),
              _def('Property type', property.propertyType),
              _def('Monthly rent', property.rentalDisplay),
              _def(
                'Floor area',
                '${property.sizeSqft.toStringAsFixed(0)} sq ft',
              ),
              _def('Verification', property.verification.label),
            ]),
          ],
        ),
    ];
  }

  List<Component> _findings() => [
    _empty(
      title: 'No business-findings evaluation is stored',
      body:
          'Business findings and their decisions come from the upstream M2 '
          'business-declaration stage. That stage is not enabled for this '
          'assessment, so no finding was evaluated — and this report does not '
          'assert one.',
      foot:
          'Once the stage is enabled, each finding keeps its own outcome '
          '(confirmed, declined, unresolved, superseded) here.',
    ),
  ];

  List<Component> _decisions() {
    final approved = decisions.values.where((v) => v == 'approve').length;
    final rejected = decisions.values.where((v) => v == 'reject').length;
    final pending = register.length - approved - rejected;

    return [
      _card(
        icon: 'track_changes',
        title: 'Research objective',
        trailing: Pill('From Step 4', tone: 'neutral'),
        children: [
          p(classes: 'asw-rpt__body', [
            Component.text(
              objective.isEmpty
                  ? 'No research objective could be derived — save your '
                        'business preferences in Step 2 first.'
                  : objective,
            ),
          ]),
        ],
      ),
      _card(
        icon: 'checklist',
        title: 'Question decision register',
        trailing: Pill(
          '$approved approved · $rejected rejected · $pending undecided',
          tone: pending == 0 ? 'success' : 'warning',
        ),
        children: [
          if (register.isEmpty)
            _emptyInline(
              'No question candidates exist yet. Step 4 derives them from your '
              'saved preferences.',
            )
          else
            div(classes: 'table-scroll', [
              table(classes: 'asw-rpt__table', [
                thead([
                  tr([
                    th([Component.text('Candidate')]),
                    th([Component.text('Proposed question')]),
                    th([Component.text('Decision')]),
                  ]),
                ]),
                tbody([
                  for (final row in register)
                    tr([
                      td([
                        span(classes: 'asw-rpt__id', [
                          Component.text(row.id),
                        ]),
                      ]),
                      td([Component.text(row.question)]),
                      td([
                        StatusBadge(
                          switch (decisions[row.id]) {
                            'approve' => 'Approved (session)',
                            'reject' => 'Rejected (session)',
                            _ => 'Undecided',
                          },
                          tone: switch (decisions[row.id]) {
                            'approve' => 'success',
                            'reject' => 'danger',
                            _ => 'neutral',
                          },
                        ),
                      ]),
                    ]),
                ]),
              ]),
            ]),
          p(classes: 'asw-rpt__note', [
            strong([Component.text('Session only: ')]),
            Component.text(
              'these decisions are held in this browser session. No endpoint '
              'persists them yet, so the report shows them as session '
              'decisions rather than a stored history.',
            ),
          ]),
        ],
      ),
    ];
  }

  List<Component> _questionnaire() {
    final respondents = record.respondentCount;
    final responses = record.responseCount;
    return [
      _empty(
        title: 'No fielded customer questionnaire results',
        body:
            'This report admits customer answers only from a released '
            'questionnaire with recorded response state. None is attached to '
            'this assessment, so no response counts, percentages or charts are '
            'shown — an empty chart would be a fabricated one.',
        foot: respondents == null && responses == null
            ? 'The backend does not report participation for this assessment.'
            : 'Participation on record: '
                  '${respondents ?? 0} registered respondent(s), '
                  '${responses ?? 0} submitted response(s).',
      ),
    ];
  }

  List<Component> _extras() {
    if (extraQuestions.isEmpty) {
      return [
        _empty(
          title: 'No additional questions were added',
          body:
              'Questions you add during question review appear here. Adding '
              'one does not field it — a released questionnaire would still be '
              'needed before any customer result could exist.',
        ),
      ];
    }
    return [
      _card(
        icon: 'playlist_add',
        title: 'Added by you in Step 4',
        trailing: Pill('${extraQuestions.length}', tone: 'neutral'),
        children: [
          ul(classes: 'asw-rpt__list', [
            for (final question in extraQuestions)
              li([Component.text(question)]),
          ]),
          p(classes: 'asw-rpt__note', [
            Component.text(
              'Added questions are session-only and have no customer results.',
            ),
          ]),
        ],
      ),
    ];
  }

  List<Component> _evidence() {
    final checks = report.requirementMatching;
    final groups = report.evidenceGroups;
    final association = report.researchAssociation.asMap;
    final explanation = report.explanation.asMap;

    return [
      _card(
        icon: 'rule',
        title: 'Requirement checks',
        trailing: Pill(
          checks.total == 0
              ? 'Nothing to check'
              : '${checks.matched} supported · ${checks.mismatched} not met',
          tone: checks.mismatched > 0 ? 'warning' : 'success',
        ),
        children: [
          if (checks.checks.isEmpty)
            _emptyInline(
              checks.note.isEmpty
                  ? 'No requirement could be checked from the stored data.'
                  : checks.note,
            )
          else
            div(classes: 'table-scroll', [
              table(classes: 'asw-rpt__table', [
                thead([
                  tr([
                    th([Component.text('Check')]),
                    th([Component.text('Verdict')]),
                    th([Component.text('What the data says')]),
                  ]),
                ]),
                tbody([
                  for (final check in checks.checks)
                    tr([
                      td([
                        span(classes: 'asw-rpt__who', [
                          Component.text(check.label),
                        ]),
                      ]),
                      td([
                        StatusBadge(
                          check.verdictLabel,
                          tone: check.verdictTone,
                        ),
                      ]),
                      td([
                        span(classes: 'asw-rpt__sub', [
                          Component.text(check.detail),
                        ]),
                      ]),
                    ]),
                ]),
              ]),
            ]),
          if (checks.note.isNotEmpty)
            p(classes: 'asw-rpt__note', [Component.text(checks.note)]),
        ],
      ),
      div(classes: 'asw-rpt__two', [
        _card(
          icon: 'insights',
          title: 'Research model association',
          trailing: Pill(
            report.researchAssociation.available ? 'Available' : 'Unavailable',
            tone: report.researchAssociation.available ? 'success' : 'warning',
          ),
          children: [
            if (!report.researchAssociation.available)
              _emptyInline(
                report.researchAssociation.reason ??
                    'The research model produced no score for this property.',
              )
            else ...[
              div(classes: 'asw-rpt__score', [
                Component.text(_number(association?['score'])),
              ]),
              p(classes: 'asw-rpt__body', [
                Component.text(_scoreMeaning(association?['score_meaning'])),
              ]),
              dl(classes: 'asw-rpt__defs', [
                _def('Base value', _number(association?['base_value'])),
                _def('Model version', '${association?['model_version'] ?? '—'}'),
                _def('Feature set', '${association?['feature_set'] ?? '—'}'),
              ]),
            ],
          ],
        ),
        _card(
          icon: 'psychology',
          title: 'Model explanation (SHAP)',
          trailing: Pill(
            report.explanation.available ? 'Available' : 'Unavailable',
            tone: report.explanation.available ? 'success' : 'warning',
          ),
          children: [
            if (!report.explanation.available)
              _emptyInline(
                report.explanation.reason ??
                    'No verified SHAP explanation is stored for this property.',
              )
            else ...[
              _legend(
                'Strongest support',
                'success',
                _factorText(explanation?['strongest_positive']),
              ),
              _legend(
                'Strongest drag',
                'danger',
                _factorText(explanation?['strongest_negative']),
              ),
              p(classes: 'asw-rpt__note', [
                Component.text(
                  'Explainer: ${explanation?['explainer'] ?? '—'} · '
                  'background ${explanation?['background_size'] ?? '—'} rows · '
                  'additivity ${explanation?['additivity_ok'] == true ? 'verified' : 'not verified'}.',
                ),
              ]),
            ],
          ],
        ),
      ]),
      _card(
        icon: 'travel_explore',
        title: 'Measured evidence used',
        trailing: Pill(
          report.evidenceCategories.available ? 'Included' : 'Unavailable',
          tone: report.evidenceCategories.available ? 'success' : 'warning',
        ),
        children: [
          if (groups.isEmpty)
            _emptyInline(
              report.evidenceCategories.reason ??
                  'No analysed location evidence exists for this property.',
            )
          else
            dl(classes: 'asw-rpt__defs', [
              for (final group in groups)
                _def(
                  '${group['label'] ?? group['key'] ?? 'Group'}',
                  '${AssessmentReportPayload.measuredMetrics(group)} of '
                      '${AssessmentReportPayload.totalMetrics(group)} metrics measured',
                ),
            ]),
        ],
      ),
    ];
  }

  List<Component> _coverage() {
    final rows = <(String, ReportSection)>[
      ('Business preferences', report.questionnaire),
      ('Property listing', report.property),
      ('Listing media', report.listingMedia),
      ('Geospatial features', report.geospatialFeatures),
      ('Location evidence', report.evidenceCategories),
      ('Research association', report.researchAssociation),
      ('Model explanation', report.explanation),
    ];
    return [
      div(classes: 'asw-rpt__coverage', [
        for (final (label, section) in rows)
          div(
            classes:
                'asw-rpt__cov${section.available ? '' : ' asw-rpt__cov--off'}',
            [
              span(classes: 'asw-rpt__covlabel', [Component.text(label)]),
              StatusBadge(
                section.available ? 'Included' : 'Not available',
                tone: section.available ? 'success' : 'warning',
              ),
              if (!section.available && (section.reason ?? '').isNotEmpty)
                span(classes: 'asw-rpt__covreason', [
                  Component.text(section.reason!),
                ]),
            ],
          ),
      ]),
      p(classes: 'asw-rpt__note', [
        Component.text(
          'Coverage is computed from this read, not from a frozen snapshot: '
          'the report is assembled each time it is opened.',
        ),
      ]),
    ];
  }

  List<Component> _sources() => [
    _card(
      icon: 'source',
      title: 'Source trail',
      children: [
        div(classes: 'table-scroll', [
          table(classes: 'asw-rpt__table', [
            thead([
              tr([
                th([Component.text('Source')]),
                th([Component.text('Role in this report')]),
                th([Component.text('This read')]),
              ]),
            ]),
            tbody([
              for (final (source, role, state) in const [
                (
                  'Step 2 business preferences',
                  'Declared business description',
                  'Loaded',
                ),
                (
                  'Property catalogue record',
                  'Listing facts and verification state',
                  'Loaded',
                ),
                (
                  'Analysed location evidence',
                  'Measured catchment, access and competitor metrics',
                  'Loaded when available',
                ),
                (
                  'Persisted SHAP explanation',
                  'Model association and feature attribution',
                  'Loaded when available',
                ),
                (
                  'Customer questionnaire responses',
                  'Fielded customer answers',
                  'Not attached',
                ),
              ])
                tr([
                  td([Component.text(source)]),
                  td([Component.text(role)]),
                  td([Component.text(state)]),
                ]),
            ]),
          ]),
        ]),
      ],
    ),
    _card(
      icon: 'report',
      title: 'Still missing from this report',
      trailing: Pill(
        report.missingInformation.isEmpty
            ? 'Nothing missing'
            : '${report.missingInformation.length}',
        tone: report.missingInformation.isEmpty ? 'success' : 'warning',
      ),
      children: [
        if (report.missingInformation.isEmpty)
          _emptyInline('Every section of this report is backed by stored data.')
        else
          ul(classes: 'asw-rpt__list asw-rpt__list--warn', [
            for (final gap in report.missingInformation)
              li([Component.text(gap)]),
          ]),
        p(classes: 'asw-rpt__note', [
          strong([Component.text('Export: ')]),
          Component.text(
            report.exportReason ??
                'A printable copy is produced by the browser print dialog.',
          ),
        ]),
      ],
    ),
    p(classes: 'asw-rpt__footnote', [
      Component.text(
        'This report is decision support. It is not verified fact, not '
        'regulatory advice, and not a prediction of business performance. '
        'Licensing, extraction, venting and grease-trap requirements still '
        'need official confirmation.',
      ),
    ]),
  ];

  // ------------------------------------------------------------------ pieces

  Component _kpi({
    required String icon,
    required String label,
    required String value,
    required String foot,
    String tone = 'blue',
  }) => div(classes: 'asw-rpt__kpi asw-rpt__kpi--$tone', [
    span(classes: 'asw-rpt__kpiicon', [Icon(icon, size: 'sm')]),
    span(classes: 'asw-rpt__kpilabel', [Component.text(label)]),
    span(classes: 'asw-rpt__kpivalue', [Component.text(value)]),
    span(classes: 'asw-rpt__kpifoot', [Component.text(foot)]),
  ]);

  Component _card({
    required String icon,
    required String title,
    required List<Component> children,
    Component? trailing,
  }) => section(classes: 'asw-rpt__card', [
    div(classes: 'asw-rpt__cardhead', [
      span(classes: 'asw-rpt__cardicon', [Icon(icon, size: 'sm')]),
      h3(classes: 'asw-rpt__cardtitle', [Component.text(title)]),
      ?trailing,
    ]),
    ...children,
  ]);

  Component _legend(String label, String tone, String text) =>
      div(classes: 'asw-rpt__legend', [
        StatusBadge(label, tone: tone),
        span(classes: 'asw-rpt__legendtext', [Component.text(text)]),
      ]);

  Component _def(String label, String value) => div(classes: 'asw-rpt__def', [
    dt([Component.text(label)]),
    dd([Component.text(value)]),
  ]);

  Component _empty({
    required String title,
    required String body,
    String? foot,
  }) => div(classes: 'asw-rpt__empty', [
    span(classes: 'asw-rpt__emptyicon', [Icon('info', size: 'sm')]),
    div(classes: 'asw-rpt__emptycopy', [
      strong([Component.text(title)]),
      p([Component.text(body)]),
      if (foot != null) span(classes: 'asw-rpt__emptyfoot', [Component.text(foot)]),
    ]),
  ]);

  Component _emptyInline(String text) =>
      div(classes: 'asw-rpt__emptyinline', [Component.text(text)]);

  /// The model's own `score_meaning` code, said in a sentence. The backend
  /// emits a machine token (`..._NOT_business_success_probability`) precisely
  /// so no surface can dress the index up as a success probability — printing
  /// the token raw is correct but unreadable, so the known token is expanded
  /// and anything unrecognised is passed through verbatim rather than guessed.
  static String _scoreMeaning(Object? value) {
    final raw = value is String ? value : '';
    if (raw.contains('NOT_business_success_probability')) {
      return "A research index of how strongly this location's measured "
          'features associate with the positive label in the training data. '
          'It is not a probability of business success, a revenue forecast, '
          'or a customer-volume estimate.';
    }
    return raw.isEmpty ? 'No score meaning was returned.' : raw;
  }

  static String _factorText(Object? factor) {    if (factor is Map) {
      final label = factor['label'] ?? factor['feature'] ?? factor['name'];
      final value = factor['value'] ?? factor['shap'] ?? factor['contribution'];
      if (label != null && value != null) return '$label ($value)';
      if (label != null) return '$label';
    }
    return factor == null
        ? 'No single feature dominates this score.'
        : '$factor';
  }

  static String _number(Object? value) {
    if (value is num) {
      return value == value.roundToDouble()
          ? value.toStringAsFixed(0)
          : value.toStringAsFixed(2);
    }
    return value == null ? '—' : '$value';
  }

  static String _date(String? iso) {
    if (iso == null || iso.length < 16) return 'just now';
    return iso.substring(0, 16).replaceFirst('T', ' ');
  }
}
