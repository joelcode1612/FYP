/// Wire → entity mapping for the research model metadata endpoint.
///
/// `/api/v1/ml/model` is decoded here. The backend owns the model, its feature
/// names and its thresholds; this mapper only maps those fields onto the
/// domain entity without recomputing anything.
library;

import '../../domain/entities/full_analysis.dart';

abstract final class FullAnalysisMapper {
  static ResearchModelMetadata modelMetadata(Map<String, dynamic> response) =>
      ResearchModelMetadata.fromJson(response);
}
