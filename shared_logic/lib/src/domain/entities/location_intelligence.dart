/// A single explainable location factor, expressed in business language
/// (Strong / Good / Moderate) — never raw geospatial calculations.
class LocationFactor {
  final String name;
  final double score; // 0–100, drives the progress bar only
  final String rating; // Strong, Good, Moderate, Weak
  final String evidence;
  final String impact; // Positive / Neutral / Risk

  const LocationFactor({
    required this.name,
    required this.score,
    required this.rating,
    required this.evidence,
    required this.impact,
  });
}

/// Aggregated location intelligence for one property.
class LocationAnalysis {
  final String propertyId;
  final double suitabilityScore;
  final List<LocationFactor> factors;
  final int competitorCount;
  final String demandSummary;
  final String socioeconomicSummary;

  const LocationAnalysis({
    required this.propertyId,
    required this.suitabilityScore,
    required this.factors,
    required this.competitorCount,
    required this.demandSummary,
    this.socioeconomicSummary = '',
  });

  /// Plain-language verdict for the suitability page.
  String get verdict {
    if (suitabilityScore >= 80) return 'Good potential';
    if (suitabilityScore >= 60) return 'Moderate potential';
    return 'Consider carefully';
  }
}
