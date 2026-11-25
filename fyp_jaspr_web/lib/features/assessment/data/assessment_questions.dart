/// The Stage-2 business questionnaire and the two derivations the report needs
/// from it.
///
/// This module exists so the assessment report has **one** definition of the
/// questionnaire. The report is rendered from two places — in place inside the
/// workspace, and on its own route (`/entrepreneur/assessment-report`) — and a
/// second copy of this contract would let the same saved answer be described two
/// different ways depending on which URL the reader opened.
///
/// Tokens are what the backend validates, so a label can change here without
/// rewriting a stored answer. Option captions are the only place a stored token
/// becomes prose, and the report reads them through [assessmentAnswerText] so it
/// cannot invent a caption the questionnaire does not use.
library;

import 'package:sitewise_jaspr_web/features/assessment/data/assessment_api.dart';

/// One question of the Stage-2 business questionnaire.
typedef AssessmentQuestion = ({
  String id,
  String prompt,
  String help,
  String kind,
  List<(String, String)> options,
});

/// The five questions whose answers declare the business.
///
/// Q4 shows the five V3 priorities; the two legacy v2 tokens stay valid
/// server-side for pre-V3 records, which seed from storage without being
/// re-interpreted.
const List<AssessmentQuestion> assessmentQuestions = [
  (
    id: 'fnb_concept',
    prompt: 'What kind of F&B business are you opening?',
    help: 'Your concept shapes how the competition figures are read.',
    kind: 'single',
    options: [
      ('cafe_coffee_shop', 'Café / Coffee Shop'),
      ('restaurant', 'Restaurant'),
      ('bakery_dessert_shop', 'Bakery / Dessert Shop'),
      ('fast_food_quick_service', 'Fast Food / Quick Service'),
      ('beverage_shop_kiosk', 'Beverage / Kiosk'),
      ('other_fnb', 'Other'),
    ],
  ),
  (
    id: 'service_model',
    prompt: 'How will you serve customers?',
    help: 'Dine-in, takeaway and delivery place different demands on a site.',
    kind: 'single',
    options: [
      ('dine_in', 'Dine-in'),
      ('takeaway_quick_service', 'Takeaway / Quick Service'),
      ('delivery_focused', 'Delivery Focused'),
      ('hybrid', 'Hybrid'),
    ],
  ),
  (
    id: 'target_customers',
    prompt: 'Who are your target customers?',
    help: 'Select every group that matters. At least one is required.',
    kind: 'multi',
    options: [
      ('nearby_residents', 'Nearby Residents'),
      ('office_workers', 'Office Workers'),
      ('students', 'Students'),
      ('commuters', 'Commuters'),
      ('general_public', 'General Public'),
    ],
  ),
  (
    id: 'recommendation_priority',
    prompt: 'What matters most when choosing the location?',
    help:
        'This priority dynamically re-weights the scoring components '
        '(Q4 of the five-question recommender).',
    kind: 'single',
    options: [
      ('high_nearby_population', 'High Nearby Population'),
      ('affordable_operating_location', 'Affordable Operating Location'),
      ('easy_customer_accessibility', 'Easy Customer Accessibility'),
      ('active_commercial_surroundings', 'Active Commercial Surroundings'),
      ('balanced_suitability', 'Balanced Suitability'),
    ],
  ),
  (
    id: 'space_size_preference',
    prompt: 'What size of business space do you prefer?',
    help:
        'Scored against the catalogue\'s calibrated floor-area percentiles '
        '(Q5 of the five-question recommender).',
    kind: 'single',
    options: [
      ('compact_business_space', 'Compact Business Space'),
      ('standard_business_space', 'Standard Business Space'),
      ('spacious_business_space', 'Spacious Business Space'),
      ('flexible_no_preference', 'Flexible / No Preference'),
    ],
  ),
];

/// Short human labels for the five declared answers, used as report row labels.
const Map<String, String> assessmentQuestionLabels = {
  'fnb_concept': 'Business type',
  'service_model': 'Service model',
  'target_customers': 'Target customers',
  'recommendation_priority': 'Choosing priority',
  'space_size_preference': 'Space size',
};

/// A stored token rendered with the questionnaire's own caption.
///
/// An unknown token falls back to its underscores turned into spaces, which is
/// the honest reading of a value this build does not know — never a caption
/// borrowed from another option.
String assessmentOptionCaption(AssessmentQuestion question, String token) {
  for (final (value, caption) in question.options) {
    if (value == token) return caption;
  }
  return token.replaceAll('_', ' ');
}

/// A stored requirement rendered with the questionnaire's own option labels.
///
/// Returns null when the answer is absent or renders empty. An id this build
/// does not know still renders (as its de-tokenised text) rather than throwing:
/// a report must not fail to assemble because the questionnaire gained a
/// question after the record was saved.
String? assessmentAnswerText(Map<String, dynamic> stored, String id) {
  final raw = stored[id];
  if (raw == null) return null;
  final question = assessmentQuestions.where((item) => item.id == id).firstOrNull;
  if (question == null) {
    final text = '$raw'.replaceAll('_', ' ').trim();
    return text.isEmpty ? null : text;
  }
  if (raw is List) {
    final parts = [
      for (final item in raw) assessmentOptionCaption(question, '$item'),
    ];
    return parts.isEmpty ? null : parts.join(', ');
  }
  final text = assessmentOptionCaption(question, '$raw');
  return text.isEmpty ? null : text;
}

/// The declared business as label/value pairs for the report's business
/// description.
///
/// Values come from the saved requirements through the questionnaire's own
/// option captions, so the report and Step 2 cannot describe the same answer two
/// different ways.
List<(String, String)> assessmentReportScope(AssessmentRecord record) {
  final stored = record.requirements ?? const <String, dynamic>{};
  final rows = <(String, String)>[];
  for (final key in const [
    'fnb_concept',
    'service_model',
    'target_customers',
    'recommendation_priority',
    'space_size_preference',
  ]) {
    final value = assessmentAnswerText(stored, key);
    if (value == null || value.isEmpty) continue;
    rows.add((assessmentQuestionLabels[key] ?? key, value));
  }
  final budget = stored['max_monthly_rent_myr'] ?? stored['max_budget_rm'];
  if (budget != null) rows.add(('Rental ceiling', 'RM $budget/month'));
  final area = stored['min_floor_area_sqft'] ?? stored['min_size_sqft'];
  if (area != null) rows.add(('Minimum floor area', '$area sq ft'));
  final access = stored['customer_access_mode'];
  if (access is String && access.isNotEmpty) {
    rows.add(('Customer access', access.replaceAll('_', ' ')));
  }
  return rows;
}

/// The one-sentence research objective shown in the report, derived from the
/// saved answers.
///
/// The wording is deliberately conditional: it says what would be assessed, not
/// what has been found.
String assessmentReviewObjective(AssessmentRecord record) {
  final stored = record.requirements ?? const <String, dynamic>{};
  final concept = assessmentAnswerText(stored, 'fnb_concept');
  final customers = assessmentAnswerText(stored, 'target_customers');
  if (concept == null) {
    return 'Choose your business preferences in Step 2 to build a research '
        'objective.';
  }
  if (customers != null) {
    return 'Assess interest in the ${concept.toLowerCase()} you plan to '
        'open and whether ${customers.toLowerCase()} would visit this '
        'location.';
  }
  return 'Assess interest in the ${concept.toLowerCase()} you plan to open '
      'at this location.';
}
