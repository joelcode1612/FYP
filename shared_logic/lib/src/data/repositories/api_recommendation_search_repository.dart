import '../../core/network/api_client.dart';
import '../../domain/entities/recommendation_search.dart';
import '../../domain/repositories/recommendation_search_repository.dart';

/// Live [RecommendationSearchRepository] over
/// `POST /api/v1/recommendations/search` and `GET /api/v1/recommendations/facets`.
///
/// Property ids are CATALOGUE ids (`EP-`/`MD-`), the same space saved
/// properties, assessments and the PU model use — so a ranked card can be
/// saved, assessed and opened without translating its identity.
///
/// The response's `model` block is carried through untouched. When the trained
/// ranker is unavailable the backend says so; this class never substitutes a
/// score of its own.
class ApiRecommendationSearchRepository implements RecommendationSearchRepository {
  final ApiClient _client;

  const ApiRecommendationSearchRepository(this._client);

  @override
  Future<RecommendationSearchPage> search(
    RecommendationSearchRequest request,
  ) async {
    final response = await _client.post(
      '/api/v1/recommendations/search',
      request.toJson(),
    );
    return RecommendationSearchPage.fromJson(response);
  }

  @override
  Future<RecommendationFacets> facets({
    RecommendationSearchRequest? criteria,
  }) async {
    // The facets endpoint takes the same hard-filter vocabulary as search.
    // Business type and target-market preferences are deliberately NOT hard
    // eligibility filters on the backend, so sending them may change nothing;
    // layout preferences are omitted because the GET transport cannot carry
    // repeated keys and the backend does not count them anyway.
    final query = <String, String>{};
    final c = criteria;
    if (c != null) {
      if (c.businessType != null) query['business_type'] = c.businessType!;
      if (c.preferredState != null) {
        query['preferred_state'] = c.preferredState!;
      }
      if (c.preferredArea != null) query['preferred_area'] = c.preferredArea!;
      if (c.minRentalRm != null) query['min_rental_rm'] = '${c.minRentalRm}';
      if (c.maxRentalRm != null) query['max_rental_rm'] = '${c.maxRentalRm}';
      if (c.minSizeSqft != null) query['min_size_sqft'] = '${c.minSizeSqft}';
      if (c.maxSizeSqft != null) query['max_size_sqft'] = '${c.maxSizeSqft}';
      if (c.propertyType != null) query['property_type'] = c.propertyType!;
      if (c.city != null) query['city'] = c.city!;
      if (c.locationLatitude != null) query['location_latitude'] = '${c.locationLatitude}';
      if (c.locationLongitude != null) query['location_longitude'] = '${c.locationLongitude}';
      if (c.nearbyRadiusKm != null) query['nearby_radius_km'] = '${c.nearbyRadiusKm}';
      if (c.floorLevel != null) query['floor_level'] = c.floorLevel!;
      if (c.transitMaxM != null) query['transit_max_m'] = '${c.transitMaxM}';
      if (c.nearbyParkingMin != null) {
        query['nearby_parking_min'] = '${c.nearbyParkingMin}';
      }
      if (c.fnbCompetitionMax != null) {
        query['fnb_competition_max'] = '${c.fnbCompetitionMax}';
      }
      if (c.demandGenerator != null) {
        query['demand_generator'] = c.demandGenerator!;
      }
      if (c.populationMin1000m != null) {
        query['population_min_1000m'] = '${c.populationMin1000m}';
      }
      if (c.populationMax1000m != null) {
        query['population_max_1000m'] = '${c.populationMax1000m}';
      }
      if (c.query != null) query['query'] = c.query!;
      if (c.managedOnly) query['managed_only'] = 'true';
    }
    final response = await _client.get(
      '/api/v1/recommendations/facets',
      query: query,
    );
    final data = response['data'];
    return RecommendationFacets.fromJson(
      data is Map<String, dynamic> ? data : const {},
    );
  }
}
