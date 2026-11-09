/// Device-local shortlist entry.
class SavedProperty {
  final String propertyId;
  final DateTime savedAt;

  const SavedProperty({required this.propertyId, required this.savedAt});
}

/// A comparison set of up to 3 properties (§22).
class PropertyComparison {
  final List<String> propertyIds;

  const PropertyComparison({this.propertyIds = const []});

  bool get isFull => propertyIds.length >= 3;
}

/// Explainable recommendation: strengths + considerations (§20).
class RecommendationExplanation {
  final String propertyId;
  final double suitabilityScore;
  final List<String> strengths;
  final List<String> considerations;
  final String summary;

  const RecommendationExplanation({
    required this.propertyId,
    required this.suitabilityScore,
    required this.strengths,
    required this.considerations,
    required this.summary,
  });
}

/// Clean evaluation report (§24) — no analytics overload.
class EvaluationReport {
  final String propertyId;
  final String propertyTitle;
  final String locationLine;
  final String rentalLine;
  final String sizeLine;
  final double suitabilityScore;
  final List<String> keyFactors;
  final String recommendation;
  final List<String> considerations;
  final bool tourAvailable;

  const EvaluationReport({
    required this.propertyId,
    required this.propertyTitle,
    required this.locationLine,
    required this.rentalLine,
    required this.sizeLine,
    required this.suitabilityScore,
    required this.keyFactors,
    required this.recommendation,
    required this.considerations,
    required this.tourAvailable,
  });
}
