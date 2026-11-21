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

  /// Filter vocabulary (states, property types, contextual rental/size
  /// intervals, counts and relaxations) read from the same eligible catalogue
  /// the search ranks. With [criteria], the backend applies every other hard
  /// filter and releases each facet's own constraint (leave-one-out); with no
  /// criteria it describes the full eligible population.
  Future<RecommendationFacets> facets({RecommendationSearchRequest? criteria});
}
