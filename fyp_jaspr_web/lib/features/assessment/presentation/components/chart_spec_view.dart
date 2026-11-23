import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import 'package:sitewise_jaspr_web/features/assessment/data/chart_spec.dart';
import 'package:sitewise_jaspr_web/shared/presentation/components/ui.dart';

/// Horizontal-bar renderer for one `chart-spec/1` measurement line.
///
/// Deliberately a plain component rather than an `@client` one: Jaspr cannot
/// serialize a [ChartSpecModel] as an `@client` constructor parameter. It is
/// mounted beneath primitive-parameter `@client` pages instead.
///
/// Governance rules enforced here, not in the caller:
///
/// * A bar is drawn only when the backend said `RENDERABLE`, or when it said
///   `SYNTHETIC_PREVIEW_ONLY` — the development-only demonstration state. Every
///   other state renders its own notice, so a withheld finding cannot appear as
///   a chart with a shorter bar or a missing label.
/// * A `SYNTHETIC_PREVIEW_ONLY` chart always carries
///   [syntheticPreviewBannerText] above the bars. The banner is not optional and
///   not suppressible: it is the only thing distinguishing a demonstration from
///   a finding at a glance.
/// * Percentages are printed from [ChartOptionModel.percentageText], which is
///   the backend's decimal string. Nothing is recomputed from counts, and a
///   null percentage prints as "withheld" rather than `0%`.
/// * The bars are decorative (`aria-hidden`); the adjacent table is the
///   accessible representation, so screen-reader users get the exact figures
///   once instead of a duplicated reading.
/// * The limitations list is mandatory and always rendered.
class ChartSpecView extends StatelessComponent {
  final ChartSpecModel spec;

  /// Extra note shown under the chart, e.g. a section-level caveat.
  final String? note;

  /// The banner text a synthetic demonstration must display. Exposed as a
  /// constant so tests can assert the rendered surface contains it verbatim.
  static const String syntheticPreviewBannerText =
      'SYNTHETIC DEMONSTRATION — NOT REPORT EVIDENCE';

  const ChartSpecView({super.key, required this.spec, this.note});

  @override
  Component build(BuildContext context) {
    final headingId = 'chart-${spec.chartId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '-')}';
    return figure(
      classes: 'sw-chart${spec.isSyntheticPreview ? ' sw-chart--synthetic' : ''}',
      attributes: {'aria-labelledby': headingId},
      [
        figcaption(classes: 'sw-chart__head', [
          div(classes: 'sw-chart__eyebrow', [
            ...spec.reportSections.map((sectionId) => Pill(sectionId)),
            Pill(_responseKindLabel(spec.responseKind)),
            if (spec.isSyntheticPreview) const Pill('Synthetic preview', tone: 'warning'),
            if (spec.admission.isHeld) const Pill('Not report-admissible', tone: 'warning'),
          ]),
          h3(attributes: {'id': headingId}, [Component.text(spec.title)]),
          p(classes: 'sw-chart__question', [Component.text(spec.questionText)]),
        ]),
        if (spec.isSyntheticPreview) _syntheticBanner(),
        if (spec.renderState.disclosesCounts) _bars() else _notice(),
        _table(),
        if (spec.derivedLines.isNotEmpty) _derived(),
        p(classes: 'sw-chart__denominator', [
          Component.text('Denominator — ${spec.denominatorScope}. '),
          // The number only. `denominatorScope` is a mandatory contract field
          // and already says what V counts, so repeating "substantive answers"
          // here would contradict it for any item whose V includes valid
          // answers that select no substantive code — Q01's exclusive
          // terminals are exactly that case.
          Component.text('V = ${spec.measurement.substantive}.'),
        ]),
        _limitations(),
        div(classes: 'sw-chart__foot', [
          _footItem('Question', '${spec.questionId} · ${spec.questionVersion}'),
          _footItem('Construct', spec.constructId),
          _footItem('Cohort', spec.cohortScope),
          _footItem('Cutoff', _date(spec.cutoff)),
          if (spec.admission.gates.isNotEmpty)
            _footItem('Open gates', spec.admission.gates.join(' · ')),
          if (note != null) p(classes: 'sw-chart__note', [Component.text(note!)]),
        ]),
      ],
    );
  }

