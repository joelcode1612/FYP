import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import 'report_template_sections.dart';

/// Read-only, version-pinned view data prepared by the existing report API.
/// A UI flag is not authorization; the backend must enforce A10 admission.
class CafeReportSnapshot {
  final String businessName;
  final String assessmentId;
  final String snapshotId;
  final String evidenceCutoff;
  final bool admitted;
  final String concept;
  final String productsAndServices;
  final String targetCustomers;
  final String? uncertaintySummary;
  final String? admittedVisitingInterest;
  final Map<String, ReportSectionContent> sections;

  const CafeReportSnapshot({
    required this.businessName,
    required this.assessmentId,
    required this.snapshotId,
    required this.evidenceCutoff,
    required this.admitted,
    required this.concept,
    required this.productsAndServices,
    required this.targetCustomers,
    this.uncertaintySummary,
    this.admittedVisitingInterest,
    this.sections = const {},
  });
}

/// Server-authorized display section, with each claim's actual gate recorded.
/// Do not insert unadmitted findings as authorized text.
class ReportSectionContent {
  final String heading;
  final List<ReportContentBlock> blocks;
  const ReportSectionContent({required this.heading, required this.blocks});
}

class ReportContentBlock {
  final String title;
  final String body;
  final bool claimAdmitted;
  final String? claimId;
  final String? sourceOrMeasurementId;
  const ReportContentBlock({
    required this.title,
    required this.body,
    required this.claimAdmitted,
    this.claimId,
    this.sourceOrMeasurementId,
  });
}

/// Display names only; must not replace the canonical report field mapping.
const sitewiseReportSections = <String, String>{
  'R01': 'Business Concept and Declared Plan',
  'R02': 'Survey Recruitment, Eligibility and Consent',
  'R03': 'Stated Interest in Visiting',
  'R04': 'Interested Product Categories',
  'R05': 'Price Acceptability for an Exact Offer',
  'R06': 'Existing-Café Purchasing Behavior',
  'R07': 'Occasions and Experience Priorities',
  'R08': 'Study-Area Affiliation and Geographic Context',
  'R09': 'External Business, Competitor and Rental Context',
  'R10': 'Financial and Operational Planning Assumptions',
  'R11': 'Overall Findings, Evidence Gaps and Next Steps',
  'R12': 'Research Methods, Sources and Limitations',
};

/// Place inside the existing SITEWISE AppLayout (not another MaterialApp/root).
/// Requires client hydration for section navigation and search.
///
/// Not `@client`: it is mounted inside the `@client` route shell, and the
/// `@client` codegen rejects custom model parameters.
class CafeDemandReportPage extends StatefulComponent {
  final CafeReportSnapshot snapshot;
  final VoidCallback? onViewSources;
  final VoidCallback? onViewLogHistory;
  final VoidCallback? onExportPdf;

  const CafeDemandReportPage({
    required this.snapshot,
    this.onViewSources,
    this.onViewLogHistory,
    this.onExportPdf,
    super.key,
  });

  @override
  State<CafeDemandReportPage> createState() => _CafeDemandReportPageState();
}

class _CafeDemandReportPageState extends State<CafeDemandReportPage> {
  String _selected = 'R01';
  String _search = '';

  Component _action(String title, VoidCallback? handler, {String style = ''}) {
    return button(
      classes: 'sr-button $style',
      attributes: {'type': 'button', if (handler == null) 'disabled': ''},
      events: events(onClick: () { if (handler != null) handler(); }),
      [Component.text(title)],
    );
  }

  Component _description(String icon, String title, String body) => article(
    classes: 'sr-description-part',
    [
      span(classes: 'sr-description-icon', [Component.text(icon)]),
      div([
        h4([Component.text(title)]),
        p([Component.text(body.isEmpty ? 'Not provided in this snapshot.' : body)]),
      ]),
    ],
  );

  Component _withheld(String explanation) => div(classes: 'sr-withheld', [
    strong([Component.text('Customer finding WITHHELD')]),
    p([Component.text(explanation)]),
  ]);

  Component _identification() {
    final snap = component.snapshot;
    return section(classes: 'sr-card sr-ident', [
      h3([Component.text('Report Identification')]),
      _table(ReportTable(
        headers: const ['Field', 'Value'],
        rows: [
          ['Café concept', snap.businessName],
          ['Assessment', snap.assessmentId],
          ['Assessment revision', 'Not supplied'],
          ['Study area', 'Not supplied'],
          ['Customer research', 'Questionnaire version / availability not supplied'],
          ['Evidence cutoff', snap.evidenceCutoff],
          ['Report snapshot', snap.snapshotId],
          ['Report admission',
              snap.admitted ? 'Admitted' : 'Not admitted'],
        ],
      )),
    ]);
  }

