/// M2 prototype fixtures — illustrative only.
///
/// Ported verbatim from the Jaspr prototype's `lib/prototype/prototype_data.dart`
/// (`PROTO-V4-2026-10-28`), with the string `type` discriminator converted to the
/// [M2ItemType] enum.
///
/// **Every caveat from the source is preserved.** This is *not* a scientific
/// instrument, *not* fielded research, and *not* approved benchmark data. The
/// item wording and options are a working design pending scientific
/// finalisation; the item IDs are **local to this prototype** and are not the
/// frozen B03 register IDs. Do not present these as validated measurement.
library;

import '../../../domain/entities/m2_assessment.dart';

const String kPrototypeVersion = 'PROTO-V4-2026-10-28';
/// 21 answer fields (12 required, 9 optional) — the V4 working set.
const List<M2Item> kM2AnswerItems = [
  // A — Entrepreneur & experience
  M2Item(
    id: 'M2-01',
    section: 'A · Entrepreneur & experience',
    type: M2ItemType.choice,
    prompt: 'Which best describes your role in the proposed café?',
    required: true,
    options: ['Founder / owner', 'Partner', 'Manager', 'Other'],
    sample: 'Founder / owner',
  ),
  M2Item(
    id: 'M2-02',
    section: 'A · Entrepreneur & experience',
    type: M2ItemType.choice,
    prompt: 'How much previous food-and-beverage experience do you have?',
    required: false,
    options: ['None', 'Under 1 year', '1–3 years', '3+ years'],
    sample: 'Under 1 year',
  ),
  // B — Concept & format
  M2Item(
    id: 'M2-03',
    section: 'B · Concept & format',
    type: M2ItemType.text,
    prompt: 'Describe your café concept in one or two sentences.',
    required: true,
    sample:
        'A small takeaway-focused café serving specialty coffee and fresh '
        'pastries near a university.',
  ),
  M2Item(
    id: 'M2-04',
    section: 'B · Concept & format',
    type: M2ItemType.choice,
    prompt: 'What service format do you plan?',
    required: true,
    options: ['Takeaway-focused', 'Dine-in-focused', 'Hybrid'],
    sample: 'Takeaway-focused',
  ),
  M2Item(
    id: 'M2-05',
    section: 'B · Concept & format',
    type: M2ItemType.multi,
    prompt: 'Which menu categories do you plan to offer?',
    required: true,
    options: ['Coffee', 'Tea', 'Pastries', 'Sandwiches', 'Hot food', 'Desserts'],
    sample: 'Coffee, Pastries',
  ),
  // C — Products & customers
  M2Item(
    id: 'M2-06',
    section: 'C · Products & customers',
    type: M2ItemType.choice,
    prompt: 'What is your intended signature product?',
    required: true,
    options: ['Latte', 'Americano', 'Filter coffee', 'Other'],
    sample: 'Latte',
  ),
  M2Item(
    id: 'M2-07',
    section: 'C · Products & customers',
    type: M2ItemType.choice,
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
    type: M2ItemType.multi,
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
    type: M2ItemType.choice,
    prompt: 'What price range do you plan for a medium latte?',
    required: true,
    options: ['Below RM10', 'RM10 to below RM12', 'RM12 to below RM15', 'RM15+'],
    sample: 'RM12 to below RM15',
  ),
  // D — Financial planning
  M2Item(
    id: 'M2-10',
    section: 'D · Financial planning',
    type: M2ItemType.choice,
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
    type: M2ItemType.choice,
    prompt: 'What is your fit-out budget? (optional)',
    required: false,
    options: ['Below RM30k', 'RM30k–RM59k', 'RM60k–RM99k', 'RM100k+'],
    sample: 'RM30k–RM59k',
  ),
  M2Item(
    id: 'M2-12',
    section: 'D · Financial planning',
    type: M2ItemType.choice,
    prompt: 'How many daily covers do you expect?',
    required: true,
    options: ['Below 50', '50–99', '100–199', '200+'],
    sample: '50–99',
  ),
  M2Item(
    id: 'M2-13',
    section: 'D · Financial planning',
    type: M2ItemType.choice,
    prompt: 'What break-even timeline do you expect? (optional)',
    required: false,
    options: ['Under 12 months', '12–24 months', 'Over 24 months', 'Unsure'],
    sample: '12–24 months',
  ),
  // E — Information held
  M2Item(
    id: 'M2-14',
    section: 'E · Information you already hold',
    type: M2ItemType.choice,
    prompt: 'What customer information do you already hold? (optional)',
    required: false,
    options: ['None', 'Informal feedback', 'Structured survey', 'Sales data'],
    sample: 'None',
  ),
  M2Item(
    id: 'M2-15',
    section: 'E · Information you already hold',
    type: M2ItemType.choice,
    prompt: 'What supplier information do you already hold? (optional)',
    required: false,
    options: ['None', 'Informal quotes', 'Written quotes'],
    sample: 'Informal quotes',
  ),
  M2Item(
    id: 'M2-16',
    section: 'E · Information you already hold',
    type: M2ItemType.choice,
    prompt: 'What market research have you already done? (optional)',
    required: false,
    options: ['None', 'Online research', 'Local observation', 'Professional report'],
    sample: 'Local observation',
  ),
  // F — Missing information & confidence
  M2Item(
    id: 'M2-17',
    section: 'F · Missing information & confidence',
    type: M2ItemType.multi,
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
    type: M2ItemType.choice,
    prompt: 'How confident are you in your expectations? (optional)',
    required: false,
    options: ['Very low', 'Low', 'Neutral', 'High', 'Very high'],
    sample: 'Neutral',
  ),
  // G — Location decision stage
  M2Item(
    id: 'M2-19',
    section: 'G · Location decision stage',
    type: M2ItemType.choice,
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
    type: M2ItemType.choice,
    prompt: 'What is your target opening timeframe?',
    required: true,
    options: ['Within 3 months', '3–6 months', '6–12 months', 'Over 12 months'],
    sample: '3–6 months',
  ),
  M2Item(
    id: 'M2-21',
    section: 'G · Location decision stage',
    type: M2ItemType.choice,
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
    type: M2ItemType.action,
    prompt:
        'OP-A · Acknowledge my answers — confirms the information was entered '
        'intentionally. It does NOT authorize downstream reliance on a '
        'confirmed business plan.',
    required: false,
  ),
  M2Item(
    id: 'ACT-OP-B',
    section: 'Review & confirmation',
    type: M2ItemType.action,
    prompt:
        'OP-B · Confirm my proposed business plan — available only to an '
        'appropriately authorized actor under accepted confirmation rules. '
        'Simulated only; proves no demand, viability or ownership.',
    required: false,
  ),
];

/// A plain-language business-understanding statement and its M2 provenance.
