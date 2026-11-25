/// The one place a stage key becomes a name a reader recognises.
///
/// The backend's stage keys are the contract (`location_evidence`,
/// `ai_explanation`, …) and must not be reworded on the wire. But the keys are
/// internal names, and two surfaces were printing them at readers: the journey
/// stepper labelled the step "Business review and research goals", while the
/// blocker sentence for the next stage said "Complete the location evidence
/// stage first" — the same step, two vocabularies, one of them meaningless.
///
/// Every reader-facing mention of a stage goes through [stageDisplayLabel], so
/// renaming a step changes the stepper, the breadcrumb, the step heading and
/// every "complete X first" sentence together.
///
/// Lives in `application/` because both presentation components and the reason
/// copy need it, and presentation may not be imported from application.
library;

/// Reader-facing names for the five checkpoints.
///
/// These follow the step redesigns, not the original wire names: step 3 became
/// the business review and research goals, step 4 became the research question
/// review, and step 5 became publishing the questionnaire.
const Map<String, String> stageLabels = {
  'select_property': 'Select property',
  'business_requirements': 'Business preferences',
  'location_evidence': 'Business review and research goals',
  'ai_explanation': 'Question review',
  'assessment_report': 'Questionnaire preview',
};

/// The label for [key], falling back to the server's own label.
///
/// The fallback matters: a stage added on the server before this build knows
/// about it still gets a name from the payload instead of a raw key or a blank.
String stageDisplayLabel(String key, String serverLabel) =>
    stageLabels[key] ?? serverLabel;

/// The label for [key] alone, or null when this build has no name for it.
String? stageLabel(String? key) => key == null ? null : stageLabels[key];
