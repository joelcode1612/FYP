/// Versioned, fictional sample data for the PROJECT1 UI/UX prototype (V4).
///
/// Everything in this file is **illustrative**. It is not a scientific
/// instrument, not fielded research, and not approved benchmark data. The
/// prototype requirement (V4 §9) is explicit: sample café, responses,
/// locations, report figures and interactions are illustrative only.
///
/// The M2 item wording/options here are a *working design* and remain subject
/// to scientific finalization by WS-QNR-FINAL-01 (V4 §3 WF-04, §8). Item IDs
/// are local to this prototype and are not the frozen B03 register IDs.
library;

/// The pinned prototype data version shown in the UI and audit trail.
const String kPrototypeVersion = 'PROTO-V4-2026-10-28';

/// One M2 questionnaire item (answer field or governance action).
class M2Item {
  final String id;
  final String section;

  /// `choice` | `multi` | `text` | `action`
  final String type;
  final String prompt;
  final bool required;
  final List<String> options;

  /// Pre-filled sample answer. Empty for actions.
  final String sample;

  const M2Item({
    required this.id,
    required this.section,
    required this.type,
    required this.prompt,
    required this.required,
    this.options = const [],
    this.sample = '',
  });
}

/// 21 answer fields (12 required, 9 optional) — the V4 working set.
const List<M2Item> kM2AnswerItems = [
  // A — Entrepreneur & experience
  M2Item(
    id: 'M2-01',
    section: 'A · Entrepreneur & experience',
    type: 'choice',
    prompt: 'Which best describes your role in the proposed café?',
    required: true,
    options: ['Founder / owner', 'Partner', 'Manager', 'Other'],
    sample: 'Founder / owner',
  ),
  M2Item(
    id: 'M2-02',
    section: 'A · Entrepreneur & experience',
    type: 'choice',
    prompt: 'How much previous food-and-beverage experience do you have?',
    required: false,
    options: ['None', 'Under 1 year', '1–3 years', '3+ years'],
    sample: 'Under 1 year',
  ),
  // B — Concept & format
  M2Item(
    id: 'M2-03',
    section: 'B · Concept & format',
    type: 'text',
    prompt: 'Describe your café concept in one or two sentences.',
    required: true,
    sample:
        'A small takeaway-focused café serving specialty coffee and fresh '
        'pastries near a university.',
  ),
  M2Item(
    id: 'M2-04',
    section: 'B · Concept & format',
    type: 'choice',
    prompt: 'What service format do you plan?',
    required: true,
    options: ['Takeaway-focused', 'Dine-in-focused', 'Hybrid'],
    sample: 'Takeaway-focused',
  ),
  M2Item(
    id: 'M2-05',
    section: 'B · Concept & format',
    type: 'multi',
    prompt: 'Which menu categories do you plan to offer?',
    required: true,
    options: ['Coffee', 'Tea', 'Pastries', 'Sandwiches', 'Hot food', 'Desserts'],
    sample: 'Coffee, Pastries',
  ),
  // C — Products & customers
  M2Item(
    id: 'M2-06',
    section: 'C · Products & customers',
    type: 'choice',
    prompt: 'What is your intended signature product?',
    required: true,
    options: ['Latte', 'Americano', 'Filter coffee', 'Other'],
    sample: 'Latte',
  ),
  M2Item(
    id: 'M2-07',
    section: 'C · Products & customers',
    type: 'choice',
    prompt: 'Who is your primary customer group?',
    required: true,
    options: [
      'University students',
      'Office workers',
      'Local residents',
      'Tourists',
      'Mixed',
    ],
    sample: 'University students',
  ),
  M2Item(
    id: 'M2-08',
    section: 'C · Products & customers',
    type: 'multi',
    prompt: 'Which secondary customer groups do you expect? (optional)',
    required: false,
    options: [
      'University students',
      'Office workers',
      'Local residents',
      'Tourists',
    ],
    sample: 'Office workers',
  ),
  M2Item(
    id: 'M2-09',
    section: 'C · Products & customers',
    type: 'choice',
    prompt: 'What price range do you plan for a medium latte?',
    required: true,
    options: ['Below RM10', 'RM10 to below RM12', 'RM12 to below RM15', 'RM15+'],
    sample: 'RM12 to below RM15',
  ),
  // D — Financial planning
  M2Item(
    id: 'M2-10',
    section: 'D · Financial planning',
    type: 'choice',
    prompt: 'What is your monthly rent budget?',
    required: true,
    options: [
      'Below RM3,000',
      'RM3,000–RM5,999',
      'RM6,000–RM9,999',
      'RM10,000+',
    ],
    sample: 'RM3,000–RM5,999',
  ),
  M2Item(
    id: 'M2-11',
    section: 'D · Financial planning',
    type: 'choice',
    prompt: 'What is your fit-out budget? (optional)',
    required: false,
    options: ['Below RM30k', 'RM30k–RM59k', 'RM60k–RM99k', 'RM100k+'],
    sample: 'RM30k–RM59k',
  ),
  M2Item(
    id: 'M2-12',
    section: 'D · Financial planning',
    type: 'choice',
    prompt: 'How many daily covers do you expect?',
    required: true,
    options: ['Below 50', '50–99', '100–199', '200+'],
    sample: '50–99',
  ),
  M2Item(
    id: 'M2-13',
    section: 'D · Financial planning',
    type: 'choice',
    prompt: 'What break-even timeline do you expect? (optional)',
    required: false,
    options: ['Under 12 months', '12–24 months', 'Over 24 months', 'Unsure'],
    sample: '12–24 months',
  ),
  // E — Information held
  M2Item(
    id: 'M2-14',
    section: 'E · Information you already hold',
    type: 'choice',
    prompt: 'What customer information do you already hold? (optional)',
    required: false,
    options: ['None', 'Informal feedback', 'Structured survey', 'Sales data'],
    sample: 'None',
  ),
  M2Item(
    id: 'M2-15',
    section: 'E · Information you already hold',
    type: 'choice',
    prompt: 'What supplier information do you already hold? (optional)',
    required: false,
    options: ['None', 'Informal quotes', 'Written quotes'],
    sample: 'Informal quotes',
  ),
  M2Item(
    id: 'M2-16',
    section: 'E · Information you already hold',
    type: 'choice',
    prompt: 'What market research have you already done? (optional)',
    required: false,
    options: ['None', 'Online research', 'Local observation', 'Professional report'],
    sample: 'Local observation',
  ),
  // F — Missing information & confidence
  M2Item(
    id: 'M2-17',
    section: 'F · Missing information & confidence',
    type: 'multi',
    prompt: 'Which information are you missing? (optional)',
    required: false,
    options: [
      'Customer demand',
      'Competitor pricing',
      'Footfall',
      'Rent benchmarks',
      'Supplier costs',
    ],
    sample: 'Customer demand, Footfall',
  ),
  M2Item(
    id: 'M2-18',
    section: 'F · Missing information & confidence',
    type: 'choice',
    prompt: 'How confident are you in your expectations? (optional)',
    required: false,
    options: ['Very low', 'Low', 'Neutral', 'High', 'Very high'],
    sample: 'Neutral',
  ),
  // G — Location decision stage
  M2Item(
    id: 'M2-19',
    section: 'G · Location decision stage',
    type: 'choice',
    prompt: 'What stage is your location decision at?',
    required: true,
    options: [
      'No area yet',
      'Shortlisting areas',
      'Comparing specific units',
      'Unit selected',
    ],
    sample: 'Shortlisting areas',
  ),
  M2Item(
    id: 'M2-20',
    section: 'G · Location decision stage',
    type: 'choice',
    prompt: 'What is your target opening timeframe?',
    required: true,
    options: ['Within 3 months', '3–6 months', '6–12 months', 'Over 12 months'],
    sample: '3–6 months',
  ),
  M2Item(
    id: 'M2-21',
    section: 'G · Location decision stage',
    type: 'choice',
    prompt: 'Which daypart will you mainly serve?',
    required: true,
    options: ['Morning', 'Lunch', 'Afternoon', 'Evening', 'All day'],
    sample: 'Morning',
  ),
];

