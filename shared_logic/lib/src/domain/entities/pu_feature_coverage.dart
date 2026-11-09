/// Diagnostic for whether the property's stored data satisfy the saved PU model.
class PuFeatureCoverage {
  final String propertyId;
  final int featureCount;
  final int availableFeatures;
  final List<String> missingFeatures;
  final List<String> qualityFlags;
  final String? subjectId;

  const PuFeatureCoverage({
    required this.propertyId,
    required this.featureCount,
    required this.availableFeatures,
    required this.missingFeatures,
    required this.qualityFlags,
    this.subjectId,
  });

  bool get ready =>
      featureCount > 0 && availableFeatures == featureCount && missingFeatures.isEmpty;
}
