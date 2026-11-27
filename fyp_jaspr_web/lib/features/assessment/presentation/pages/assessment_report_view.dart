import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import 'package:sitewise_jaspr_web/shared/presentation/components/ui.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/assessment_api.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/assessment_report.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/business_description.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/chart_spec.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/chart_preview.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/explanation_candidate.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/measurement_chart_preview.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/q01_synthetic_preview.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/report_composition.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/report_measurement.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/synthetic_preview_gate.dart';
import 'package:sitewise_jaspr_web/features/assessment/presentation/components/chart_spec_view.dart';
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

  /// Admitted `chart-spec/1` for the R03 questionnaire section.
  ///
  /// `null` in V1: no adopted report-admission adapter exists, so the backend
  /// cannot produce an admitted spec. The section then renders its held state
  /// instead of a chart. A spec that is not `RENDERABLE` is also refused here,
  /// so a caller cannot smuggle a withheld measurement into the report.
  final ChartSpecModel? chartSpec;

  /// Development-only synthetic Q01 demonstration, rendered inside this same
  /// report beside R03.
  ///
  /// `null` in every production build: the caller supplies it only when the
  /// development gate is open. It is deliberately a **separate** parameter from
  /// [chartSpec] so the two can never be confused — [chartSpec] is the
  /// admitted-measurement path and is gated on `isReportAdmissible`, while this
  /// one is a demonstration and is gated on `isSyntheticPreview`. Neither can
  /// satisfy the other's check.
  final Q01SyntheticPreview? q01Preview;

  /// Development-only diagnostic readback of a **real** EE-01 measurement,
  /// rendered in the same R03 questionnaire section as the held notice.
  ///
  /// `null` in every production build, and `null` whenever the fixture is not a
  /// held, non-disclosing payload. It is a third, separate parameter on purpose:
  /// [chartSpec] is the admitted path, [q01Preview] is a synthetic
  /// demonstration, and this one is a measured-but-withheld readback. None can
  /// satisfy another's gate, so a withheld measurement can never be mistaken
  /// for an admitted finding.
  ///
  /// Supplying it is not enough for it to be drawn — see [_boundMeasurement].
  final MeasurementChartPreview? measurementChart;

  /// Development-only synthetic chart previews for the measured slots.
  ///
  /// `null` in every production build. Supplied only when the caller's synthetic
  /// gate is open **and** the server answered the preview endpoint for this
  /// campaign — the server enforces its own module switch and per-run developer
  /// grant, so this parameter can widen what is *drawn* but never what is
  /// *authorized*. Every spec here is `SYNTHETIC_PREVIEW_ONLY` with a `HELD`
  /// admission block; [ChartPreviewSlot.isDrawable] refuses anything else, so a
  /// withheld spec cannot be drawn by passing it.
  final ChartPreviewBundle? chartPreviews;

  /// The server-rendered explanation for the questionnaire item in this section.
  ///
  /// `null` in V1's production path: every Q01–Q13 item is instrument-gated, so
  /// no explanation is admitted. When supplied, only a *withheld* explanation is
  /// drawn here — it discloses no figure, so it is safe in a production report.
  /// A substantive but unadmitted explanation renders nothing at all; see
  /// [ExplanationPanel.isRenderable]. The backend decides the prose; this page
  /// only places it beneath the chart it explains.
  final ExplanationPanel? explanation;

  /// Dev-only explanation cards for the isolated synthetic preview.
  ///
  /// A production build compiles the gate to false, so this list can never be
  /// drawn by the ordinary report. It exists so the same card component can be
  /// exercised with deterministic, mocked-AI and fallback wording without
  /// changing A10 or persisting an admitted row.
  final List<ExplanationPanel> syntheticExplanations;

  /// The confirmed business description bound to this assessment (RP-13).
  ///
  /// `null` when the caller could not read it. A non-null value with
  /// [BusinessDescription.isAvailable] replaces the Step-2 draft rows in section
  /// 02, because a confirmed declaration is a better source than the workspace
  /// input it was built from. A non-null value with
  /// [BusinessDescription.isNotYetConfirmed] renders an explicit "not yet
  /// confirmed" state instead of a blank card.
  final BusinessDescription? businessDescription;

  /// The measurement readback, but only when it belongs to **this** record.
  ///
  /// A measurement card names a campaign, a policy, a funnel and a chart
  /// identity. Drawing it under another assessment's heading would attribute
  /// one assessment's measurement to another, which is the exact error the
  /// report must never make. So the binding is enforced here rather than
  /// trusted from the caller:
  ///
  /// * the provenance must name this assessment, and
  /// * the chart's own `campaign_id` must be the campaign the provenance names.
  ///
  /// A caller that hands over the wrong assessment's readback gets nothing
  /// rendered — not a warning, because a warning would still confirm that some
  /// other measurement exists.
  MeasurementChartPreview? get _boundMeasurement {
    final preview = measurementChart;
    if (preview == null) return null;
    if (preview.provenance.assessmentId != record.assessmentId) return null;
    if (preview.chart.campaignId != preview.provenance.campaignId) return null;
    return preview;
  }

  /// The EE-01 measurement association, but only when the payload it arrived in
  /// is **this** record's report.
  ///
  /// [report] is supplied by the caller, so it could in principle describe a
  /// different assessment. Section 05 attributes a cohort, a campaign and a
  /// hold reason to the assessment above it, so the identity is checked here
  /// rather than trusted — the same rule [_boundMeasurement] applies to a
  /// chart. An empty payload id is tolerated because a report assembled by an
  /// older server does not carry one; a *different* id is not.
  ReportMeasurement? get _boundAssociation {
    final association = report.measurement;
    if (association == null) return null;
    final payloadId = report.assessmentId;
    if (payloadId.isNotEmpty && payloadId != record.assessmentId) return null;
    return association;
  }

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
    this.chartSpec,
    this.q01Preview,
    this.measurementChart,
    this.chartPreviews,
    this.businessDescription,
    this.explanation,
    this.composition,
    this.syntheticExplanations = const [],
    this.backLabel = 'Back',
    required this.onBack,
  });

  /// The backend's own nine-section composition, or `null` when it could not
  /// be read.
  ///
  /// It is the authority on section availability and on the A10 state behind
  /// each section. When it is absent the view still renders — it keeps its own
  /// ordering and the payload-derived coverage — but section 08 says the
  /// composition could not be read rather than presenting its own guess as the
  /// backend's answer.
  final ReportComposition? composition;

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
      'The business you confirmed, at the version this report used.',
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
      div(classes: 'asw-rpt__chrome', [
        _toolbar(),
        _jumpBar(),
      ]),
      for (final (id, index, title, purpose) in _sections)
        _section(id, index, title, purpose, _bodyFor(id)),
      _actions(),
    ]);
  }

  // ------------------------------------------------------------------ chrome

  Component _toolbar() {
    final generated = _date(report.generatedAt);
    return div(classes: 'asw-rpt__bar', [
      button(
        classes: 'asw-rpt__backlink',
        attributes: const {'type': 'button'},
        events: events(onClick: onBack),
        [Component.text('← Back to workspace')],
      ),
      div(classes: 'asw-rpt__docid', [
        span(classes: 'asw-rpt__docmark', [Component.text('S')]),
        span(classes: 'asw-rpt__docname', [
          Component.text('Sitewise · Assessment report'),
        ]),
      ]),
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

  /// The jump bar for the whole document: one chip per section, in order.
  ///
  /// Every section is listed. A chip that scrolls to a section which is not
  /// drawn would be a dead control, so the two lists are the same [_sections]
  /// constant and cannot drift apart.
  Component _jumpBar() => nav(
    classes: 'asw-rpt__nav',
    attributes: const {'aria-label': 'Jump to a report section'},
    [
      for (final section in _sections)
        button(
          classes: 'asw-rpt__navlink',
          attributes: const {'type': 'button'},
          events: events(onClick: () => scrollToId(section.$1)),
          [
            span(classes: 'asw-rpt__navindex', [
              Component.text(section.$2),
            ]),
            span([Component.text(section.$3)]),
          ],
        ),
    ],
  );

  Component _section(
    String id,
    String index,
    String title,
    String purpose,
    List<Component> body,
  ) => section(
    classes: 'asw-rpt__section',
    attributes: {'id': id},
    [
      div(classes: 'asw-rpt__sechead', [
        span(classes: 'asw-rpt__secindex', [Component.text(index)]),
        div(classes: 'asw-rpt__seccopy', [
          h2(classes: 'asw-rpt__sectitle', [Component.text(title)]),
          p(classes: 'asw-rpt__secdesc', [Component.text(purpose)]),
        ]),
      ]),
      ...body,
    ],
  );

  /// The report is a read-only destination; the checkpoint owns stage
  /// completion. The footer only links onward to the next section.
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
      button(
        classes: 'asw-rpt__pagerlink asw-rpt__pagerlink--next',
        attributes: const {'type': 'button'},
        events: events(onClick: () => scrollToId('asw-rpt-coverage')),
        [Component.text('Next: 08 Report coverage →')],
      ),
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
          // The full data-origin disclosure lives here, once, rather than as a
          // banner over every chart. It appears whenever a demonstration
          // surface is actually mounted, so a reader can always find out where
          // the responses came from — and it is absent from a report that shows
          // no demonstration data.
          if (chartPreviews != null || q01Preview != null)
            p(classes: 'asw-rpt__note', [
              strong([Component.text('${ChartSpecView.demoModeLabel}: ')]),
              Component.text(ChartSpecView.dataOriginDisclosure),
            ]),
        ],
      ),
    ];
  }

  List<Component> _business() {
    final confirmed = businessDescription;
    final property = record.property;

    // A confirmed context is the authoritative description. It is shown on its
    // own, because printing the Step-2 draft beside it would present two
    // versions of the same declaration and leave the reader to pick one.
    if (confirmed != null && confirmed.isAvailable) {
      return [
        _confirmedBusinessCard(confirmed),
        if (property != null) _boundPropertyCard(property),
      ];
    }

    // Nothing confirmed yet. Say which prerequisite is missing rather than
    // showing an empty card, and never fall back to another assessment's text.
    if (confirmed != null && confirmed.isNotYetConfirmed) {
      return [
        _empty(
          title: 'No confirmed business description yet',
          body: confirmed.detail ??
              'This assessment has no confirmed business declaration, so '
                  'there is no description to report. Confirm your business '
                  'details to populate this section.',
          foot: 'Nothing is inferred here. A description appears only after the '
              'declaration is confirmed and its stored context is verified.',
        ),
        if (property != null) _boundPropertyCard(property),
      ];
    }

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
      if (property != null) _boundPropertyCard(property),
    ];
  }

  /// The confirmed declaration, with its own provenance and limitations.
  ///
  /// Every row names the M2 answer it came from, so a reader can trace a
  /// sentence back to the revision that produced it. The limitations are the
  /// packet's own, unedited: this section is a declaration, not a verified fact.
  Component _confirmedBusinessCard(BusinessDescription confirmed) {
    final source = confirmed.source;
    final revision = source['assessment_revision'];
    return _card(
      icon: 'storefront',
      title: 'Confirmed business description',
      trailing: Pill('Confirmed declaration', tone: 'success'),
      children: [
        div(classes: 'asw-rpt__legend', [
          StatusBadge('ENTREPRENEUR_CONFIRMED', tone: 'neutral'),
          span(classes: 'asw-rpt__legendtext', [
            Component.text(
              'Your own confirmed description. Not independently verified, and '
              'not a finding about the market.',
            ),
          ]),
        ]),
        dl(classes: 'asw-rpt__defs', [
          for (final row in confirmed.rows)
            div(classes: 'asw-rpt__def', [
              dt([Component.text(row.label)]),
              dd([
                Component.text(row.text ?? row.code ?? ''),
                if (row.text != null && row.code != null)
                  span(classes: 'asw-rpt__sub', [
                    Component.text(' · ${row.code}'),
                  ]),
                if (row.source['item_key'] is String)
                  span(classes: 'asw-rpt__sub', [
                    Component.text(' · ${row.source['item_key']}'),
                  ]),
              ]),
            ]),
        ]),
        if (confirmed.uncertainty != null)
          p(classes: 'asw-rpt__note', [
            strong([Component.text('Confirmed uncertainty: ')]),
            Component.text(confirmed.uncertainty!.text),
          ]),
        p(classes: 'asw-rpt__note', [
          strong([Component.text('Source: ')]),
          Component.text(
            'confirmation ${_short(source['confirmation_id'])}, revision '
            '${revision ?? '—'}, context ${_short(source['context_id'])}, '
            'packet ${_short(source['packet_hash'])}. The description is '
            're-verified against its stored hash on every read, so a changed '
            'source shows as unavailable rather than as a stale sentence.',
          ),
        ]),
        if (confirmed.limitations.isNotEmpty) ...[
          p(classes: 'asw-rpt__note', [
            strong([Component.text('Limitations of this description: ')]),
          ]),
          ul(classes: 'asw-rpt__list', [
            for (final limitation in confirmed.limitations)
              li([Component.text(limitation)]),
          ]),
        ],
      ],
    );
  }

  /// The verification label this record actually supports.
  ///
  /// The catalogue mapper maps every imported row to
  /// `VerificationStatus.pending`, because the catalogue table has no
  /// administrator-verification column. That is the right defensive default, but
  /// it renders "Pending review" — which implies a review is queued and will
  /// happen — for listings the dataset itself marks
  /// `PU_RESEARCH_ONLY_NOT_VERIFIED`, meaning they are research-only and have
  /// never been verified. Those are different claims and the stronger one is the
  /// true one, so the raw token wins. DD-164.
  String _verificationLabel(CommercialProperty property) {
    final researchOnly = property.tags.any(
      (t) => t.contains('PU_RESEARCH_ONLY_NOT_VERIFIED'),
    );
    return researchOnly ? 'Research only — not verified' : property.verification.label;
  }

  /// The catalogue record the assessment is bound to, when there is one.
  Component _boundPropertyCard(CommercialProperty property) => _card(
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
        _def('Verification', _verificationLabel(property)),
      ]),
    ],
  );

  /// Section 03, from the composed state rather than from a fixed sentence.
  ///
  /// The five states this can be in are different facts and the copy says which
  /// one it is. "No finding" is a result; "no evaluation" is the absence of a
  /// result; "withheld" is a result the report may not show.
  List<Component> _findings() {
    final composed = composition?.byIndex('03');
    if (composed == null) {
      return [
        _empty(
          title: 'The finding state could not be read',
          body:
              'Business findings and their decisions come from the upstream M2 '
              'business-declaration stage. The report could not read whether an '
              'evaluation exists for this assessment, so it asserts neither '
              'findings nor their absence.',
          foot: 'Reopen the report once the backend composition is available.',
        ),
      ];
    }
    return [
      _empty(
        title: _findingTitle(composed.findingState),
        body: composed.detail,
        foot: composed.findingState == 'ZERO_FINDINGS_VALID'
            ? 'A valid zero means the rules were applied and none fired. It is '
                  'not the same as an evaluation that never ran.'
            : null,
      ),
    ];
  }

  static String _findingTitle(String? state) => switch (state) {
    'NO_FINDINGS_RECORDED' => 'No business-findings evaluation is stored',
    'EVALUATION_NOT_EXECUTED' => 'The findings evaluation has not run yet',
    'ZERO_FINDINGS_VALID' => 'The evaluation found no business finding',
    'FINDINGS_ACCEPTED_WITHHELD' => 'Findings are withheld from this report',
    'FINDINGS_WITHHELD' => 'Findings are withheld from this report',
    _ => 'The finding state could not be established',
  };

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

    // Rendered beneath the R03 chart in both branches. A substantive but
    // unadmitted explanation yields an empty list, so nothing appears — the
    // report never publishes an unadmitted finding through explanation text.
    final panel = explanation;
    final explanationCards =
        panel != null && panel.isRenderable ? _explanationSection(panel) : const <Component>[];

    // The only route that can supply these panels is the dev-gated harness.
    // Each card is labelled synthetic and never claims report admission.
    final syntheticCards = syntheticPreviewEnabled
        ? syntheticExplanations
            .where((candidate) => candidate.isSyntheticPreviewRenderable)
            .expand((candidate) => _explanationSection(candidate, synthetic: true))
            .toList(growable: false)
        : const <Component>[];

    // R03 is reserved by the specification for the Q05 concept-intent
    // distribution as a horizontal bar chart. It renders only from an admitted
    // chart-spec; anything else keeps the section in its held state.
    final admitted = chartSpec;
    if (admitted != null && admitted.isReportAdmissible) {
      return [
        ChartSpecView(
          spec: admitted,
          note:
              'Counts are respondent counts within V. The share column is '
              'printed from the admitted measurement line, not recomputed here.',
        ),
        ...explanationCards,
        ...syntheticCards,
      ];
    }

    // Only a readback that names *this* assessment may be drawn here.
    final measurement = _boundMeasurement;

    // What the backend resolved for this assessment — marketplace → M2 →
    // campaign → frozen snapshot, identity and admission only. It is what
    // separates "nothing was measured" from "something was measured and is
    // withheld", which the specification's default notice conflated.
    final association = _boundAssociation;

    return [
      ..._measurementStateSection(association, respondents, responses),
      ...explanationCards,
      ...syntheticCards,
      // Q01 sits in the same section as R03 because it is the other
      // questionnaire-derived distribution. It is a demonstration, so it is
      // appended *after* the held R03 state and never replaces it.
      if (measurement != null) ..._measurementChartSection(measurement),
      if (q01Preview != null) ..._q01PreviewSection(q01Preview!),
    ];
  }

  /// R03's state, driven by the server's measurement association.
  ///
  /// Four different facts used to print as one sentence. They are now four
  /// sentences, because a reader acts differently on each:
  ///
  /// * the assessment has no M2 confirmation → no campaign can exist;
  /// * the confirmation exists but owns no campaign → nothing was fielded;
  /// * a campaign and frozen snapshots exist, and admission is withheld →
  ///   evidence exists and may not be disclosed;
  /// * the questionnaire store could not be read → we did not look
  ///   successfully, which is not the same as finding nothing.
  ///
  /// None of them renders an empty chart. An empty chart reads as a measured
  /// zero, and for the third case that would be a false statement about a
  /// cohort that answered.
  List<Component> _measurementStateSection(
    ReportMeasurement? association,
    int? respondents,
    int? responses,
  ) {
    final participation = respondents == null && responses == null
        ? null
        : 'Participation on record: ${respondents ?? 0} registered '
            'respondent(s), ${responses ?? 0} submitted response(s) — '
            'participation is not a distribution.';

    // No section, or a report composed without a resolver: the specification's
    // own notice, unchanged. This is the only branch that may still say "no
    // admitted measurement line exists", because here we genuinely do not know.
    if (association == null ||
        association.status == ReportMeasurement.statusNotResolved) {
      return [
        _empty(
          title: 'R03 · Concept intent distribution — held',
          body:
              'The report specification reserves R03 for the Q05 concept-intent '
              'distribution, drawn as a horizontal bar chart of option counts '
              'against V. No measurement association was resolved for this '
              'assessment, so the section shows its held state rather than an '
              'empty chart — an empty chart would read as a measured zero.',
          foot: participation ??
              'Held because no report-admission adapter is adopted: EE-01 '
                  'withholds findings, and R03 is specification-only with '
                  'gates G03–G08 and G10 open.',
        ),
      ];
    }

    if (!association.evidenceExists) {
      return [
        _empty(
          title: _measurementAbsentTitle(association),
          body: association.reason,
          foot: participation ?? _measurementAbsentFoot(association),
        ),
      ];
    }

    // HELD. The association is real, the numbers are not disclosable.
    final identity = association.identity;
    final slots = association.slots;
    return [
      _card(
        icon: 'query_stats',
        title: 'R03 · Concept intent distribution — held',
        trailing: const Pill('Findings withheld', tone: 'warning'),
        children: [
          div(classes: 'asw-rpt__legend', [
            StatusBadge(
              association.reasonCode ?? 'WITHHELD_NOT_AUTHORIZED',
              tone: 'warning',
            ),
          ]),
          p(classes: 'asw-rpt__note', [Component.text(association.reason)]),
          p(classes: 'asw-rpt__note', [
            strong([Component.text('Measurement association: ')]),
            Component.text(
              [
                ?association.cohortLabel,
                if (identity?.snapshotId case final id?)
                  'snapshot ${_shortId(id)}',
                if (identity?.campaignId case final id?)
                  'campaign ${_shortId(id)}',
                if (identity?.questionVersion case final version?)
                  'instrument $version',
                'M2 assessment ${_shortId(identity?.m2AssessmentId ?? '')}',
              ].join(' · '),
            ),
          ]),
          p(classes: 'asw-rpt__note', [
            strong([Component.text('Why no chart: ')]),
            Component.text(
              'The counts and the shares exist and are withheld — they are not '
              'zero. Drawing the axis without them would read as a measured '
              'zero for every option, so the section reports the association '
              'and the hold instead.',
            ),
          ]),
          if (slots.length > 1)
            p(classes: 'asw-rpt__note', [
              strong([Component.text('Frozen slots measured: ')]),
              Component.text(
                '${slots.map((slot) => slot.slotId).join(', ')} — '
                '${slots.length} slots, each at its own cutoff. Slots that were '
                'never shown are not zero demand; they were not asked.',
              ),
            ]),
          if (participation != null)
            p(classes: 'asw-rpt__note', [Component.text(participation)]),
        ],
      ),
      // Developer diagnostic, below the hold and never instead of it. The hold
      // is the report's statement; this is an inspection aid that says so.
      if (chartPreviews != null) ..._chartPreviewSection(chartPreviews!),
    ];
  }

  /// Response distribution for the measured slots of this campaign.
  ///
  /// Only [ChartPreviewSlot.isDrawable] slots are charted. A `NOT_SHOWN` slot
  /// and a slot whose contract requires an approved stimulus are *described*,
  /// never drawn: an empty axis would read as a measured zero, and for those two
  /// states that is exactly the false statement the report must avoid.
  ///
  /// Presentation is a business report — a small `Demo Mode` chip, a coverage
  /// line and per-question metadata. The states behind it are untouched: every
  /// slot here is still `SYNTHETIC_PREVIEW_ONLY` or held, and none is admitted
  /// into R02 or R08.
  List<Component> _chartPreviewSection(ChartPreviewBundle bundle) {
    final drawn = bundle.drawable.length;
    return [
      _card(
        icon: 'insights',
        title: 'Response distribution by question',
        trailing: const Pill(ChartSpecView.demoModeLabel, tone: 'neutral'),
        children: [
          p(classes: 'asw-rpt__note', [
            Component.text(
              'Distribution of the saved questionnaire responses for each '
              'measured question. These figures illustrate the measurement '
              'pipeline; they are not admitted findings, and the hold above is '
              'unchanged.',
            ),
          ]),
          p(classes: 'asw-rpt__note', [
            strong([Component.text('Coverage: ')]),
            Component.text(
              '$drawn of ${bundle.slots.length} measured questions charted. '
              'Campaign ${_shortId(bundle.campaignId)} · contract '
              '${bundle.contractVersion}.',
            ),
          ]),
          // Gate 3: a slot may have more than one stored snapshot. Say so,
          // because "the measurement" would be a different claim when the
          // server selected one revision out of several.
          if (bundle.multiRevision.isNotEmpty)
            p(classes: 'asw-rpt__note', [
              strong([Component.text('Revision selection: ')]),
              Component.text(
                '${bundle.multiRevision.map((slot) => '${slot.slotId} (${slot.candidates})').join(', ')} '
                'hold more than one frozen snapshot. One was selected by '
                '${bundle.selectionPolicy ?? 'the server policy'}; the evidence '
                'is not pinned to a report revision, so a later snapshot '
                'replaces it on the next read.',
              ),
            ]),
          for (final slot in bundle.slots) ...[
            div(classes: 'asw-rpt__legend', [
              StatusBadge(
                _slotStateLabel(slot),
                tone: slot.isDrawable ? 'neutral' : 'warning',
              ),
            ]),
            p(classes: 'asw-rpt__note', [
              strong([Component.text('${slot.slotId} · ')]),
              Component.text(
                [
                  ?slot.cutoff,
                  if (slot.snapshotId case final id?) 'snapshot ${_shortId(id)}',
                  if (slot.funnel case final funnel?)
                    'Q ${funnel.qualified} · S ${funnel.shown} · '
                        'A ${funnel.answered} · V ${funnel.substantive}',
                ].join(' · '),
              ),
            ]),
            if (slot.isDrawable)
              ChartSpecView(
                spec: slot.spec!,
                note: 'V is the denominator for every share shown; the share '
                    'column is the saved diagnostic line, not an authorised '
                    'estimate.',
              )
            else
              p(classes: 'asw-rpt__note', [Component.text(slot.stateLine)]),
          ],
        ],
      ),
    ];
  }

  /// Human label for a slot's state. The wire codes
  /// (`SYNTHETIC_PREVIEW_ONLY`, `NOT_SHOWN`, …) stay in the API payload and in
  /// the evidence record; a business report prints the meaning, not the enum.
  static String _slotStateLabel(ChartPreviewSlot slot) {
    if (slot.isDrawable) return ChartSpecView.demoModeLabel;
    if (slot.isNotShown) return 'Not shown';
    if (slot.isMissingStimulus) return 'Unavailable';
    return 'Held';
  }

  static String _shortId(String value) =>
      value.length <= 8 ? value : '${value.substring(0, 8)}…';

  String _measurementAbsentTitle(ReportMeasurement association) {
    switch (association.status) {
      case ReportMeasurement.statusNoM2Link:
        return 'R03 · Concept intent distribution — no confirmed business';
      case ReportMeasurement.statusUnavailable:
        return 'R03 · Concept intent distribution — association unavailable';
      default:
        return 'R03 · Concept intent distribution — not yet fielded';
    }
  }

  String _measurementAbsentFoot(ReportMeasurement association) {
    switch (association.status) {
      case ReportMeasurement.statusUnavailable:
        // Deliberately not a restatement of the server's reason, which is
        // already the body of this card. The reader's next question is what to
        // do about it, and the answer is specific: the association is resolved
        // on every read, so a re-read is enough — nothing was lost.
        return 'The association is resolved again on every report read, so '
            're-reading once the store is reachable recovers it. Until then '
            'this section claims nothing about the questionnaire either way.';
      case ReportMeasurement.statusNoM2Link:
        return 'Stage 2 must be confirmed before a questionnaire campaign can '
            'be associated with this assessment.';
      default:
        return 'No questionnaire has been fielded for the confirmed business '
            'behind this assessment.';
    }
  }

  /// The server-rendered explanation for this section's item, in the report's
  /// own card layout.
  ///
  /// The prose arrives already composed by the backend from hash-pinned
  /// templates; this method places it and adds no sentence of its own. Only a
  /// withheld explanation or an admitted one reaches here —
  /// [ExplanationPanel.isRenderable] has already refused everything else.
  List<Component> _explanationSection(ExplanationPanel panel,
      {bool synthetic = false}) {
    // A module-level refusal is not a withheld item. It says nothing was
    // measured, so it must not borrow the withheld card's state badge or its
    // "Explanation source" line — both would imply an item was considered.
    if (panel.moduleHeld) {
      return [
        _card(
          icon: 'notes',
          title: 'Explanations',
          trailing: const Pill('Unavailable', tone: 'neutral'),
          children: [
            p(classes: 'asw-rpt__note', [
              strong([Component.text(panel.headline)]),
            ]),
            p(classes: 'asw-rpt__note', [Component.text(panel.observation)]),
          ],
        ),
      ];
    }
    return [
    _card(
      icon: 'notes',
      title: panel.questionId == null
          ? (synthetic ? 'Explanation · synthetic preview' : 'Explanation')
          : synthetic
              ? '${panel.questionId} · synthetic preview'
              : '${panel.questionId} · explanation',
      trailing: synthetic
          ? const Pill('Synthetic preview', tone: 'neutral')
          : Pill(
              panel.isReportAdmissible ? 'Admitted' : 'Explanation withheld',
              tone: panel.isReportAdmissible ? 'success' : 'warning',
            ),
      children: [
        div(classes: 'asw-rpt__legend', [
          StatusBadge(
            synthetic
                ? 'SYNTHETIC_PREVIEW_ONLY'
                : panel.state ?? 'WITHHELD_NOT_AUTHORIZED',
            tone: synthetic
                ? 'neutral'
                : panel.isReportAdmissible
                    ? 'success'
                    : 'warning',
          ),
          span(classes: 'asw-rpt__legendtext', [
            Component.text(synthetic
                ? 'Synthetic evidence — not a report finding'
                : panel.stateLabel)
          ]),
        ]),
        p(classes: 'asw-rpt__note', [
          strong([Component.text(panel.headline)]),
        ]),
        p(classes: 'asw-rpt__note', [Component.text(panel.observation)]),
        p(classes: 'asw-rpt__note', [Component.text(panel.research)]),
        p(classes: 'asw-rpt__note', [Component.text(panel.planning)]),
        p(classes: 'asw-rpt__note', [
          strong([Component.text('Limitations: ')]),
          Component.text(panel.limitations),
        ]),
        if (panel.missingEvidenceReferences.isNotEmpty)
          p(classes: 'asw-rpt__note', [
            strong([Component.text('Still required: ')]),
            Component.text(panel.missingEvidenceReferences.join(' · ')),
          ]),
        p(classes: 'asw-rpt__note', [
          strong([Component.text('Explanation source: ')]),
          Component.text(
            'registry ${panel.registryVersion ?? '—'} '
            '(${_shortHash(panel.registrySha256)}), producer '
            '${panel.producer.isEmpty ? '—' : panel.producer}, '
            'authority ${panel.authority}. The wording is generated by the '
            'backend from pinned templates; it adds no measurement.',
          ),
        ]),
      ],
    ),
    ];
  }

  static String _shortHash(String? value) {
    if (value == null || value.isEmpty) return '—';
    return value.length <= 12 ? value : '${value.substring(0, 12)}…';
  }

  /// The measured-but-withheld readback for R03, in this report's own layout.
  ///
  /// Unlike the Q01 preview this is not a demonstration of geometry: the
  /// measurement behind it is real, ran under EE-01 as a restricted principal,
  /// and its funnel is printed from the persisted snapshot. What it does **not**
  /// have is authority — no admitted report source exists — so the chart renders
  /// the withheld notice, the gates are listed, and no count or percentage is
  /// disclosed. It therefore adds evidence to R03 without turning it into a
  /// finding.
  List<Component> _measurementChartSection(MeasurementChartPreview preview) {
    final chart = preview.chart;
    final provenance = preview.provenance;
    return [
      _card(
        icon: 'query_stats',
        title:
            '${chart.questionId} · ${chart.constructId.replaceAll('_', ' ').toLowerCase()} — measurement readback',
        trailing: Pill('Findings withheld', tone: 'warning'),
        children: [
          div(classes: 'asw-rpt__legend', [
            StatusBadge('WITHHELD_NOT_AUTHORIZED', tone: 'warning'),
          ]),
          p(classes: 'asw-rpt__note', [
            Component.text(
              'A real measurement exists for this assessment. It is shown here '
              'as a readback, not a result: the measurement ran, but no '
              'authorized report source is adopted, so the counts and the '
              'shares are withheld rather than estimated.',
            ),
          ]),
          ChartSpecView(spec: chart),
          p(classes: 'asw-rpt__note', [
            strong([Component.text('Funnel at the cutoff: ')]),
            Component.text(preview.funnelSentence),
          ]),
          p(classes: 'asw-rpt__note', [
            strong([Component.text('Open gates: ')]),
            Component.text(chart.admission.gates.join(' · ')),
          ]),
          p(classes: 'asw-rpt__note', [
            strong([Component.text('Measurement provenance: ')]),
            Component.text(
              '${provenance.slot} under ${provenance.rule}, campaign '
              '${provenance.campaignId.substring(0, 8)}…, policy '
              '${provenance.policyVersion}. Chart identity is bound to EE-01 '
              'readback context '
              '${provenance.evidenceContextHash.substring(0, 12)}…, so this '
              'chart cannot be attached to a different measurement.',
            ),
          ]),
          p(classes: 'asw-rpt__note', [
            strong([Component.text('What this is not: ')]),
            Component.text(
              'not customer-demand evidence, not an admitted finding, and not a '
              'percentage. The measurement is synthetic and the admission block '
              'is held, so nothing here may be quoted as a result.',
            ),
          ]),
        ],
      ),
    ];
  }

  /// The development-only Q01 synthetic demonstration, in this report's own
  /// layout: one card, the report's card head, the shared `ChartSpecView` for
  /// the chart, and the report's note/list styles for the prose.
  ///
  /// It is rendered from [q01Preview], which the caller supplies only when the
  /// development gate is open. Because the fixture's chart is
  /// `SYNTHETIC_PREVIEW_ONLY` with a `HELD` admission block, this section can
  /// draw bars without ever becoming report-admissible.
  List<Component> _q01PreviewSection(Q01SyntheticPreview preview) {
    final chart = preview.chart;
    return [
      _card(
        icon: 'science',
        title: 'Q01 · Area connection — ${chart.questionVersion}',
        trailing: const Pill(ChartSpecView.demoModeLabel, tone: 'neutral'),
        children: [
          p(classes: 'asw-rpt__note', [Component.text(preview.submarker)]),
          ChartSpecView(spec: chart),
          p(classes: 'asw-rpt__note', [
            strong([Component.text('Valid respondents: ')]),
            Component.text(
              '${preview.respondents} synthetic respondents gave a valid Q01 '
              'answer, of whom ${preview.exclusiveOnly} selected only an '
              'exclusive alternative. ${preview.affiliationSelections} '
              'affiliation selections were made across them '
              '(${preview.overlapSelections} of them overlapping), so the '
              'categories sum above V and are not a partition.',
            ),
          ]),
          p(classes: 'asw-rpt__note', [
            strong([Component.text('Exclusive alternatives: ')]),
            Component.text(preview.exclusiveNote),
          ]),
          _q01Interpretation(preview),
        ],
      ),
    ];
  }

  /// Deterministic interpretation: the registry's own `valid` template filled
  /// with this fixture's counts. Affiliation and exclusive alternatives are
  /// listed separately, because the instrument requires them counted apart.
  Component _q01Interpretation(Q01SyntheticPreview preview) => div(
    classes: 'asw-rpt__card asw-rpt__card--sub',
    [
      h4(classes: 'asw-rpt__cardtitle', [
        Component.text('Deterministic interpretation'),
      ]),
      p(classes: 'asw-rpt__note', [
        Component.text(
          'Registry template ${preview.templateId}, filled with the counts '
          'above. Not model output and not new wording.',
        ),
      ]),
      ul(classes: 'asw-rpt__list', [
        for (final statement in preview.affiliation)
          li([Component.text(statement.text)]),
      ]),
      p(classes: 'asw-rpt__note', [
        strong([Component.text('Exclusive alternatives, counted separately: ')]),
        Component.text(
          preview.exclusive
              .map((alternative) => '${alternative.label} ${alternative.count}')
              .join(' · '),
        ),
      ]),
      p(classes: 'asw-rpt__note', [Component.text(preview.productionBehaviour)]),
    ],
  );

  List<Component> _extras() {
    // CP-RPT-05: Section B is assessment-specific, so it is rendered from the
    // backend's composition rather than from the fixed registry. A generated
    // question has no registry entry and must not be hard-coded into one to
    // make it display; the composition is the extension point.
    final composed = composition?.byIndex('06');
    if (composed != null && composed.items.isNotEmpty) {
      return [
        _card(
          icon: 'playlist_add',
          title: 'Additional research questions',
          trailing: Pill('${composed.items.length} recorded', tone: 'neutral'),
          children: [
            for (final item in composed.items) _additionalItem(item),
            p(classes: 'asw-rpt__note', [Component.text(composed.detail)]),
          ],
        ),
      ];
    }
    if (composed != null && composed.availability == SectionAvailability.notApplicable) {
      return [
        _empty(
          title: 'No additional questions were added',
          body: composed.detail,
        ),
      ];
    }
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

  /// One Section B item, at the stage it actually reached.
  ///
  /// "Submitted for review" is not "admitted": the stage line names the stage,
  /// and the measurement attributes the report cannot obtain are printed as
  /// unestablished rather than omitted, because a blank line reads as zero.
  Component _additionalItem(AdditionalResearchItem item) => div(
    classes: 'asw-rpt__cov',
    [
      span(classes: 'asw-rpt__covlabel', [
        Component.text(
          item.stem.isEmpty
              ? 'No wording recorded — the generator abstained on this candidate.'
              : item.stem,
        ),
      ]),
      StatusBadge(
        item.isMeasured ? 'Measured' : 'Not measured',
        tone: item.isMeasured ? 'success' : 'warning',
      ),
      span(classes: 'asw-rpt__covreason', [
        Component.text('Stage: ${_stageLabel(item.admissionStage)}'),
      ]),
      span(classes: 'asw-rpt__covreason', [
        Component.text(
          'Objective ${item.objectiveId ?? 'not recorded'} · review '
          '${item.reviewDecision ?? 'not recorded'} · measurement level '
          '${item.measurementLevel ?? 'unestablished'} · denominator '
          '${item.denominator ?? 'unestablished'}',
        ),
      ]),
      if (item.options.isNotEmpty)
        span(classes: 'asw-rpt__covreason', [
          Component.text('Options: ${item.options.join(' · ')}'),
        ]),
      if (item.ownerIntendedOptions.isNotEmpty)
        span(classes: 'asw-rpt__covreason', [
          Component.text(
            'Your intended answer (not a respondent answer): '
            '${item.ownerIntendedOptions.join(', ')}',
          ),
        ]),
    ],
  );

  /// The stage vocabulary, said in words. An unknown token is shown as
  /// "unrecognised" rather than guessed at.
  static String _stageLabel(String? stage) => switch (stage) {
    'CANDIDATE_PRESENTED' => 'candidate presented, no review decision',
    'CANDIDATE_ABSTAINED' => 'generator abstained — there is no question to field',
    'CANDIDATE_REJECTED' => 'rejected at review',
    'CANDIDATE_SUBMITTED_FOR_REVIEW' => 'submitted for review, not admitted',
    'OBJECTIVE_ADMITTED' => 'admitted as a research objective',
    'QUESTION_APPROVED' => 'approved into the questionnaire',
    'QUESTION_RELEASED' => 'in a released questionnaire',
    'MEASURED' => 'measured',
    _ => 'unrecognised stage',
  };

  List<Component> _evidence() {
    final checks = report.requirementMatching;
    final groups = report.evidenceGroups;
    final association = report.researchAssociation.asMap;
    final explanation = report.explanation.asMap;

    return [
      _card(
        icon: 'travel_explore',
        title: 'Measured location evidence',
        trailing: Pill(
          report.evidenceCategories.available ? 'Coverage only' : 'Unavailable',
          tone: report.evidenceCategories.available ? 'neutral' : 'warning',
        ),
        children: [
          if (groups.isEmpty)
            _emptyInline(
              report.evidenceCategories.reason ??
                  'No analysed location evidence exists for this property.',
            )
          else
            div(classes: 'asw-rpt__coveragebars', [
              for (final group in groups) _coverageMetric(group),
            ]),
        ],
      ),
      details(
        classes: 'asw-rpt__disclosure',
        attributes: const {'open': ''},
        [
          summary(classes: 'asw-rpt__disclosuresummary', [
            span([Component.text('Requirement checks & scoring contract status')]),
            span(classes: 'asw-rpt__chevron', [Component.text('⌄')]),
          ]),
          div(classes: 'asw-rpt__disclosurebody', [
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
            div(classes: 'asw-rpt__contract', [
              Pill('Overall suitability: Not established', tone: 'warning'),
              h4([Component.text('Scoring contract')]),
              p([
                Component.text(
                  checks.note.isEmpty
                      ? 'No approved scoring contract is attached to this report.'
                      : checks.note,
                ),
              ]),
              p([
                Component.text(
                  'The research index below is a match-to-business-type value, '
                  'not a probability of success.',
                ),
              ]),
            ]),
          ]),
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
      p(classes: 'asw-rpt__footnote', [
        Component.text(
          'Coverage and requirement checks are separate facts. A filled bar '
          'never means the location is suitable, and an unavailable source '
          'is never shown as a measured zero.',
        ),
      ]),
    ];
  }

  /// One measured-evidence bar. The count is taken from the payload only; a
  /// group with no measured values gets an explicit unavailable treatment
  /// instead of a zero-width bar that could be read as a real result.
  Component _coverageMetric(Map<String, dynamic> group) {
    final label = '${group['label'] ?? group['key'] ?? 'Group'}';
    final measured = AssessmentReportPayload.measuredMetrics(group);
    final total = AssessmentReportPayload.totalMetrics(group);
    final percent = total == 0 ? 0 : (measured * 100 / total).round();
    final tone = total == 0 || measured == 0
        ? 'unavailable'
        : measured >= total
            ? 'success'
            : 'warning';
    final note = tone == 'success'
        ? 'Metrics present; not a suitability verdict.'
        : tone == 'warning'
            ? 'Partial coverage · the remaining metrics were not measured.'
            : 'No measured values are available for this group.';

    return div(classes: 'asw-rpt__cm', [
      div(classes: 'asw-rpt__cmtop', [
        span(classes: 'asw-rpt__cmlabel', [Component.text(label)]),
        span(classes: 'asw-rpt__cmvalue', [
          Component.text(tone == 'unavailable' ? 'Not captured' : '$measured / $total'),
        ]),
      ]),
      div(
        classes: tone == 'unavailable'
            ? 'asw-rpt__cmtrack asw-rpt__cmtrack--unavailable'
            : 'asw-rpt__cmtrack',
        attributes: {
          'role': 'img',
          'aria-label': tone == 'unavailable'
              ? '$label: no measured values available'
              : '$label: $measured of $total metrics measured',
        },
        tone == 'unavailable'
            ? const []
            : [
                div(
                  classes: 'asw-rpt__cmfill asw-rpt__cmfill--$tone',
                  attributes: {'style': 'width: $percent%'},
                  [],
                ),
              ],
      ),
      p(
        classes: tone == 'success'
            ? 'asw-rpt__cmnote'
            : 'asw-rpt__cmnote asw-rpt__cmnote--$tone',
        [Component.text(note)],
      ),
    ]);
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
    final composed = composition;
    return [
      if (composed != null)
        _card(
          icon: 'fact_check',
          title: 'Composed section availability',
          trailing: Pill('${composed.sections.length}', tone: 'neutral'),
          children: [
            div(classes: 'table-scroll', [
              table(classes: 'asw-rpt__table', [
                thead([
                  tr([
                    th([Component.text('#')]),
                    th([Component.text('Section')]),
                    th([Component.text('State')]),
                    th([Component.text('Reason')]),
                  ]),
                ]),
                tbody([
                  for (final section in composed.sections)
                    tr([
                      td([Component.text(section.index)]),
                      td([Component.text(section.title)]),
                      td([
                        StatusBadge(
                          _availabilityLabel(section.availability),
                          tone: _availabilityTone(section.availability),
                        ),
                      ]),
                      td([Component.text(section.reasonCode)]),
                    ]),
                ]),
              ]),
            ]),
            p(classes: 'asw-rpt__note', [
              strong([Component.text('Composed by the backend: ')]),
              Component.text(
                'each state is decided from the A10 section contract, the '
                'measurement association and the confirmed business '
                'description — contract ${composed.contractVersion}. Gate '
                'identities ${composed.instrument['gate_identities_total']}, '
                'closed ${composed.instrument['gates_closed']}; decisions '
                'adopted ${composed.instrument['decisions_adopted']} of '
                '${composed.instrument['decisions_total']}.',
              ),
            ]),
            // The tally is over all nine sections, including this one. It is
            // printed from the server's own count rather than recomputed here,
            // so a client cannot disagree with the document it is showing.
            if (composed.counts.isNotEmpty)
              p(classes: 'asw-rpt__note', [
                strong([Component.text('Coverage: ')]),
                Component.text(_countsSentence(composed.counts)),
              ]),
            if (composed.revisions.isNotEmpty)
              p(classes: 'asw-rpt__note', [
                strong([Component.text('Versions: ')]),
                Component.text(_revisionsSentence(composed.revisions)),
              ]),
            if (!composed.releaseAuthorized)
              p(classes: 'asw-rpt__note', [
                strong([Component.text('Admission: ')]),
                Component.text(
                  composed.countsDisclosed
                      ? 'a measurement in this document carries its own '
                            'admission decision, so that measurement is shown. '
                            'Releasing the report as a whole is a separate act '
                            'and is not authorized.'
                      : 'no report-admission decision is adopted, so this '
                            'document composes states and sources only. It does '
                            'not publish a measurement.',
                ),
              ]),
          ],
        )
      else
        _card(
          icon: 'fact_check',
          title: 'Composed section availability',
          trailing: const Pill('Not read', tone: 'warning'),
          children: [
            p(classes: 'asw-rpt__note', [
              Component.text(
                'The backend composition could not be read for this report, so '
                'the section states below are derived from the report payload '
                'alone. That is a degraded view, not an empty report.',
              ),
            ]),
          ],
        ),
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
          'The payload rows are computed from this read, not from a frozen '
          'snapshot: the report is assembled each time it is opened.',
        ),
      ]),
    ];
  }

  /// "1 available, 4 administrative, 1 pending, 1 withheld, 1 unavailable,
  /// 1 not applicable" — only the states that occur, so a zero is never read as
  /// a finding.
  static String _countsSentence(Map<String, dynamic> counts) {
    const labels = <String, String>{
      SectionAvailability.available: 'available',
      SectionAvailability.administrative: 'administrative',
      SectionAvailability.partial: 'partial',
      SectionAvailability.pending: 'pending measurement',
      SectionAvailability.withheld: 'withheld',
      SectionAvailability.unavailable: 'unavailable',
      SectionAvailability.notApplicable: 'not applicable',
    };
    final parts = <String>[];
    var total = 0;
    for (final entry in labels.entries) {
      final count = (counts[entry.key] as num?)?.toInt() ?? 0;
      total += count;
      if (count > 0) parts.add('$count ${entry.value}');
    }
    if (parts.isEmpty) return 'no sections counted';
    return 'of $total sections, ${parts.join(', ')}.';
  }

  /// The two numbers a reader would otherwise reconcile by eye.
  static String _revisionsSentence(Map<String, dynamic> revisions) {
    final form = revisions['marketplace_requirements_form_version'];
    final confirmation = revisions['m2_confirmation_revision'];
    return 'business-description form version ${form ?? '—'} (a form-schema '
        'generation marker, not a revision counter); research record confirmed '
        'at revision ${confirmation ?? '—'}.';
  }

  /// Human label for a composed state. The wire token is never printed as-is.
  static String _availabilityLabel(String availability) => switch (availability) {    SectionAvailability.available => 'Available',
    SectionAvailability.administrative => 'Administrative',
    SectionAvailability.partial => 'Partial',
    SectionAvailability.pending => 'Pending',
    SectionAvailability.withheld => 'Withheld',
    SectionAvailability.notApplicable => 'Not applicable',
    _ => 'Unavailable',
  };

  static String _availabilityTone(String availability) => switch (availability) {
    SectionAvailability.available => 'success',
    SectionAvailability.administrative => 'neutral',
    SectionAvailability.partial => 'neutral',
    SectionAvailability.pending => 'neutral',
    SectionAvailability.withheld => 'warning',
    SectionAvailability.notApplicable => 'neutral',
    _ => 'warning',
  };

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

  /// An identifier shortened for prose. A full UUID in a sentence pushes the
  /// meaning off the line; the first twelve characters are enough to recognise
  /// a value a reader can look up in full elsewhere.
  static String _short(Object? value) {
    if (value is! String || value.isEmpty) return '—';
    return value.length <= 12 ? value : '${value.substring(0, 12)}…';
  }

  static String _date(String? iso) {
    if (iso == null || iso.length < 16) return 'just now';
    return iso.substring(0, 16).replaceFirst('T', ' ');
  }
}