/// The two review/confirmation actions (V4 WF-04/WF-05). These are engine
/// events, not answer fields — they must never be presented as operational.
const List<M2Item> kM2Actions = [
  M2Item(
    id: 'ACT-OP-A',
    section: 'Review & confirmation',
    type: 'action',
    prompt:
        'OP-A · Acknowledge my answers — confirms the information was entered '
        'intentionally. It does NOT authorize downstream reliance on a '
        'confirmed business plan.',
    required: false,
  ),
  M2Item(
    id: 'ACT-OP-B',
    section: 'Review & confirmation',
    type: 'action',
    prompt:
        'OP-B · Confirm my proposed business plan — available only to an '
        'appropriately authorized actor under accepted confirmation rules. '
        'Simulated only; proves no demand, viability or ownership.',
    required: false,
  ),
];

/// A plain-language business-understanding statement and its M2 provenance.
class BusinessStatement {
  final String text;
  final List<String> sourceIds;
  final String originalAnswer;
  final String meaning;
  final String limitations;

  const BusinessStatement({
    required this.text,
    required this.sourceIds,
    required this.originalAnswer,
    required this.meaning,
    required this.limitations,
  });
}

const List<BusinessStatement> kBusinessStatements = [
  BusinessStatement(
    text:
        'You plan to open a takeaway-focused café offering coffee and pastries.',
    sourceIds: ['M2-04', 'M2-05'],
    originalAnswer: 'Service format: Takeaway-focused · Menu: Coffee, Pastries',
    meaning:
        'The service format is takeaway-led and the planned menu centres on '
        'coffee and pastries.',
    limitations:
        'This reflects your stated plan. It is not measured demand and not a '
        'validated concept.',
  ),
  BusinessStatement(
    text:
        'You intend to serve university students as your primary customer group.',
    sourceIds: ['M2-07'],
    originalAnswer: 'Primary customer group: University students',
    meaning: 'The intended primary customer group is university students.',
    limitations:
        'Self-declared. Customer research has not yet validated this group.',
  ),
  BusinessStatement(
    text:
        'Your selected price range for a medium latte is RM12 to below RM15.',
    sourceIds: ['M2-09'],
    originalAnswer: 'Price range: RM12 to below RM15',
    meaning: 'A price band for the specified drink.',
    limitations:
        'A range, not an exact selling price, and not a willingness-to-pay '
        'measurement.',
  ),
  BusinessStatement(
    text: 'Your monthly rent budget is RM3,000 to RM5,999.',
    sourceIds: ['M2-10'],
    originalAnswer: 'Monthly rent budget: RM3,000–RM5,999',
    meaning: 'A planning assumption for monthly rent.',
    limitations:
        'A budget assumption, not a market rent benchmark.',
  ),
];

