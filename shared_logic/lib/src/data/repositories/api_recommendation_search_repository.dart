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
  Future<RecommendationFacets> facets() async {
    final response = await _client.get('/api/v1/recommendations/facets');
    final data = response['data'];
    return RecommendationFacets.fromJson(
      data is Map<String, dynamic> ? data : const {},
    );
  }
}
