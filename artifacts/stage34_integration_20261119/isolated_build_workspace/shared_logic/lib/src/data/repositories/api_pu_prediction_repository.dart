import '../../core/network/api_client.dart';
import '../../domain/entities/full_analysis.dart';
import '../../domain/entities/pu_feature_coverage.dart';
import '../../domain/entities/pu_prediction.dart';
import '../../domain/repositories/pu_prediction_repository.dart';

/// Live [PuPredictionRepository] over the authenticated read-only research
/// endpoints (`backend/src/sitewise/api/v1/ml_predictions.py`).
///
/// Transport only: the backend resolves features, runs the saved artifact and
/// labels every score research-only. A non-2xx response throws with the
/// backend's own `detail` sentence. An unavailable artifact or missing features
/// is a successful `available: false` payload, not a transport error.
class ApiPuPredictionRepository implements PuPredictionRepository {
  final ApiClient _client;

  ApiPuPredictionRepository(this._client);

  @override
  Future<ResearchModelMetadata> modelMetadata() async =>
      ResearchModelMetadata.fromJson(await _client.get('/api/v1/ml/model'));

  @override
  Future<PuPrediction> getPropertyPrediction(String propertyId) async =>
      PuPrediction.fromJson(
        await _client.get(
          '/api/v1/ml/properties/${Uri.encodeComponent(propertyId)}/prediction',
        ),
      );

  @override
  Future<PuFeatureCoverage> getPropertyCoverage(String propertyId) async =>
      PuFeatureCoverage.fromJson(
        await _client.get(
          '/api/v1/ml/properties/${Uri.encodeComponent(propertyId)}/coverage',
        ),
      );
}
