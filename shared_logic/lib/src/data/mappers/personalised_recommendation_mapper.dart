/// Wire → entity mapping for the personalised-recommendation pipeline.
///
/// The backend owns ranking and explanation content; this mapper only decodes
/// the response shapes. It is the data-layer entry point used by the live
/// repository, so entity factories remain a compatibility surface only.
library;

import '../../domain/entities/personalised_recommendations.dart';

abstract final class PersonalisedRecommendationMapper {
  static GeneratedBatch? batch(Map<String, dynamic> response) {
    if (response['available'] != true) return null;
    final value = response['batch'];
    if (value is! Map<String, dynamic>) return null;
    return GeneratedBatch.fromJson(value);
  }

  static PersonalisedExplanation explanation(Map<String, dynamic> response) =>
      PersonalisedExplanation.fromJson(response);
}
