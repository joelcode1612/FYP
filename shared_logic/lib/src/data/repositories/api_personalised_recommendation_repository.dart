import '../../core/network/api_client.dart';
import '../../domain/entities/personalised_recommendations.dart';
import '../../domain/repositories/personalised_recommendation_repository.dart';
import '../mappers/personalised_recommendation_mapper.dart';

/// Live client for the Layer 2/3 personalised recommendation pipeline.
///
/// * `generate` - `POST /api/v1/recommendations/generate` ranks the eligible
///   research catalogue against the entrepreneur's SAVED preferences
///   (ownership always comes from the authenticated token; no user id is
///   ever sent).
/// * `latest` - `GET /api/v1/recommendations/me/generated` retrieves the
///   most recent stored batch (durable across restarts).
/// * `explanation` - `GET /api/v1/recommendations/{result_id}/explanation`
///   returns the two separated explanation sections (rule-based preference
///   reasons and the PU model's optional SHAP payload).
///
/// Failures propagate as exceptions for the notifier to map onto its error
/// state; nothing is substituted or fabricated here.
class ApiPersonalisedRecommendationRepository
    implements PersonalisedRecommendationRepository {
  final ApiClient _client;

  const ApiPersonalisedRecommendationRepository(this._client);

  Future<Map<String, dynamic>> generate({
    int limit = 20,
    String? state,
    List<String>? propertyIds,
  }) async {
    return _client.post('/api/v1/recommendations/generate', {
      'limit': limit,
      if (state != null && state.isNotEmpty) 'state': state,
      if (propertyIds != null) 'property_ids': propertyIds,
    });
  }

  /// Returns null when no batch exists for the account yet.
  Future<GeneratedBatch?> latest() async {
    final response = await _client.get('/api/v1/recommendations/me/generated');
    return PersonalisedRecommendationMapper.batch(response);
  }

  Future<PersonalisedExplanation> explanation(String resultId) async {
    final response =
        await _client.get('/api/v1/recommendations/$resultId/explanation');
    return PersonalisedRecommendationMapper.explanation(response);
  }
}
