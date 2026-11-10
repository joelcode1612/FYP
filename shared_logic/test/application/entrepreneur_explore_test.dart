import 'dart:async';

import 'package:riverpod/riverpod.dart';
import 'package:shared_logic/shared_logic.dart';
import 'package:test/test.dart';

/// Server-driven Explore tests: the mobile Listing integration contract.
///
/// These protect the twelve behaviours the Priority-1 integration brief
/// demands: distinct failure classes (backend down / unauthorized / server /
/// malformed contract / genuine empty), criteria-driven search with the
/// backend's whitelisted parameters, pagination with stale-response and
/// duplicate protection, filter-option sourcing, property-id fidelity, and
/// the rule that a live-mode failure never falls back to demo data.
void main() {
  group('EntrepreneurController (server-driven Explore)', () {
    late ProviderContainer container;
    late FakeExploreRepository repo;

    setUp(() {
      repo = FakeExploreRepository();
      container = ProviderContainer(
        overrides: [
          getPropertiesProvider.overrideWithValue(
            GetProperties(_FakePropertyRepository()),
          ),
          getRecommendationsProvider.overrideWithValue(
            GetRecommendations(_FakeRecommendationRepository()),
          ),
          getLocationAnalysisProvider.overrideWithValue(
            GetLocationAnalysis(_FakeRecommendationRepository()),
          ),
          businessPreferencesProvider.overrideWithValue(
            DemoData.defaultPreferences,
          ),
          exploreRepositoryProvider.overrideWithValue(repo),
        ],
      );
      // autoDispose: hold the listener so the notifier survives between reads.
      container.listen(entrepreneurNotifierProvider, (_, _) {});
    });

    tearDown(() => container.dispose());

    EntrepreneurState read() => container.read(entrepreneurNotifierProvider);
    EntrepreneurNotifier notifier() =>
        container.read(entrepreneurNotifierProvider.notifier);

    test('successful listing publishes rows, total and hasMore', () async {
      repo.nextPages = [
        ExplorePage(
          items: [_prop('101'), _prop('102')],
          total: 5,
          limit: 2,
          offset: 0,
        ),
      ];
      await notifier().loadExplore();
      final s = read();
      expect(s.explore, hasLength(2));
      expect(s.exploreTotal, 5);
      expect(s.exploreHasMore, isTrue);
      expect(s.error, isNull);
      expect(s.exploreFailure, isNull);
      expect(s.loading, isFalse);
    });

    test('successful zero-result response is empty, not an error', () async {
      repo.nextPages = [
        const ExplorePage(items: [], total: 0, limit: 24, offset: 0),
      ];
      await notifier().loadExplore();
      final s = read();
      expect(s.explore, isEmpty);
      expect(s.error, isNull);
      expect(s.exploreFailure, isNull);
      expect(s.exploreTotal, 0);
      expect(s.loading, isFalse);
    });

    test('backend unavailable is classified as a network failure', () async {
      repo.nextError = const NetworkFailure(
        'Could not connect to the Sitewise service.',
      );
      await notifier().loadExplore();
      final s = read();
      expect(s.explore, isEmpty);
      expect(s.error, NetworkFailure().userMessage);
      expect(s.exploreFailure, isA<NetworkFailure>());
    });

    test('unauthorized response is distinguished from a connection problem',
        () async {
      repo.nextError = const UnauthorizedFailure();
      await notifier().loadExplore();
      final s = read();
      expect(s.error, 'Your session has expired. Please sign in again.');
      expect(s.exploreFailure, isA<UnauthorizedFailure>());
    });

    test('malformed contract response is classified, not shown as empty',
        () async {
      repo.nextError = const ResponseFormatFailure('not JSON');
      await notifier().loadExplore();
      final s = read();
      expect(s.error, isNotNull);
      expect(s.exploreFailure, isA<ResponseFormatFailure>());
      expect(s.explore, isEmpty);
    });

    test('a live failure never falls back to demo data', () async {
      repo.nextError = const NetworkFailure();
      await notifier().loadExplore();
      // The demo store has properties; the live path must surface the error
      // with an empty list instead of silently substituting them.
      expect(read().error, isNotNull);
      expect(read().explore, isEmpty);
    });

    test('filter options are loaded once from the same backend source',
        () async {
      repo.nextPages = [
        ExplorePage(items: [_prop('101')], total: 1, limit: 24, offset: 0),
      ];
      repo.nextOptions = const ExploreFilterOptions(
        states: ['Selangor'],
        cities: ['Kuala Lumpur'],
        propertyTypes: ['Shop'],
        availability: ['Available'],
        publishedTotal: 7,
      );
      await notifier().loadExplore();
      expect(read().filterOptions?.cities, ['Kuala Lumpur']);
      expect(repo.optionsRequests, 1);
      // A second load must not re-fetch the facets.
      await notifier().loadExplore();
      expect(repo.optionsRequests, 1);
    });

    test('search and sort parameters travel inside the server criteria',
        () async {
      repo.nextPages = [
        const ExplorePage(items: [], total: 0, limit: 24, offset: 0),
      ];
      await notifier().loadExplore();
      notifier().setExploreCriteria(
        ExploreQuery.fromCriteria(
          city: 'Kuala Lumpur',
          propertyType: 'Shop',
          maxPrice: 8500,
          minSize: 800,
          fnbSuitable: true,
          sort: ExploreSortOption.priceAsc,
        ),
      );
      await container.pump();
      final sent = repo.lastQuery!;
      expect(sent.city, 'Kuala Lumpur');
      expect(sent.propertyType, 'Shop');
      expect(sent.maxPrice, 8500);
      expect(sent.minSize, 800);
      expect(sent.fnbSuitable, isTrue);
      expect(sent.sort, ExploreSortOption.priceAsc);
      final map = sent.toQueryMap();
      expect(map['city'], 'Kuala Lumpur');
      expect(map['property_type'], 'Shop');
      expect(map['max_price'], '8500');
      expect(map['min_size'], '800');
      expect(map['fnb_suitable'], 'true');
      expect(map['sort'], 'price_asc');
    });

    test('free-text query is debounced by the UI but never lost: setQuery '
        're-runs the search with the term', () async {
      repo.nextPages = [
        ExplorePage(items: [_prop('103')], total: 1, limit: 24, offset: 0),
      ];
      notifier().setQuery('103');
      await container.pump();
      expect(read().query, '103');
      expect(repo.lastQuery!.query, '103');
      expect(read().explore, hasLength(1));
    });

    test('loadMore appends the next page and advances the offset', () async {
      repo.nextPages = [
        ExplorePage(
          items: [_prop('101'), _prop('102')],
          total: 5,
          limit: 2,
          offset: 0,
        ),
        ExplorePage(
          items: [_prop('103'), _prop('104')],
          total: 5,
          limit: 2,
          offset: 2,
        ),
      ];
      await notifier().loadExplore();
      await notifier().loadMore();
      final s = read();
      expect(s.explore, hasLength(4));
      expect(s.exploreTotal, 5);
      expect(s.exploreHasMore, isTrue);
      expect(repo.lastQuery!.offset, 2);
      // Third page closes the result set.
      repo.nextPages = [
        ExplorePage(items: [_prop('105')], total: 5, limit: 2, offset: 4),
      ];
      await notifier().loadMore();
      expect(read().explore, hasLength(5));
      expect(read().exploreHasMore, isFalse);
    });

    test('loadMore never duplicates rows the server resends', () async {
      final row = _prop('101');
      repo.nextPages = [
        ExplorePage(items: [row], total: 2, limit: 1, offset: 0),
        ExplorePage(items: [row, _prop('102')], total: 2, limit: 1, offset: 1),
      ];
      await notifier().loadExplore();
      await notifier().loadMore();
      expect(
        read().explore.map((p) => p.id).toSet().length,
        read().explore.length,
      );
      expect(read().explore, hasLength(2));
    });

    test('changing filters during an in-flight request keeps only the newest '
        'response', () async {
      final first = Completer<ExplorePage>();
      repo.gate = first;
      repo.nextPages = [
        ExplorePage(items: [_prop('201')], total: 1, limit: 24, offset: 0),
      ];
      final slow = notifier().loadExplore();
      // The second request completes before the first.
      notifier().setExploreCriteria(
        ExploreQuery.fromCriteria(city: 'Kuala Lumpur'),
      );
      await container.pump();
      expect(repo.queries, hasLength(2));
      // Release the stale response; it must be discarded by sequence number.
      first.complete(
        ExplorePage(items: [_prop('999')], total: 1, limit: 24, offset: 0),
      );
      await slow;
      await container.pump();
      final s = read();
      expect(s.exploreCriteria.city, 'Kuala Lumpur');
      expect(s.explore.map((p) => p.id), isNot(contains('999')));
      expect(s.error, isNull);
    });

    test('changing criteria resets pagination to the first page', () async {
      repo.nextPages = [
        ExplorePage(
          items: [_prop('101'), _prop('102')],
          total: 9,
          limit: 2,
          offset: 0,
        ),
      ];
      await notifier().loadExplore();
      // Page beyond the first: the offset must reset when filters change.
      notifier().setExploreCriteria(
        ExploreQuery.fromCriteria(maxPrice: 3000),
      );
      await container.pump();
      expect(repo.lastQuery!.offset, 0);
      expect(repo.lastQuery!.maxPrice, 3000);
    });

    test('property ids keep the backend numeric identity verbatim',
        () async {
      repo.nextPages = [
        ExplorePage(items: [_prop('4711')], total: 1, limit: 24, offset: 0),
      ];
      await notifier().loadExplore();
      expect(read().explore.single.id, '4711');
    });
  });

  group('ApiExploreRepository contract', () {
    late FakeApiClient client;
    late ApiExploreRepository repo;

    setUp(() {
      client = FakeApiClient();
      repo = ApiExploreRepository(client);
    });

    test('search sends the whitelisted query parameters', () async {
      client.nextResponse = {
        'data': [_row('101')],
        'meta': {'total': 42, 'limit': 24, 'offset': 0},
      };
      final page = await repo.search(
        const ExploreQuery(
          query: 'kebab',
          city: 'Kuala Lumpur',
          minPrice: 1000,
          sort: ExploreSortOption.priceDesc,
          limit: 24,
        ),
      );
      expect(client.lastPath, '/api/v1/explore/properties');
      expect(client.lastQueryMap!['q'], 'kebab');
      expect(client.lastQueryMap!['city'], 'Kuala Lumpur');
      expect(client.lastQueryMap!['min_price'], '1000');
      expect(client.lastQueryMap!['sort'], 'price_desc');
      expect(page.total, 42);
      expect(page.items.single.id, '101');
    });

    test('filter options parse the /options payload', () async {
      client.nextResponse = {
        'data': {
          'states': ['Selangor'],
          'cities': ['Shah Alam'],
          'property_types': ['Cafe'],
          'availability': ['Available'],
          'published_total': 12,
        },
      };
      final options = await repo.filterOptions();
      expect(client.lastPath, '/api/v1/explore/options');
      expect(options.publishedTotal, 12);
      expect(options.propertyTypes, ['Cafe']);
    });

    test('detail maps photos, amenities and the numeric id', () async {
      client.nextResponse = {
        'data': {
          ..._row('77'),
          'photos': [
            {'url': 'https://example.test/a.jpg', 'is_primary': true},
          ],
          'amenities': {'suitable_for': 'F&B'},
          'listing_sources': [],
        },
      };
      final detail = await repo.detail('77');
      expect(client.lastPath, '/api/v1/explore/properties/77');
      expect(detail.property.id, '77');
      expect(detail.primaryImageUrl, 'https://example.test/a.jpg');
      expect(detail.amenities?.suitableFor, 'F&B');
    });

    test('detail without a data payload throws NotFoundShape', () async {
      client.nextResponse = {'detail': 'nope'};
      expect(() => repo.detail('1'), throwsA(isA<NotFoundShape>()));
    });
  });
}

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

