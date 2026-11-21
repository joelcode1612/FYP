import '../entities/full_analysis.dart';
import '../entities/pu_prediction.dart';
import '../entities/pu_feature_coverage.dart';

abstract class PuPredictionRepository {
  Future<PuPrediction> getPropertyPrediction(String propertyId);
  Future<PuFeatureCoverage> getPropertyCoverage(String propertyId);

  /// The selected artifact's metadata and canonical feature taxonomy. Read-only;
  /// an unavailable artifact is a successful `available: false` response.
  Future<ResearchModelMetadata> modelMetadata();
}
