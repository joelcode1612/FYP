import '../entities/location_intelligence.dart';
import '../entities/recommendation.dart';

abstract class RecommendationRepository {
  Future<List<PropertyRecommendation>> getRecommendations(
    BusinessPreferences prefs,
  );
  Future<LocationAnalysis> getLocationAnalysis(String propertyId);
}
