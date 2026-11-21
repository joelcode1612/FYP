import '../entities/explore.dart';

/// Server-driven Explore contract over the authenticated FastAPI
/// `/api/v1/explore/*` endpoints (`fyp.rental_properties`, approved +
/// published rows only).
///
/// Implementations depend only on the abstract [ApiClient] port, so they stay
/// browser-safe. Authorization is the backend's job; ids here are
/// `fyp.rental_properties` numeric ids — a different universe from the
/// imported catalogue's `EP-xxxxx`/`MD-xxxxx` ids, and never mixed.
abstract class ExploreRepository {
  /// `GET /explore/options` — database-backed filter facets.
  Future<ExploreFilterOptions> filterOptions();

  /// `GET /explore/properties` — one filtered, sorted, paginated page.
  Future<ExplorePage> search(ExploreQuery query);

  /// `GET /explore/properties/{id}` — listing + photos + amenities +
  /// listing sources. Throws [NotFoundFailure]-shaped errors from the
  /// transport when the id is absent or not published; implementations never
  /// return a fabricated placeholder row.
  Future<ExplorePropertyDetail> detail(String propertyId);

  /// `GET /explore/properties/{id}/competitors?radius_m=` — real F&B
  /// competitor outlets (research records, not commercial properties).
  /// Radius must be 250, 500 or 1000 — the backend refuses other values.
  Future<NearbyOutlets> competitors(String propertyId, {int radiusM = 500});

  /// `GET /explore/properties/{id}/demand-generators?radius_m=` — malls,
  /// transit hubs and other demand generators within the radius.
  Future<NearbyDemandGenerators> demandGenerators(
    String propertyId, {
    int radiusM = 1000,
  });
}
