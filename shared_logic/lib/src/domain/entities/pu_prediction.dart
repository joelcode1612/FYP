/// Research-only P/U classifier output. NOT a probability of business success.
/// Keep this separate from LocationAnalysis.suitabilityScore (a 0–100
/// decision-support score in the current UI) and from personalized rankings.
class PuPrediction {
  final String propertyId;
  final bool available;
  final double? positiveLabelAssociation;
  final String? modelVersion;
  final String? reason;
  final String scoreMeaning;
  final int? featureCount;
  final int? availableFeatures;
  final List<String> missingFeatures;
  final List<String> qualityFlags;

  const PuPrediction({
    required this.propertyId,
    required this.available,
    required this.positiveLabelAssociation,
    required this.scoreMeaning,
    this.modelVersion,
    this.reason,
    this.featureCount,
    this.availableFeatures,
    this.missingFeatures = const [],
    this.qualityFlags = const [],
  });

  /// Display as a *research association* percentage only (not success odds).
  double? get associationPercent =>
      positiveLabelAssociation == null ? null : positiveLabelAssociation! * 100;
}
