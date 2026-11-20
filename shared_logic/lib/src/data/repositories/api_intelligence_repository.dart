import '../../domain/entities/location_intelligence.dart';
import '../../domain/entities/recommendation.dart';
import '../../domain/entities/sitewise_records.dart';
import '../../domain/services/location_analysis_rules.dart';
import '../../domain/repositories/intelligence_repositories.dart';
import '../../domain/repositories/recommendation_repository.dart';
import '../../core/network/api_client.dart';

/// Live [LocationIntelligenceRepository] over the authenticated FastAPI
/// `/explore/analysis` endpoint (the cross-universe property analysis in
/// `backend/src/sitewise/api/v1/explore.py`).
///
/// Depends only on the abstract [ApiClient] port: pure Dart, browser-safe.
/// The platform supplies the bearer-aware client; the backend enforces
/// authentication. This class never decides authorization and never calls
/// Supabase directly.
///
/// Transport only: this class reads the payload and hands it to
/// [LocationAnalysisRules], which owns the bands, scores and evidence wording.
/// The honesty contract therefore lives there — every figure is a RESEARCH
/// dataset feature (a precomputed geospatial count, a DOSM statistic or the
/// imported workbook's suitability index), never a verified commercial-success
/// probability, and a payload without backing data yields no factor.
class ApiLocationIntelligenceRepository implements LocationIntelligenceRepository {
  final ApiClient _client;

  ApiLocationIntelligenceRepository(this._client);

  /// The backend `analysis` payload for one property reference — either a
  /// `fyp.rental_properties` numeric id or a workbook catalogue id
  /// (`EP-xxxxx` / `MD-xxxxx`). The backend resolves both.
  Future<Map<String, dynamic>> _analysis(String propertyId) async {
    final response = await _client.get(
      '/api/v1/explore/analysis',
      query: {'ref': propertyId},
    );
    // Bare-object payloads pass through the bridge unwrapped; wrapped ones
    // (array-like) arrive as {'data': ...}. The analysis endpoint always
    // returns an object, so read it directly and tolerate the wrapper.
    final payload = response.containsKey('data') && response.containsKey('meta')
        ? response
        : (response['data'] as Map<String, dynamic>? ?? response);
    return payload['data'] as Map<String, dynamic>;
  }

  @override
  Future<LocationAnalysis> getLocationIntelligence(String propertyId) async =>
      LocationAnalysisRules.analyse(propertyId, await _analysis(propertyId));

  @override
  Future<RecommendationExplanation> getExplanation(String propertyId) async =>
      LocationAnalysisRules.explain(await getLocationIntelligence(propertyId));
}

/// [RecommendationRepository] adapter that delegates ranking to one
/// repository and location analysis to the live [LocationIntelligenceRepository].
///
/// This is the composition-root glue for the split the shared package makes:
/// ranking and analysis live on separate contracts, but the
/// [GetLocationAnalysis] use case (and therefore the entrepreneur state
/// owner) consumes a [RecommendationRepository]. Without this adapter a
/// composition root had to wire analysis to a ranking implementation that
/// could only throw.
class IntelligenceBackedRecommendationRepository
    implements RecommendationRepository {
  final RecommendationRepository _ranking;
  final LocationIntelligenceRepository _intelligence;

  IntelligenceBackedRecommendationRepository(this._ranking, this._intelligence);

  @override
  Future<List<PropertyRecommendation>> getRecommendations(
    BusinessPreferences prefs,
  ) => _ranking.getRecommendations(prefs);

  @override
  Future<LocationAnalysis> getLocationAnalysis(String propertyId) =>
      _intelligence.getLocationIntelligence(propertyId);
}
