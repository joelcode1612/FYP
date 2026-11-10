import 'package:shared_logic/shared_logic.dart';
import 'package:test/test.dart';

/// Live Explore repository contract over the authenticated FastAPI endpoint.
///
/// The transport is a fake [ApiClient] (no network, no Supabase, no DB), but
/// every row here is the shape the development database actually returns for
/// `fyp.rental_properties` — including PostgreSQL `numeric` columns encoded
/// as JSON strings. This is the regression guard for the mobile Listing page
/// showing "Unable to load properties" on a 200 response.
class _FakeApiClient implements ApiClient {
  Map<String, dynamic> response;
  Map<String, String>? lastQuery;
  String? lastPath;

  _FakeApiClient(this.response);

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async {
    lastPath = path;
    lastQuery = query;
    return response;
  }

  @override
  Future<Map<String, dynamic>> post(String path, Map<String, dynamic> body) =>
      throw UnimplementedError();

  @override
  Future<Map<String, dynamic>> patch(String path, Map<String, dynamic> body) =>
      throw UnimplementedError();

  @override
  Future<Map<String, dynamic>> delete(String path) =>
      throw UnimplementedError();

  @override
  Future<Map<String, dynamic>> uploadMultipart(
    String path, {
    required Map<String, String> fields,
    required String fileField,
    required String filename,
    required List<int> bytes,
    required String contentType,
  }) => throw UnimplementedError();

  @override
  Future<List<int>> downloadBinary(String path) => throw UnimplementedError();
}

Map<String, dynamic> _realRow() => <String, dynamic>{
  'property_id': 315,
  'name': 'One Puchong Ground + Basement Retail',
  'property_type': 'Shop',
  'description': null,
  'address': 'Jalan OP, One Puchong, Bandar Puchong Jaya, Puchong, Selangor',
  'city': 'Puchong',
  'state': 'Selangor',
  'latitude': 3.018,
  'longitude': 101.624,
  'rental_price': '6000.00',
  'size_sqft': '3000.00',
  'psf': '2.00',
  'availability': 'Available Now',
  'tenure': 'NULL',
  'furnishing': 'Partially Furnished',
  'floor_level': null,
  'bathrooms': '2.0',
  'is_fnb_suitable': 1,
  'has_parking': 0,
  'is_corner_lot': 0,
  'is_freehold': 0,
  'verification_status': 'approved',
  'is_published': true,
  'primary_image': null,
  'competitor_count_500m': 7,
  'competitor_count_1km': 11,
  'population_500m': '12000.5',
  'accessibility_score': '64.25',
  'overall_location_score': '71.0',
  'has_research_link': false,
  'nearby_property_count': 4,
};

void main() {
  group('ApiExploreRepository.search', () {
    test('maps real fyp.rental_properties rows and preserves the numeric id',
        () async {
      final client = _FakeApiClient(<String, dynamic>{
        'data': [_realRow()],
        'meta': <String, dynamic>{'total': 227, 'limit': 24, 'offset': 0},
      });
      final page = await ApiExploreRepository(client).search(
        const ExploreQuery(),
      );

      expect(client.lastPath, '/api/v1/explore/properties');
      expect(page.total, 227);
      expect(page.hasMore, isTrue);
      expect(page.items, hasLength(1));
      final property = page.items.single;
      expect(property.id, '315'); // numeric FYP id, never remapped to EP-xxx
      expect(property.rentalRm, 6000.0);
      expect(property.sizeSqft, 3000.0);
      expect(property.nearbyPropertyCount, 4);
      expect(property.imageUrl, isNull); // SQL NULL, no placeholder URL
      expect(property.tenure, isNull); // literal "NULL" text artifact
      expect(property.hasSuitabilityScore, isTrue);
    });

    test('sends the spatial filter parameters when the rule is active',
        () async {
      final client = _FakeApiClient(<String, dynamic>{
        'data': <dynamic>[],
        'meta': <String, dynamic>{'total': 0, 'limit': 24, 'offset': 0},
      });
      final page = await ApiExploreRepository(client).search(
        const ExploreQuery(
          nearbyOnly: true,
          minNearbyProperties: 3,
          nearbyRadiusM: 500,
        ),
      );

      expect(client.lastQuery?['min_nearby_properties'], '3');
      expect(client.lastQuery?['nearby_radius_m'], '500');
      expect(page.total, 0);
      expect(page.items, isEmpty); // a real empty result, not an error
      expect(page.hasMore, isFalse);
    });

    test('omits the spatial filter entirely when the rule is off', () async {
      final client = _FakeApiClient(<String, dynamic>{
        'data': <dynamic>[],
        'meta': <String, dynamic>{'total': 227, 'limit': 24, 'offset': 0},
      });
      await ApiExploreRepository(client).search(const ExploreQuery());

      expect(client.lastQuery?.containsKey('min_nearby_properties'), isFalse);
      expect(client.lastQuery?.containsKey('nearby_radius_m'), isFalse);
      expect(client.lastQuery?['limit'], '24');
    });

    test('a malformed data payload is a contract failure, not a network one',
        () async {
      final client = _FakeApiClient(<String, dynamic>{
        'data': 'not-a-list',
        'meta': <String, dynamic>{'total': 0},
      });
      await expectLater(
        ApiExploreRepository(client).search(const ExploreQuery()),
        throwsA(isA<ResponseFormatFailure>()),
      );
    });
  });
}
