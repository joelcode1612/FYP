import '../entities/pu_prediction.dart';
import '../entities/pu_feature_coverage.dart';

abstract class PuPredictionRepository {
  Future<PuPrediction> getPropertyPrediction(String propertyId);
  Future<PuFeatureCoverage> getPropertyCoverage(String propertyId);
}