  /// Non-dismissible banner. Rendered above the bars so it is read before the
  /// geometry, and repeated as the figure's accessible description.
  Component _syntheticBanner() => div(
    classes: 'sw-chart__synthetic-banner',
    attributes: {'role': 'note'},
    [
      Icon('science', size: 'lg'),
      div(classes: 'sw-chart__synthetic-body', [
        p(classes: 'sw-chart__synthetic-title', [
          Component.text(syntheticPreviewBannerText),
        ]),
        p(classes: 'sw-chart__synthetic-text', [
          Component.text(
            'These figures come from a synthetic fixture, not from a fielded '
            'response. The line is held: it is not admitted into R02 or R08 and '
            'must not be cited as a finding.',
          ),
        ]),
      ]),
    ],
  );

  // ---------------------------------------------------------------------
  // Bars
  // ---------------------------------------------------------------------

  Component _bars() {
    final maxCount = spec.maxCount;
    final top = spec.highestOptions.toSet();
    return div(classes: 'sw-chart__bars', attributes: {'aria-hidden': 'true'}, [
      for (final option in spec.options)
        div(classes: 'sw-chart__bar${top.contains(option.code) ? ' is-top' : ''}', [
          span(classes: 'sw-chart__bar-label', [Component.text(option.displayLabel)]),
          span(classes: 'sw-chart__bar-track', [
            span(
              classes: 'sw-chart__bar-fill',
              attributes: {'style': 'width:${_width(option.count, maxCount)}'},
              const [],
            ),
          ]),
          span(classes: 'sw-chart__bar-count', [Component.text('${option.count}')]),
          span(classes: 'sw-chart__bar-pct', [Component.text(_percentage(option))]),
        ]),
    ]);
  }

  /// Bar length is scaled against the largest count in this chart, matching the
  /// existing `.sw-viz__bar` convention: the geometry is readable, the printed
  /// figure is the real one. Geometry is never the evidence.
  String _width(int count, int maxCount) {
    if (maxCount <= 0 || count <= 0) return '0%';
    final pct = (count / maxCount) * 100;
    return '${pct.clamp(1.5, 100).toStringAsFixed(2)}%';
  }

  String _percentage(ChartOptionModel option) {
    final text = option.percentageText;
    if (text == null) return '—';
    return '${_trimZeros(text)}%';
  }

  /// Trims trailing zeros only. No re-rounding: the backend's decimal string is
  /// the value, and shortening `24.0000` to `24` changes nothing it asserted.
  String _trimZeros(String value) {
    if (!value.contains('.')) return value;
    var out = value;
    while (out.endsWith('0')) {
      out = out.substring(0, out.length - 1);
    }
    if (out.endsWith('.')) out = out.substring(0, out.length - 1);
    return out.isEmpty ? '0' : out;
  }

  // ---------------------------------------------------------------------
  // Non-renderable states
  // ---------------------------------------------------------------------

  Component _notice() {
    final (String icon, String title, String body) = switch (spec.renderState) {
      ChartRenderState.notShown => (
        'visibility_off',
        'Not shown',
        'Routing prevented display to any eligible unit, so no distribution exists. '
            'This is an absence of display, not a result of zero.',
      ),
      ChartRenderState.notEstimable => (
        'functions',
        'Not estimable',
        'V = 0 at this cutoff: no substantive answers, so no percentage exists. '
            'A zero denominator is never rendered as 0%.',
      ),
      ChartRenderState.withheldNotAuthorized => (
        'lock',
        'Findings withheld',
        'The measurement exists, but no authorized report source is adopted. '
            'Counts and percentages are withheld rather than estimated.',
      ),
      ChartRenderState.unavailableMissingApprovedStimulus => (
        'block',
        'Unavailable',
        'The required approved stimulus does not exist, so this section cannot be measured.',
      ),
      ChartRenderState.unauthorizedClaim => (
        'gpp_bad',
        'Not authorized',
        'The claim is not authorized and must not be rendered.',
      ),
      ChartRenderState.renderable => ('info', 'Available', ''),
      // Unreachable through [build]: a disclosing state draws bars instead. The
      // case exists so the switch stays exhaustive, and it says what it is
      // rather than pretending to be a finding.
      ChartRenderState.syntheticPreviewOnly => (
        'science',
        'Synthetic demonstration',
        'Figures come from a synthetic fixture and are not report evidence.',
      ),
    };
    return div(classes: 'sw-chart__notice', attributes: {'role': 'status'}, [
      Icon(icon, size: 'lg'),
      div(classes: 'sw-chart__notice-body', [
        p(classes: 'sw-chart__notice-title', [Component.text(title)]),
        p(classes: 'sw-chart__notice-text', [Component.text(body)]),
      ]),
    ]);
  }

