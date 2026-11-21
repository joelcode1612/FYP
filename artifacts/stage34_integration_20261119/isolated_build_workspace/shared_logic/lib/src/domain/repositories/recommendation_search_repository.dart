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

  /// Filter vocabulary and intervals, counted over the listings [request]
  /// still leaves eligible.
  ///
  /// Each field is priced with all the OTHER hard filters applied and only its
  /// own constraint released, over the same PU-gated population [search]
  /// ranks — so an option can never match zero listings, and a dropdown's
  /// counts move when another input changes. Passing the DRAFT selections
  /// rather than the applied request is what lets the choices update before a
  /// search runs.
  ///
  /// Omitting the request counts over the whole eligible population, which is
  /// the view a first paint can show before the contextual numbers arrive.
  Future<RecommendationFacets> facets([RecommendationSearchRequest? request]);
}