/// One R01–R12 report section (V4 WF-09). Status is a prototype label only.
class ReportSection {
  final String id;
  final String title;
  final String body;

  /// `ENTREPRENEUR_DECLARED` | `FICTIONAL` | `CONTEXT_ONLY` | `NOT_AVAILABLE`
  final String status;

  const ReportSection({
    required this.id,
    required this.title,
    required this.body,
    required this.status,
  });
}

const List<ReportSection> kReportSections = [
  ReportSection(
    id: 'R01',
    title: 'Proposed café and business understanding',
    body:
        'Artisan Brew Corner Lot — a takeaway-focused café offering coffee and '
        'pastries, targeting university students. Derived from the entrepreneur '
        'M2 answers.',
    status: 'ENTREPRENEUR_DECLARED',
  ),
  ReportSection(
    id: 'R02',
    title: 'Customer research method and evidence coverage',
    body:
        'FICTIONAL demonstration: 58 responses collected, 42 valid '
        '(n = 42 / 58), questionnaire version vDRAFT.0. This is not a real '
        'fielding and no respondents were recruited.',
    status: 'FICTIONAL',
  ),
  ReportSection(
    id: 'R03',
    title: 'Stated first-visit interest',
    body:
        'FICTIONAL: 61% (26 / 42) said they would likely visit. Stated interest '
        'is not guaranteed visits and not projected revenue.',
    status: 'FICTIONAL',
  ),
  ReportSection(
    id: 'R04',
    title: 'Customer product-category interest',
    body: 'FICTIONAL: Coffee 88% (37 / 42); Pastries 64% (27 / 42).',
    status: 'FICTIONAL',
  ),
  ReportSection(
    id: 'R05',
    title: 'Acceptability of a precisely defined product and price',
    body:
        'FICTIONAL: A medium latte at RM12 to below RM15 was acceptable to 55% '
        '(23 / 42). The price is a band, not a fabricated exact price.',
    status: 'FICTIONAL',
  ),
  ReportSection(
    id: 'R06',
    title: 'Self-reported existing café purchasing',
    body:
        'FICTIONAL: 71% (30 / 42) reported buying café coffee at least weekly.',
    status: 'FICTIONAL',
  ),
  ReportSection(
    id: 'R07',
    title: 'Café occasions and feature preferences',
    body:
        'FICTIONAL: The most cited occasion was a quick takeaway before class.',
    status: 'FICTIONAL',
  ),
  ReportSection(
    id: 'R08',
    title: 'Respondent geographic context and limitations',
    body:
        'District-level context only. No mukim, sub-district or neighbourhood '
        'dataset exists; respondent geography is self-reported and '
        'illustrative. Deeper geography is not available at this level.',
    status: 'CONTEXT_ONLY',
  ),
  ReportSection(
    id: 'R09',
    title: 'Accepted external market information',
    body:
        'None accepted. External geographic and market sources are not approved '
        'for use in this prototype.',
    status: 'NOT_AVAILABLE',
  ),
  ReportSection(
    id: 'R10',
    title: "Entrepreneur's financial planning assumptions",
    body:
        'Rent budget RM3,000–RM5,999 per month; expected 50–99 covers per day. '
        'These are assumptions, not financial benchmarks.',
    status: 'ENTREPRENEUR_DECLARED',
  ),
  ReportSection(
    id: 'R11',
    title: 'Suitability findings (only when justified)',
    body:
        'Not issued. No accepted methods or benchmarks exist, so suitability is '
        'not scored in this prototype. The only permitted vocabulary is '
        'BELOW_THRESHOLD, ON_TRACK, ABOVE_THRESHOLD, NO_BENCHMARK.',
    status: 'NOT_AVAILABLE',
  ),
  ReportSection(
    id: 'R12',
    title: 'Evidence sources, missing information, limitations, version history',
    body:
        'Version vDRAFT.0 · fictional customer data · missing: approved '
        'customer responses and approved external market data · limitation: '
        'district-level geography only.',
    status: 'NOT_AVAILABLE',
  ),
];

