import 'commercial_property.dart';

/// Ranked recommendation with a human-readable explanation.
/// No model internals (versions, weights, vectors) ever appear here.
class PropertyRecommendation {
  final CommercialProperty property;
  final double score;
  final String reason;

  /// "Why recommended" bullets in business language (§19).
  final List<String> whyRecommended;
  final List<String> highlights;

  const PropertyRecommendation({
    required this.property,
    required this.score,
    required this.reason,
    required this.whyRecommended,
    this.highlights = const [],
  });

  String get suitabilityLabel => '${score.toStringAsFixed(0)} / 100';
}

/// Entrepreneur-stated business preferences that drive recommendations.
/// Budget is a range; no AI weighting controls are exposed (§14).
class BusinessPreferences {
  final String businessType;
  final String preferredLocation;
  final double minBudgetRm;
  final double maxBudgetRm;
  final String propertyType;
  final double minSizeSqft;
  final double maxSizeSqft;
  final List<String> requirements;
  final List<String> preferredAreas;
  final String seatingModel;

  const BusinessPreferences({
    required this.businessType,
    this.preferredLocation = '',
    this.minBudgetRm = 0,
    required this.maxBudgetRm,
    this.propertyType = 'Any',
    required this.minSizeSqft,
    this.maxSizeSqft = double.infinity,
    this.requirements = const [],
    this.preferredAreas = const [],
    this.seatingModel = '',
  });

  String get budgetDisplay =>
      'RM ${minBudgetRm.toStringAsFixed(0)} – RM ${maxBudgetRm.toStringAsFixed(0)}';
}