/// Minimal explore row in the exact shape `FypPropertyRepository.list_published`
/// emits (subset of columns the mapper reads).
Map<String, dynamic> _row(String id) => {
  'property_id': int.parse(id),
  'name': 'Listing $id',
  'address': '$id Jalan Test',
  'city': 'Kuala Lumpur',
  'state': 'Federal Territory',
  'rental_price': 3200,
  'size_sqft': 1400,
  'property_type': 'Shop',
  'verification_status': 'approved',
  'overall_location_score': null,
  'is_fnb_suitable': 1,
};

/// Mapped entity for controller-level tests (single mapping point, exactly
/// as the live repository maps rows).
CommercialProperty _prop(String id) => ExplorePropertyMapper.property(_row(id));

class FakeExploreRepository implements ExploreRepository {
  List<ExplorePage> nextPages = [];
  Object? nextError;
  ExploreFilterOptions? nextOptions;
  ExploreQuery? lastQuery;
  final List<ExploreQuery> queries = [];
  int optionsRequests = 0;

  /// When set, `search` parks on this completer instead of answering, so a
  /// test can interleave a newer request.
  Completer<ExplorePage>? gate;

  @override
  Future<ExploreFilterOptions> filterOptions() async {
    optionsRequests++;
    final options = nextOptions;
    if (options == null) {
      throw const NetworkFailure('options unavailable');
    }
    return options;
  }

