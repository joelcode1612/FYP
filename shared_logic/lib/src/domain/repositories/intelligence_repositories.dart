import '../entities/location_intelligence.dart';
import '../entities/sitewise_records.dart';

/// Location intelligence + suitability contracts. Returns business-language
/// factors only — never model internals (§39).
abstract class LocationIntelligenceRepository {
  Future<LocationAnalysis> getLocationIntelligence(String propertyId);
  Future<RecommendationExplanation> getExplanation(String propertyId);
}

/// Device-local saved/compare sets. Implemented in-memory for the prototype;
/// a local datasource can back it later without touching callers.
abstract class ComparisonRepository {
  Future<List<SavedProperty>> getSaved();
  Future<void> saveProperty(String propertyId);
  Future<void> removeSavedProperty(String propertyId);
  Future<PropertyComparison> getComparison();
  Future<void> addToComparison(String propertyId);
  Future<void> removeFromComparison(String propertyId);
  Future<void> clearComparison();
}
