import '../entities/recommendation_search.dart';

/// Server-side recommendation search.
///
/// One implementation serves both apps (`ApiRecommendationSearchRepository`);
/// tests substitute a fake through the composition root. The repository never
/// re-ranks: it returns the page exactly as the backend ordered it, which is
/// what keeps web and mobile on one algorithm.
abstract class RecommendationSearchRepository {
  /// Runs one search page. A `cursor` in [request] fetches the next page of
  /// the same ranking; the backend rejects a cursor from a different search
  /// instead of silently returning the wrong slice.
  Future<RecommendationSearchPage> search(RecommendationSearchRequest request);

  /// Filter vocabulary (states, property types, numeric ranges) read from the
  /// catalogue, so an option can never match zero listings.
  Future<RecommendationFacets> facets();
}