/// One customer questionnaire item (V4 WF-10). Q01 is the screening question.
class CustomerQuestion {
  final String id;
  final String group;
  final String prompt;
  final List<String> options;
  final bool multi;
  final bool screening;

  const CustomerQuestion({
    required this.id,
    required this.group,
    required this.prompt,
    required this.options,
    this.multi = false,
    this.screening = false,
  });
}

const List<CustomerQuestion> kCustomerQuestions = [
  CustomerQuestion(
    id: 'Q01',
    group: 'Screening',
    prompt: 'Do you buy café coffee at least occasionally?',
    options: ['Yes', 'No', 'Not sure'],
    screening: true,
  ),
  CustomerQuestion(
    id: 'Q02',
    group: 'Existing behaviour',
    prompt: 'How often do you buy café coffee?',
    options: ['Daily', 'A few times a week', 'Weekly', 'Less often', 'Not sure'],
  ),
  CustomerQuestion(
    id: 'Q03',
    group: 'Existing behaviour',
    prompt: 'Which café products do you usually buy?',
    options: ['Coffee', 'Tea', 'Pastries', 'Sandwiches'],
    multi: true,
  ),
  CustomerQuestion(
    id: 'Q04',
    group: 'Existing behaviour',
    prompt: 'When do you usually visit cafés?',
    options: ['Morning', 'Lunch', 'Afternoon', 'Evening'],
  ),
  CustomerQuestion(
    id: 'Q05',
    group: 'Geography',
    prompt: 'How far would you travel for a takeaway café?',
    options: ['Under 5 min', '5–10 min', '10–15 min', 'Over 15 min', 'Not sure'],
  ),
  CustomerQuestion(
    id: 'Q06',
    group: 'Stated interest',
    prompt: 'Would you try a new takeaway café near a university?',
    options: [
      'Very likely',
      'Likely',
      'Neutral',
      'Unlikely',
      'Very unlikely',
      'Not sure',
    ],
  ),
  CustomerQuestion(
    id: 'Q07',
    group: 'Product & price',
    prompt: 'Which price for a medium latte is acceptable?',
    options: ['Below RM10', 'RM10 to below RM12', 'RM12 to below RM15', 'RM15+', 'Not sure'],
  ),
  CustomerQuestion(
    id: 'Q08',
    group: 'Product & price',
    prompt: 'How often do you buy pastries with coffee?',
    options: ['Always', 'Sometimes', 'Rarely', 'Never', 'Not sure'],
  ),
  CustomerQuestion(
    id: 'Q09',
    group: 'Preferences',
    prompt: 'What matters most to you?',
    options: ['Price', 'Quality', 'Speed', 'Location'],
    multi: true,
  ),
  CustomerQuestion(
    id: 'Q10',
    group: 'Geography',
    prompt: 'Do you study or work near the area?',
    options: ['Yes', 'No', 'Not sure'],
  ),
  CustomerQuestion(
    id: 'Q11',
    group: 'Stated interest',
    prompt: 'Would you visit a takeaway-only café with no seating?',
    options: ['Yes', 'No', 'Not sure'],
  ),
  CustomerQuestion(
    id: 'Q12',
    group: 'Preferences',
    prompt: 'Any dietary preferences?',
    options: ['None', 'Vegetarian', 'Vegan', 'Other'],
    multi: true,
  ),
  CustomerQuestion(
    id: 'Q13',
    group: 'Preferences',
    prompt: 'Anything else you would like to add?',
    options: ['No further comments'],
  ),
];

