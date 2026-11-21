import 'package:shared_logic/shared_logic.dart';

class RecommendationService {
  final RecommendationRepository repo;
  const RecommendationService(this.repo);

  Future<List<PropertyRecommendation>> ranked(BusinessPreferences prefs) =>
      GetRecommendations(repo).call(prefs);
  Future<LocationAnalysis> analysis(String propertyId) =>
      GetLocationAnalysis(repo).call(propertyId);
}

class LocationIntelligenceService {
  final LocationIntelligenceRepository repo;
  const LocationIntelligenceService(this.repo);

  Future<LocationAnalysis> intelligence(String propertyId) =>
      GetLocationIntelligence(repo).call(propertyId);
  Future<LocationAnalysis> suitability(String propertyId) =>
      GetLocationSuitability(repo).call(propertyId);
  Future<RecommendationExplanation> explanation(String propertyId) =>
      GetRecommendationExplanation(repo).call(propertyId);
}
