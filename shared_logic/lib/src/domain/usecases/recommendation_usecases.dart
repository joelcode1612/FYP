import '../entities/location_intelligence.dart';
import '../entities/recommendation.dart';
import '../repositories/recommendation_repository.dart';

class GetRecommendations {
  final RecommendationRepository repo;
  const GetRecommendations(this.repo);
  Future<List<PropertyRecommendation>> call(BusinessPreferences prefs) =>
      repo.getRecommendations(prefs);
}

class GetLocationAnalysis {
  final RecommendationRepository repo;
  const GetLocationAnalysis(this.repo);
  Future<LocationAnalysis> call(String propertyId) =>
      repo.getLocationAnalysis(propertyId);
}