/// One evidence category (V4 WF-08).
class EvidenceCategory {
  final String title;
  final String status;
  final String detail;

  const EvidenceCategory({
    required this.title,
    required this.status,
    required this.detail,
  });
}

const List<EvidenceCategory> kEvidenceCategories = [
  EvidenceCategory(
    title: 'Entrepreneur-declared information',
    status: 'AVAILABLE · SELF-DECLARED',
    detail:
        'The café concept, target customer and price band come from your M2 '
        'answers. They describe your plan; they are not measured demand.',
  ),
  EvidenceCategory(
    title: 'External geographic / market observations',
    status: 'NOT APPROVED',
    detail:
        'No external source is approved for use. Illustrative district context '
        'is shown for orientation only and cannot establish demand.',
  ),
  EvidenceCategory(
    title: 'Qualified customer responses',
    status: 'NOT AVAILABLE',
    detail:
        'No approved customer responses exist yet (0 respondents). Customer '
        'interest has not been measured. This is not the same as 0% interest.',
  ),
  EvidenceCategory(
    title: 'Missing / insufficient / unauthorized evidence',
    status: 'LISTED',
    detail:
        'Missing: approved customer responses, approved external market data, '
        'validated demand benchmarks. Unauthorized: suitability scoring.',
  ),
];

/// One illustrative, fictional geographic location (V4 WF-07).
class GeoLocation {
  final String name;
  final String adminLevel;
  final String note;

  const GeoLocation({
    required this.name,
    required this.adminLevel,
    required this.note,
  });
}

const List<GeoLocation> kGeoLocations = [
  GeoLocation(
    name: 'Fictional District A',
    adminLevel: 'Administrative district (illustrative)',
    note: 'District-level context only. No mukim or sub-district data exists.',
  ),
  GeoLocation(
    name: 'Fictional District B',
    adminLevel: 'Administrative district (illustrative)',
    note: 'Illustrative boundary. Not a real administrative or source boundary.',
  ),
  GeoLocation(
    name: 'Fictional Study Area C',
    adminLevel: 'Study area (illustrative)',
    note: 'A drawn study area, not an approved site or source geography.',
  ),
];