  // ---------------------------------------------------------------------
  // Accessible table
  // ---------------------------------------------------------------------

  Component _table() {
    final disclosesCounts = spec.renderState.disclosesCounts;
    return table(classes: 'sw-chart__table', [
      caption([
        Component.text(
          '${spec.title}. Counts and '
          '${disclosesCounts ? 'percentages' : 'status'} for ${spec.questionId}.',
        ),
      ]),
      thead([
        tr([
          th(attributes: {'scope': 'col'}, [Component.text('Option')]),
          if (spec.responseKind == ChartResponseKind.ordinal)
            th(attributes: {'scope': 'col'}, [Component.text('Ordinal')]),
          th(attributes: {'scope': 'col'}, [Component.text('Count')]),
          th(attributes: {'scope': 'col'}, [
            Component.text(disclosesCounts ? 'Share of V' : 'Status'),
          ]),
        ]),
      ]),
      tbody([
        for (final option in spec.options)
          tr([
            th(attributes: {'scope': 'row'}, [Component.text(option.displayLabel)]),
            if (spec.responseKind == ChartResponseKind.ordinal)
              td([
                Component.text(option.ordinalValue?.toString() ?? '—'),
              ]),
            td([
              Component.text(disclosesCounts ? '${option.count}' : 'withheld'),
            ]),
            td([
              Component.text(disclosesCounts ? _percentage(option) : _statusCell(option)),
            ]),
          ]),
      ]),
    ]);
  }

  /// When the chart is not renderable the count is not disclosed either: a
  /// withheld finding is not partially published.
  String _statusCell(ChartOptionModel option) => switch (option.percentageStatus) {
    ChartPercentageStatus.estimable => '—',
    ChartPercentageStatus.notEstimable => 'not estimable',
    ChartPercentageStatus.withheldNotAuthorized => 'withheld',
    ChartPercentageStatus.notShown => 'not shown',
    ChartPercentageStatus.syntheticPreviewEstimable => 'synthetic preview',
  };

  // ---------------------------------------------------------------------
  // Derived aggregates, limitations, footer
  // ---------------------------------------------------------------------

  Component _derived() {
    final disclosesCounts = spec.renderState.disclosesCounts;
    return div(classes: 'sw-chart__derived', [
      p(classes: 'sw-chart__derived-head', [Component.text('Predeclared aggregate')]),
      for (final line in spec.derivedLines)
        div(classes: 'sw-chart__derived-row', [
          span(classes: 'sw-chart__derived-label', [Component.text(line.displayLabel)]),
          span(classes: 'sw-chart__derived-value', [
            Component.text(
              disclosesCounts
                  ? '${line.count} · ${line.percentageText == null ? '—' : '${_trimZeros(line.percentageText!)}%'}'
                  : 'withheld',
            ),
          ]),
          span(classes: 'sw-chart__derived-formula', [
            Component.text(
              '${line.numeratorCodes.join(' + ')}${line.formula.isEmpty ? '' : ' — ${line.formula}'}',
            ),
          ]),
        ]),
    ]);
  }

  Component _limitations() => div(classes: 'sw-chart__limits', [
    p(classes: 'sw-chart__limits-head', [Component.text('Limitations')]),
    ul([
      for (final limitation in spec.limitations)
        li([Component.text(limitation)]),
    ]),
  ]);

  Component _footItem(String label, String value) => div(classes: 'sw-chart__foot-item', [
    span(classes: 'sw-chart__foot-label', [Component.text(label)]),
    span(classes: 'sw-chart__foot-value', [Component.text(value)]),
  ]);

  static String _responseKindLabel(ChartResponseKind kind) => switch (kind) {
    ChartResponseKind.singleSelect => 'Single select',
    ChartResponseKind.multiSelect => 'Multi select',
    ChartResponseKind.ordinal => 'Ordinal',
  };

  static String _date(DateTime value) {
    final iso = value.toUtc().toIso8601String();
    return '${iso.substring(0, 10)} ${iso.substring(11, 16)} UTC';
  }
}
