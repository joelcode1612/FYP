import '../../domain/entities/pu_prediction.dart';
import '../../domain/entities/pu_feature_coverage.dart';
import '../../domain/repositories/pu_prediction_repository.dart';

class GetPuPrediction {
  final PuPredictionRepository repository;
  const GetPuPrediction(this.repository);

  Future<PuPrediction> call(String propertyId) =>
      repository.getPropertyPrediction(propertyId);
}

class GetPuFeatureCoverage {
  final PuPredictionRepository repository;
  const GetPuFeatureCoverage(this.repository);

  Future<PuFeatureCoverage> call(String propertyId) =>
      repository.getPropertyCoverage(propertyId);
}
