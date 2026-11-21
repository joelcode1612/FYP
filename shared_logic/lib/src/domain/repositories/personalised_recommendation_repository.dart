/// Personalised (Layer 2/3) recommendation pipeline contract.
///
/// The implementation talks to `/api/v1/recommendations/*`; the application
/// layer only needs to generate a batch, read the account's latest stored
/// batch and fetch the separated explanation for one result.
library;

import '../entities/personalised_recommendations.dart';

abstract class PersonalisedRecommendationRepository {
  /// Ownership always comes from the authenticated session — no user id is
  /// accepted here. Returns the raw envelope so each app can decide how much
  /// of the response it surfaces.
  Future<Map<String, dynamic>> generate({
    int limit = 20,
    String? state,
    List<String>? propertyIds,
  });

  /// `null` when the account has no stored batch yet.
  Future<GeneratedBatch?> latest();

  Future<PersonalisedExplanation> explanation(String resultId);
}
