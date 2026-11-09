import '../../core/network/api_client.dart';
import '../../domain/entities/explore.dart';
import '../../domain/repositories/explore_repository.dart';
import '../mappers/explore_property_mapper.dart';

/// Live [ExploreRepository] over the authenticated FastAPI `/api/v1/explore/*`
/// endpoints (`fyp.rental_properties`, approved + published rows only).
///
/// Depends only on the abstract [ApiClient] port: pure Dart, browser-safe.
/// The platform supplies the bearer-aware client; the backend enforces
/// authentication and the published/approved gate. Property ids here are
/// `fyp.rental_properties` numeric ids — a different universe from the
/// imported catalogue's `EP-xxxxx`/`MD-xxxxx` ids.
///
/// Failure contract: a non-2xx response throws from the transport (the same
/// behaviour every other Api repository in this package relies on). HTTP
/// status classification stays with the platform's detailed-response client,
/// because the shared [ApiClient] port deliberately carries no status code.
class ApiExploreRepository implements ExploreRepository {
  final ApiClient _client;

  ApiExploreRepository(this._client);

  /// The backend caps `limit` at 100 (`Query(le=100)`); 24 matches the UI's
  /// page size and keeps each response light.
  static const int defaultPageSize = 24;

  /// Radii the backend accepts (`_ALLOWED_RADII_M`); anything else is a 422.
  static const List<int> allowedRadiiM = [250, 500, 1000];

  @override
  Future<ExploreFilterOptions> filterOptions() async {
    final response = await _client.get('/api/v1/explore/options');
    return ExplorePropertyMapper.filterOptions(
      (response['data'] as Map?)?.cast<String, dynamic>() ?? const {},
    );
  }

  @override
  Future<ExplorePage> search(ExploreQuery query) async {
    final response = await _client.get(
      '/api/v1/explore/properties',
      query: query.toQueryMap(),
    );
    final meta = (response['meta'] as Map?)?.cast<String, dynamic>() ?? const {};
    final items = [
      for (final row
          in (response['data'] as List? ?? const [])
              .whereType<Map<String, dynamic>>())
        ExplorePropertyMapper.property(row),
    ];
    return ExplorePage(
      items: List.unmodifiable(items),
      total: (meta['total'] as num?)?.toInt() ?? items.length,
      limit: (meta['limit'] as num?)?.toInt() ?? query.limit,
      offset: (meta['offset'] as num?)?.toInt() ?? query.offset,
    );
  }

  @override
  Future<ExplorePropertyDetail> detail(String propertyId) async {
    // The id is a path segment built from the explore row, which is always
    // numeric in this universe. Encode anyway so a non-numeric id can never
    // alter the path shape.
    final response = await _client.get(
      '/api/v1/explore/properties/${Uri.encodeComponent(propertyId)}',
    );
    final payload = (response['data'] as Map?)?.cast<String, dynamic>();
    if (payload == null) {
      throw const NotFoundShape();
    }
    return ExplorePropertyMapper.detail(payload);
  }

  @override
  Future<NearbyOutlets> competitors(String propertyId, {int radiusM = 500}) async {
    _assertRadius(radiusM);
    final response = await _client.get(
      '/api/v1/explore/properties/${Uri.encodeComponent(propertyId)}/competitors',
      query: {'radius_m': '$radiusM'},
    );
    return ExplorePropertyMapper.outlets(response);
  }

  @override
  Future<NearbyDemandGenerators> demandGenerators(
    String propertyId, {
    int radiusM = 1000,
  }) async {
    _assertRadius(radiusM);
    final response = await _client.get(
      '/api/v1/explore/properties/${Uri.encodeComponent(propertyId)}/demand-generators',
      query: {'radius_m': '$radiusM'},
    );
    return ExplorePropertyMapper.demandGenerators(response);
  }

  static void _assertRadius(int radiusM) {
    if (!allowedRadiiM.contains(radiusM)) {
      throw ArgumentError.value(
        radiusM,
        'radiusM',
        'must be one of $allowedRadiiM (backend refuses other values with 422)',
      );
    }
  }
}

/// Thrown when the detail endpoint answers without a data payload — the
/// closest the shared port can express "the backend did not return a
/// property" without carrying HTTP status codes.
class NotFoundShape implements Exception {
  const NotFoundShape();

  @override
  String toString() => 'The backend returned no property payload.';
}