  Component _overviewRow(String label, String value) => div(
        classes: 'sr-overview__row',
        [
          span(classes: 'sr-label', [Component.text(label)]),
          p([Component.text(value)]),
        ],
      );

  Component _overview() {
    final snap = component.snapshot;
    return section(classes: 'sr-card sr-overview', [
      h3([Component.text('Assessment Overview')]),
      _overviewRow('Business concept', snap.concept),
      _overviewRow('Available findings',
          'Only claims permitted for this viewing context are shown.'),
      _overviewRow(
        'Main unresolved questions',
        snap.uncertaintySummary ??
            'No confirmed uncertainty summary is available for this snapshot.',
      ),
      _overviewRow('Research availability',
          'Withheld, missing or not yet authorized components are recorded '
          'through their governing status records.'),
      p(classes: 'sr-overview__note', [
        strong([Component.text('Important: ')]),
        Component.text(
          'An unavailable finding is not evidence that the proposed business '
          'will fail.',
        ),
      ]),
    ]);
  }

  Component _table(ReportTable data) => div(classes: 'sr-table-wrap', [
        table(classes: 'sr-table', [
          thead([
            tr([
              for (final header in data.headers)
                th([Component.text(header)]),
            ]),
          ]),
          tbody([
            for (final row in data.rows)
              tr([
                for (final cell in row) td([Component.text(cell)]),
              ]),
          ]),
        ]),
      ]);

  Component _subBlock(ReportSub sub) => section(classes: 'sr-sub', [
        h4(classes: 'sr-sub__head', [
          span(classes: 'sr-sub__code', [Component.text(sub.code)]),
          span([Component.text(' ${sub.title}')]),
        ]),
        if (sub.unavailable != null)
          div(classes: 'sr-unavailable', [Component.text(sub.unavailable!)]),
        for (final paragraph in sub.paragraphs)
          p([Component.text(paragraph)]),
        if (sub.bullets.isNotEmpty)
          ul(classes: 'sr-bullets', [
            for (final bullet in sub.bullets)
              li([Component.text(bullet)]),
          ]),
        if (sub.table != null) _table(sub.table!),
      ]);

  Component _sectionBody(String code) {
    final matches = reportTemplate.where((item) => item.code == code);
    if (matches.isEmpty) {
      return div(classes: 'sr-unavailable', [
        Component.text('Unknown report section "$code".'),
      ]);
    }
    final template = matches.first;
    final snapshotSection = component.snapshot.sections[code];
    return div(classes: 'sr-section-body', [
      h3([Component.text('$code — ${template.title}')]),
      if (template.purpose != null)
        p(classes: 'sr-purpose', [
          strong([Component.text('Purpose: ')]),
          Component.text(template.purpose!),
        ]),
      if (code == 'R01') ...[
        h4(classes: 'sr-section-strip', [
          Component.text('1.1 Business Description'),
        ]),
        _description('☕', 'A. Café Concept', component.snapshot.concept),
        _description('♜', 'B. Products and Service Format',
            component.snapshot.productsAndServices),
        _description('♧', 'C. Intended Customers and Differentiation',
            component.snapshot.targetCustomers),
      ],
      for (final sub in template.subs)
        if (!(code == 'R01' && sub.code == '1.1')) _subBlock(sub),
      if (snapshotSection != null)
        for (final block in snapshotSection.blocks) sectionContent(block),
      if (template.restriction != null)
        div(classes: 'sr-restriction', [
          strong([Component.text('Restriction: ')]),
          Component.text(template.restriction!),
        ]),
      if (template.footnote != null)
        p(classes: 'sr-footnote', [Component.text(template.footnote!)]),
    ]);
  }

  Component sectionContent(ReportContentBlock block) => section(
    classes: 'sr-inner-card',
    [
      h4([Component.text(block.title)]),
      if (block.claimAdmitted && component.snapshot.admitted) ...[
        p([Component.text(block.body)]),
        if (block.claimId != null)
          p(classes: 'sr-evidence-ref', [Component.text('Claim: ${block.claimId}')]),
        if (block.sourceOrMeasurementId != null)
          p(classes: 'sr-evidence-ref', [Component.text('Evidence: ${block.sourceOrMeasurementId}')]),
      ] else
        _withheld('This report claim has not been admitted for the selected snapshot.'),
    ],
  );

