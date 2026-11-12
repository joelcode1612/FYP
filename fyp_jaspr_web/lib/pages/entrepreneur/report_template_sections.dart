// R01–R12 report template structure (Proposed V1.1, pending Owner and
// scientific review). Titles, sub-section codes and table headers are taken
// from the supplied template; body text is either snapshot content or an
// explicit "not available" note — never an invented finding.

class ReportTable {
  final List<String> headers;
  final List<List<String>> rows;
  const ReportTable({required this.headers, required this.rows});
}

class ReportSub {
  final String code;
  final String title;
  final List<String> paragraphs;
  final List<String> bullets;
  final ReportTable? table;
  final String? unavailable;

  const ReportSub({
    required this.code,
    required this.title,
    this.paragraphs = const [],
    this.bullets = const [],
    this.table,
    this.unavailable,
  });
}

class ReportSectionTemplate {
  final String code;
  final String title;
  final String? purpose;
  final List<ReportSub> subs;
  final String? restriction;
  final String? footnote;

  const ReportSectionTemplate({
    required this.code,
    required this.title,
    required this.subs,
    this.purpose,
    this.restriction,
    this.footnote,
  });
}

const String _pending = 'Not available in this report snapshot.';

const List<ReportSectionTemplate> reportTemplate = [
  ReportSectionTemplate(
    code: 'R01',
    title: 'Business Concept and Declared Plan',
    subs: [
      ReportSub(
        code: '1.1',
        title: 'Business Description',
        paragraphs: [
          'A. Café Concept — from the entrepreneur-authored M2-04 description.',
          'B. Products and Service Format — declared beverage/food categories and '
              'dine-in/takeaway format.',
          'C. Intended Customers and Differentiation — entrepreneur-stated target '
              'groups, labelled as assumptions where unverified.',
        ],
        unavailable: 'The three-section description is shown from the report '
            'snapshot when supplied.',
      ),
      ReportSub(
        code: '1.2',
        title: 'Business Understanding',
        unavailable: _pending,
      ),
      ReportSub(
        code: '1.3',
        title: 'Identified Uncertainties',
        table: ReportTable(
          headers: ['Uncertainty', 'Origin', 'Confirmation', 'Research route'],
          rows: [
            ['Breakfast takeaway interest', 'M2 / BDJ (M2-12, M2-13, M2-14)',
                'Pending', 'QL research recommended (not scientifically approved)'],
          ],
        ),
      ),
      ReportSub(
        code: '1.4',
        title: 'Outstanding Clarifications',
        unavailable: _pending,
      ),
    ],
  ),
  ReportSectionTemplate(
    code: 'R02',
    title: 'Survey Recruitment, Eligibility and Consent',
    purpose: 'Explain who participated and how evidence was collected.',
    subs: [
      ReportSub(
        code: '2.1',
        title: 'Study population and recruitment',
        bullets: [
          'Study population: to be supplied from the authorized study design.',
          'Recruitment method: to be supplied.',
          'Collection period: to be supplied.',
        ],
        unavailable: 'No participation records have been authorized for this '
            'snapshot. Participant counts are never inferred.',
      ),
      ReportSub(
        code: '2.2',
        title: 'Eligibility, consent and limitations',
        paragraphs: [
          'Eligibility and consent rules, participation records (I/Q/S/A/V) and '
          'sampling / nonresponse limitations are supplied only from the '
          'governing records.',
        ],
      ),
    ],
    footnote:
        'The R02 scope remains subject to reconciliation with the authoritative '
        'A10 mapping.',
  ),
  ReportSectionTemplate(
    code: 'R03',
    title: 'Stated Interest in Visiting',
    subs: [
      ReportSub(
        code: '3.1',
        title: 'Research Question',
        unavailable: _pending,
      ),
      ReportSub(
        code: '3.2',
        title: 'Customer Findings',
        unavailable: 'No authorized stated-interest measurement is available.',
      ),
      ReportSub(
        code: '3.3',
        title: 'Explanation',
        unavailable: _pending,
      ),
      ReportSub(
        code: '3.4',
        title: 'Limitations',
        paragraphs: [
          'Stated intention is not actual visits, purchases or population demand.',
        ],
      ),
      ReportSub(
        code: '3.5',
        title: 'Evidence',
        paragraphs: [
          'Q05/version → stimulus → EE-01 snapshot → claim/admission references.',
        ],
      ),
    ],
  ),
  ReportSectionTemplate(
    code: 'R04',
    title: 'Interested Product Categories',
    subs: [
      ReportSub(
        code: '4.1',
        title: 'Products Evaluated',
        unavailable: _pending,
      ),
      ReportSub(
        code: '4.2',
        title: 'Customer Preferences',
        unavailable: 'No approved per-category counts are available.',
      ),
      ReportSub(
        code: '4.3',
        title: 'Interpretation',
        paragraphs: [
          'Sample-based stated category interest only — not a predicted sales mix.',
        ],
      ),
      ReportSub(
        code: '4.4',
        title: 'Evidence and Limitations',
        unavailable: _pending,
      ),
    ],
  ),
  ReportSectionTemplate(
    code: 'R05',
    title: 'Price Acceptability for an Exact Offer',
    subs: [
      ReportSub(
        code: '5.1',
        title: 'Offer Evaluated',
        table: ReportTable(
          headers: ['Attribute', 'Value'],
          rows: [
            ['Product', '—'],
            ['Size', '—'],
            ['Quantity', '—'],
            ['Fulfilment', '—'],
            ['Charges', '—'],
            ['Price', '—'],
          ],
        ),
        unavailable: 'No exact offer stimulus has been approved for this snapshot.',
      ),
      ReportSub(
        code: '5.2',
        title: 'Customer Price-Acceptability Findings',
        unavailable: 'No approved valid-response distribution is available.',
      ),
      ReportSub(
        code: '5.3',
        title: 'Explanation',
        unavailable: _pending,
      ),
      ReportSub(
        code: '5.4',
        title: 'Limitations',
        paragraphs: [
          'Price acceptability does not establish purchase conversion, optimized '
          'pricing or profitability.',
        ],
      ),
    ],
    footnote:
        'Do not replace this result with an entrepreneur’s general price band.',
  ),
  ReportSectionTemplate(
    code: 'R06',
    title: 'Existing-Café Purchasing Behavior',
    subs: [
      ReportSub(
        code: '6.1',
        title: 'Reported Previous Café Use',
        unavailable: _pending,
      ),
      ReportSub(
        code: '6.2',
        title: 'Explanation',
        paragraphs: [
          'Only what surveyed respondents reported about existing cafés.',
        ],
      ),
      ReportSub(
        code: '6.3',
        title: 'Limitations',
        paragraphs: [
          'Recall limitations apply; this is distinct from future visits to the '
          'proposed café.',
        ],
      ),
    ],
  ),
  ReportSectionTemplate(
    code: 'R07',
    title: 'Occasions and Experience Priorities',
    subs: [
      ReportSub(
        code: '7.1',
        title: 'Reported Café-Visit Occasions',
        unavailable: _pending,
      ),
      ReportSub(
        code: '7.2',
        title: 'Experience and Feature Priorities',
        unavailable: _pending,
      ),
      ReportSub(
        code: '7.3',
        title: 'Explanation and Limitations',
        paragraphs: [
          'Past café behavior, intended occasions and hypothetical preferences '
          'are kept distinct.',
        ],
      ),
    ],
  ),
  ReportSectionTemplate(
    code: 'R08',
    title: 'Study-Area Affiliation and Geographic Context',
    subs: [
      ReportSub(
        code: '8.1',
        title: 'Study-Area Definition',
        unavailable: _pending,
      ),
      ReportSub(
        code: '8.2',
        title: 'Respondent Area Relationships',
        unavailable: _pending,
      ),
      ReportSub(
        code: '8.3',
        title: 'Geographic Context for Rental Candidates',
        unavailable: _pending,
      ),
      ReportSub(
        code: '8.4',
        title: 'Limitations',
        paragraphs: [
          'Area affiliation is not measured footfall, travel distance or a '
          'proven customer catchment.',
        ],
      ),
    ],
  ),
  ReportSectionTemplate(
    code: 'R09',
    title: 'External Business, Competitor and Rental Context',
    subs: [
      ReportSub(
        code: '9.1',
        title: 'Verified External Research',
        table: ReportTable(
          headers: [
            'Finding',
            'Publisher/source',
            'Period',
            'Verification',
            'Limitation',
          ],
          rows: [
            ['—', '—', '—', '—', '—'],
          ],
        ),
        unavailable: 'No verified external findings are attached to this snapshot.',
      ),
      ReportSub(
        code: '9.2',
        title: 'Competitor Context',
        unavailable: _pending,
      ),
      ReportSub(
        code: '9.3',
        title: 'Rental Options and Evidence',
        table: ReportTable(
          headers: [
            'Candidate',
            'Rental information',
            'Area evidence',
            'Competitor evidence',
            'Unresolved information',
          ],
          rows: [
            ['Property A', '—', '—', '—', '—'],
            ['Property B', '—', '—', '—', '—'],
          ],
        ),
      ),
      ReportSub(
        code: '9.4',
        title: 'Property-Specific Considerations',
        unavailable: _pending,
      ),
    ],
    restriction:
        'No overall property ranking, footfall advantage or lease recommendation '
        'is implied without an approved decision method and supporting evidence.',
  ),
  ReportSectionTemplate(
    code: 'R10',
    title: 'Financial and Operational Planning Assumptions',
    subs: [
      ReportSub(
        code: '10.1',
        title: 'Entrepreneur-Declared Financial Inputs',
        unavailable: _pending,
      ),
      ReportSub(
        code: '10.2',
        title: 'Rental Expense Context',
        unavailable: _pending,
      ),
      ReportSub(
        code: '10.3',
        title: 'Available Calculation or Scenario',
        unavailable: 'No calculation method is authorized for this snapshot.',
      ),
      ReportSub(
        code: '10.4',
        title: 'Missing Information',
        bullets: [
          'Costs, quantities, financing terms and timing required for a valid '
              'calculation are recorded as missing until supplied.',
        ],
      ),
    ],
    restriction:
        'No unsupported profit, cash-flow, break-even or viability estimates are '
        'presented.',
    footnote: 'The authoritative R10 field mapping must be reconciled before adoption.',
  ),
  ReportSectionTemplate(
    code: 'R11',
    title: 'Overall Findings, Evidence Gaps and Next Steps',
    subs: [
      ReportSub(
        code: '11.1',
        title: 'Supported Findings',
        unavailable: _pending,
      ),
      ReportSub(
        code: '11.2',
        title: 'Unresolved Business Questions',
        unavailable: _pending,
      ),
      ReportSub(
        code: '11.3',
        title: 'Recommended Evidence-Gathering Actions',
        paragraphs: [
          'Actions are limited to missing-information requirements, such as '
          'clarifying a rental quotation or conducting separately authorized '
          'customer research.',
        ],
      ),
      ReportSub(
        code: '11.4',
        title: 'Overall Suitability Availability',
        paragraphs: [
          'Overall café viability has not been established unless an approved '
          'and validated overall decision model is available.',
          'No automatic overall suitability score, rental ranking or success '
          'prediction is implied.',
        ],
      ),
    ],
  ),
  ReportSectionTemplate(
    code: 'R12',
    title: 'Research Methods, Sources and Limitations',
    subs: [
      ReportSub(
        code: '12.1',
        title: 'Research Design',
        unavailable: _pending,
      ),
      ReportSub(
        code: '12.2',
        title: 'Instruments and Measurement Rules',
        unavailable: _pending,
      ),
      ReportSub(
        code: '12.3',
        title: 'Source Register',
        unavailable: _pending,
      ),
      ReportSub(
        code: '12.4',
        title: 'Evidence Verification',
        unavailable: _pending,
      ),
      ReportSub(
        code: '12.5',
        title: 'Sampling and Measurement Limitations',
        unavailable: _pending,
      ),
      ReportSub(
        code: '12.6',
        title: 'Outstanding Evidence',
        unavailable: _pending,
      ),
      ReportSub(
        code: '12.7',
        title: 'Report Authorization and Revision History',
        unavailable: _pending,
      ),
    ],
  ),
];

/// Appendices A–D, rendered after R12.
class ReportAppendix {
  final String code;
  final String title;
  final String note;
  const ReportAppendix(this.code, this.title, this.note);
}

const List<ReportAppendix> reportAppendices = [
  ReportAppendix('A', 'Question and Finding Traceability',
      'Confirmed uncertainty → BCB → QJ → bank reuse/QG → approved question '
      'version → respondent presentation/answer → EE-01 → eligible report claim.'),
  ReportAppendix('B', 'Evidence and Citation Inspector',
      'Claim ID → exact source or measurement → supporting passage/cell → '
      'verification decision → limitations → report authorization.'),
  ReportAppendix('C', 'Rental Candidate Details',
      'Individual rental evidence, dated source details, map/context '
      'limitations and unresolved property-specific questions.'),
  ReportAppendix('D', 'Explanation and Review History',
      'Selected explanation version, source-bound validation record, permitted '
      'LLM-attempt references and applicable audit decisions.'),
];