  @override
  Future<ExplorePage> search(ExploreQuery query) async {
    queries.add(query);
    lastQuery = query;
    // A gate parks exactly one request (the first), so a test can interleave
    // a newer request behind it.
    final g = gate;
    if (g != null) {
      gate = null;
      return g.future;
    }
    if (nextError != null) throw nextError!;
    if (nextPages.isEmpty) {
      throw StateError('FakeExploreRepository has no scripted page');
    }
    return nextPages.removeAt(0);
  }

  @override
  Future<ExplorePropertyDetail> detail(String propertyId) =>
      throw UnimplementedError();

  @override
  Future<NearbyOutlets> competitors(String propertyId, {int radiusM = 500}) =>
      throw UnimplementedError();

  @override
  Future<NearbyDemandGenerators> demandGenerators(
    String propertyId, {
    int radiusM = 1000,
  }) => throw UnimplementedError();
}

class FakeApiClient implements ApiClient {
  Object? nextResponse;
  String? lastPath;
  Map<String, String>? lastQueryMap;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async {
    lastPath = path;
    lastQueryMap = query;
    final response = nextResponse;
    if (response is Map<String, dynamic>) return response;
    throw StateError('FakeApiClient has no scripted response');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
    '${invocation.memberName} is not scripted in FakeApiClient',
  );
}

class _FakePropertyRepository implements PropertyRepository {
  @override
  Future<CommercialProperty> createProperty(CommercialProperty property) =>
      throw UnimplementedError();

  @override
  Future<CommercialProperty?> getPropertyById(String id) => throw
      UnimplementedError();

  @override
  Future<List<CommercialProperty>> getProperties() async =>
      DemoData.properties;

  @override
  Future<List<CommercialProperty>> getPropertiesByOwner(String ownerId) async =>
      const [];

  @override
  Future<void> submitForVerification(String id) => throw UnimplementedError();

  @override
  Future<void> updateProperty(CommercialProperty property) =>
      throw UnimplementedError();

  @override
  Future<void> updateVerification(String id, VerificationStatus status) =>
      throw UnimplementedError();
}

class _FakeRecommendationRepository implements RecommendationRepository {
  @override
  Future<List<PropertyRecommendation>> getRecommendations(
    BusinessPreferences prefs,
  ) async => const [];

  @override
  Future<LocationAnalysis> getLocationAnalysis(String propertyId) async =>
      LocationAnalysis(
        propertyId: propertyId,
        suitabilityScore: 0,
        factors: const [],
        competitorCount: 0,
        demandSummary: '',
        socioeconomicSummary: '',
      );
}
