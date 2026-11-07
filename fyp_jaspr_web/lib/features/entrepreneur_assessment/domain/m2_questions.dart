/// Documentary M2-VNEXT-20261028-QE-CAND-02 snapshot. NOT approved.
/// Do not infer validity, consent, authorization or questionnaire fieldability.
enum M2Kind { single, multi, description, held }

class M2Question {
  const M2Question({
    required this.id,
    required this.page,
    required this.label,
    required this.kind,
    this.options = const [],
    this.required = false,
    this.maximum,
    this.exclusiveChoice,
    this.note,
  });

  final String id;
  final int page;
  final String label;
  final M2Kind kind;
  final List<String> options;
  final bool required;
  final int? maximum;
  final String? exclusiveChoice;
  final String? note;
}

const m2Questions = <M2Question>[
  M2Question(id: 'M2-01', page: 0, label: 'What is your role in this venture?', kind: M2Kind.single, required: true, options: ['Founder/owner', 'Co-founder/partner', 'Pre-opening manager', 'Other']),
  M2Question(id: 'M2-02', page: 0, label: 'How much food-and-beverage experience do you have?', kind: M2Kind.single, required: true, options: ['No food-and-beverage experience', 'Less than 1 year (but more than none)', '1 to 3 years', 'More than 3 years'], note: 'Candidate requiredness under review; experience is not a viability weight.'),
  M2Question(id: 'M2-03', page: 0, label: 'Which best describes your intended location setting?', kind: M2Kind.single, required: true, options: ['City-centre commercial', 'Suburban shoplot', 'Residential-area shoplot', 'Mall/food-court', 'Other'], note: 'Undecided state is under scientific review.'),
  M2Question(id: 'M2-04', page: 1, label: 'In one or two sentences, what kind of café do you plan to open?', kind: M2Kind.description, note: 'Recommended. Original wording is preserved; no automatic rewrite.'),
  M2Question(id: 'M2-05', page: 1, label: 'What service format do you plan?', kind: M2Kind.single, required: true, options: ['Dine-in focused', 'Takeaway/delivery focused', 'Hybrid (meaningful volume of both)']),
  M2Question(id: 'M2-06', page: 1, label: 'Which product categories do you plan to offer?', kind: M2Kind.multi, required: true, options: ['Coffee/espresso', 'Non-coffee drinks', 'Baked/pastry', 'Light meals', 'Desserts', 'Retail beans/merch', 'Other']),
  M2Question(id: 'M2-07', page: 1, label: 'Who do you intend to serve?', kind: M2Kind.multi, required: true, options: ['Office workers', 'Students', 'Residents', 'Shoppers/tourists', 'Remote workers', 'Other'], note: 'Select primary intended group separately.'),
  M2Question(id: 'M2-08', page: 1, label: 'What is that segment view based on?', kind: M2Kind.single, options: ['My own observation of the area', 'Local knowledge/familiarity', 'General assumption', 'Other']),
  M2Question(id: 'M2-09', page: 1, label: 'What do you plan to compete on?', kind: M2Kind.multi, maximum: 2, options: ['Price', 'Quality/specialty', 'Convenience/location', 'Ambience', 'Uniqueness', 'Other']),
  M2Question(id: 'M2-10', page: 2, label: 'For a medium latte, dine-in, what price do you plan?', kind: M2Kind.held, required: true, note: 'BLOCKED: exact product applicability and SD-S07 remain unresolved.'),
  M2Question(id: 'M2-11', page: 2, label: 'Compared with cafés you know in the area, is that price…?', kind: M2Kind.held, note: 'DEFERRED: subjective comparison has no verified comparator.'),
  M2Question(id: 'M2-12', page: 2, label: 'How much startup capital do you plan to commit?', kind: M2Kind.single, required: true, options: ['Less than RM50,000', 'RM50,000 to under RM150,000', 'RM150,000 to under RM300,000', 'RM300,000 to under RM500,000', 'RM500,000 or more', 'Not decided']),
  M2Question(id: 'M2-13', page: 2, label: 'Which expense lines do you expect to dominate?', kind: M2Kind.multi, maximum: 3, required: true, options: ['Fit-out', 'Equipment', 'Rent deposit', 'Initial inventory', 'Staff', 'Marketing', 'Other']),
  M2Question(id: 'M2-14', page: 2, label: 'How long do you assume until the business breaks even?', kind: M2Kind.single, options: ['Under 6 months', '6 to 11 months', '12 to 23 months', '24 months or more', 'Not estimated'], note: 'Assumption only. Break-even meaning is not yet finalized.'),
  M2Question(id: 'M2-15', page: 2, label: 'What is the funding source?', kind: M2Kind.held, note: 'DEFERRED: necessity, access and privacy review pending.'),
  M2Question(id: 'M2-O-01', page: 2, label: 'How many customers do you expect on a typical weekday once open?', kind: M2Kind.single, options: ['Fewer than 10', '10–29', '30–59', '60–99', '100 or more', 'Not estimated'], note: 'This is a forecast, not observed demand or revenue.'),
  M2Question(id: 'M2-O-02', page: 2, label: 'How many staff do you plan to employ at opening?', kind: M2Kind.single, options: ['0 (solo/self + family)', '1–2', '3–5', '6 or more', 'Not decided']),
  M2Question(id: 'M2-16', page: 3, label: 'What customer evidence do you currently hold?', kind: M2Kind.multi, required: true, exclusiveChoice: 'None', options: ['None', 'Friends/family opinion', 'Observation of the area', 'Competitor menu boards', 'A paid report', 'A prior survey I ran', 'Other'], note: 'Declared held does not mean verified evidence.'),
  M2Question(id: 'M2-17', page: 3, label: 'Which information is still missing for your decision?', kind: M2Kind.multi, required: true, exclusiveChoice: 'None missing', options: ['Demand for my concept', 'Competitor pricing', 'Rent/occupancy costs', 'Supplier costs', 'Licensing/regulations', 'Staffing', 'None missing']),
  M2Question(id: 'M2-18', page: 3, label: 'How confident are you in your demand expectations?', kind: M2Kind.single, required: true, options: ['Not at all confident', 'Slightly confident', 'Moderately confident', 'Quite confident', 'Very confident'], note: 'Confidence measures self-perception, not evidence quality.'),
  M2Question(id: 'M2-19', page: 3, label: 'Where are you in the location decision?', kind: M2Kind.single, options: ['Not started', 'Viewing options', 'Negotiating', 'Signed/committed']),
];