  @override
  Component build(BuildContext context) {
    final snap = component.snapshot;
    if (snap.assessmentId.trim().isEmpty || snap.businessName.trim().isEmpty) {
      return main_(classes: 'sr-workspace', [
        div(classes: 'sr-page-heading', [
          p(classes: 'sr-breadcrumb', [
            Component.text('Project1 › Assessment Workspace › Report'),
          ]),
          h1([Component.text('Café Demand Suitability Report')]),
        ]),
        section(classes: 'sr-card sr-missing', [
          h3([Component.text('Report record not found')]),
          p([
            Component.text(
              'No authorized report snapshot matches this assessment. An empty '
              'or unmatched record is not shown as a draft report, and no '
              'section is filled with placeholder findings.',
            ),
          ]),
          a(href: '/entrepreneur/assessments', classes: 'sr-button', [
            Component.text('Back to assessments'),
          ]),
        ]),
      ]);
    }
    final keys = sitewiseReportSections.keys.toList();
    final position = keys.indexOf(_selected);
    final matching = sitewiseReportSections.entries.where((entry) {
      final q = _search.trim().toLowerCase();
      if (q.isEmpty) return true;
      final body = snap.sections[entry.key]?.blocks.map((b) => b.claimAdmitted && snap.admitted ? b.body : '').join(' ') ?? '';
      return entry.key.toLowerCase().contains(q) ||
          entry.value.toLowerCase().contains(q) || body.toLowerCase().contains(q);
    }).toList();
    return main_(classes: 'sr-workspace', [
      div(classes: 'sr-report-header', [
        div([
          p(classes: 'sr-breadcrumb', [Component.text('Project1 › Assessment Workspace › Report')]),
          h1([Component.text('Café Demand Suitability Report')]),
          p(classes: 'sr-subtitle', [Component.text('Pre-opening evidence-based decision-support assessment.')]),
        ]),
        div(classes: 'sr-actions', [
          input<String>(
            type: InputType.text,
            classes: 'sr-search',
            attributes: {'placeholder': 'Search within report', 'aria-label': 'Search report sections and admitted text'},
            onInput: (text) => setState(() => _search = text),
          ),
          _action('View sources', component.onViewSources),
          _action('View log history', component.onViewLogHistory),
          _action('Export PDF', snap.admitted ? component.onExportPdf : null),
        ]),
      ]),
      section(classes: 'sr-card sr-metadata', [
        div(classes: 'sr-business-title', [
          h3([Component.text(snap.businessName)]),
          p([Component.text('Location assessment · Café demand suitability report')]),
        ]),
        _datum('Assessment', snap.assessmentId),
        _datum('Report snapshot', snap.snapshotId),
        _datum('Evidence cutoff', snap.evidenceCutoff),
        _datum('Report admission', snap.admitted ? 'Admitted' : 'Not admitted'),
      ]),
      div(classes: 'sr-notice', [
        strong([Component.text('Overall business viability: Not established.')]),
        Component.text(' Individual findings require authorized evidence and claim-level admission.'),
      ]),
      _identification(),
      _overview(),
      div(classes: 'sr-report-grid', [
        nav(classes: 'sr-card sr-report-nav', [
          h3([Component.text('Report Sections (R01–R12)')]),
          for (final entry in matching)
            button(
              classes: _selected == entry.key ? 'sr-section-item selected' : 'sr-section-item',
              attributes: {'type': 'button', 'aria-current': _selected == entry.key ? 'page' : 'false'},
              events: events(onClick: () => setState(() => _selected = entry.key)),
              [strong([Component.text(entry.key)]), span([Component.text(entry.value)])],
            ),
          if (matching.isEmpty) p([Component.text('No matching report sections.')]),
        ]),
        article(classes: 'sr-card sr-report-main', [
          div(classes: 'sr-content-toolbar', [
            strong([Component.text('${position + 1} of ${keys.length}')]),
            div(classes: 'sr-actions', [
              _action('Previous', position > 0 ? () => setState(() => _selected = keys[position - 1]) : null),
              _action('Next', position < keys.length - 1 ? () => setState(() => _selected = keys[position + 1]) : null),
            ]),
          ]),
          _sectionBody(_selected),
        ]),
      ]),
      section(classes: 'sr-card sr-appendices', [
        h3([Component.text('Appendices')]),
        for (final appendix in reportAppendices)
          div(classes: 'sr-appendix', [
            strong([Component.text('Appendix ${appendix.code} — ${appendix.title}')]),
            p([Component.text(appendix.note)]),
          ]),
      ]),
      p(classes: 'sr-footnote', [Component.text('Report template view only. UI permissions and button states are not substitutes for server-side report admission.')]),
    ]);
  }

  Component _datum(String label, String value) => div(classes: 'sr-field', [
    span(classes: 'sr-label', [Component.text(label)]),
    strong([Component.text(value)]),
  ]);
}
