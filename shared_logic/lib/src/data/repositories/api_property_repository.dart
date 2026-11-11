import '../../core/errors/app_failure.dart';
import '../../core/network/api_client.dart';
import '../../domain/entities/commercial_property.dart';
import '../../domain/repositories/property_repository.dart';
import '../mappers/catalog_property_mapper.dart';

/// Live [PropertyRepository] over the authenticated `/api/v1/catalog/*`
/// endpoints (`sitewise_app.properties` — the imported research catalogue).
///
/// Why the catalogue and not `fyp.rental_properties`: the ranked recommendation
/// page returns CATALOGUE ids (`EP-xxxxx` / `MD-xxxxx`), and so do the saved
/// shortlist, the assessment workspace and the PU model. If detail / saved /
/// compare read a different id universe, every ranked card would open a
/// "not found" screen and the shortlist would silently empty itself. One id
/// space, one source.
///
/// The list endpoint caps `limit` at 200, so [getProperties] pages through the
/// whole catalogue with a bounded worker pool — never an unbounded burst.
///
/// Failure contract: a non-2xx throws from the transport, a 200 with the wrong
/// envelope throws [ResponseFormatFailure], and a 404 on a detail read throws
/// [NotFoundFailure]. The UI can therefore tell "no records" from "the service
/// failed", which is exactly what it could not do against the demo repository.
class ApiPropertyRepository implements PropertyRepository {
  final ApiClient _client;

  ApiPropertyRepository(this._client);

  /// Backend maximum for one page (`Query(le=200)`).
  static const int pageSize = 200;

  /// Bounded concurrency: enough to overlap latency, low enough that a phone
  /// never opens a dozen sockets to FastAPI at once.
  static const int maxConcurrentPages = 4;

  Future<List<CommercialProperty>>? _cached;

  /// Drops the in-memory copy so the next read hits the network.
  ///
  /// The catalogue is a research dataset, not a live feed, so caching it for
  /// the session is correct; a user-initiated refresh must still be able to
  /// bypass it.
  void invalidate() => _cached = null;

  @override
  Future<List<CommercialProperty>> getProperties() async {
    try {
      return await (_cached ??= _load());
    } catch (_) {
      // A failed load must not be cached: the next attempt has to retry the
      // network, otherwise one dropped connection poisons the whole session.
      _cached = null;
      rethrow;
    }
  }

  @override
  Future<CommercialProperty?> getPropertyById(String id) async {
    if (id.isEmpty) return null;
    try {
      final response = await _client.get(
        '/api/v1/catalog/properties/${Uri.encodeComponent(id)}',
      );
      // The detail endpoint returns the row directly (no `data` envelope).
      final row = response['data'] is Map
          ? (response['data'] as Map).cast<String, dynamic>()
          : response;
      if (row['id'] == null) {
        throw const ResponseFormatFailure(
          'The property record returned by the service could not be read.',
        );
      }
      return CatalogPropertyMapper.fromJson(row);
    } on NotFoundFailure {
      return null;
    }
  }

  /// Owner-scoped writes belong to the listing workflow
  /// (`ApiOwnerListingRepository` / `/api/v1/properties/listings`), which owns
  /// the verification lifecycle. A catalogue row is research data and is not
  /// writable from the client, so these are explicit failures rather than
  /// silent no-ops that would look like a successful save.
  @override
  Future<CommercialProperty> createProperty(CommercialProperty property) async =>
      throw const ServiceFailure(
        'Property records are created through the listing workflow, not the '
        'catalogue.',
      );

  @override
  Future<void> updateProperty(CommercialProperty property) async =>
      throw const ServiceFailure(
        'Catalogue records are read-only; edit the owner listing instead.',
      );

  @override
  Future<void> submitForVerification(String id) async =>
      throw const ServiceFailure(
        'Verification is submitted through the listing workflow.',
      );

  @override
  Future<void> updateVerification(String id, VerificationStatus status) async =>
      throw const ServiceFailure(
        'Verification status is owned by the administrator review queue.',
      );

  @override
  Future<List<CommercialProperty>> getPropertiesByOwner(String ownerId) async =>
      // Imported catalogue rows have no owner. Returning an empty list here
      // would read as "this owner has nothing"; the owner's real records come
      // from `ApiOwnerListingRepository.myListings()`.
      const <CommercialProperty>[];

  Future<List<CommercialProperty>> _load() async {
    final first = await _client.get(
      '/api/v1/catalog/properties',
      query: const {'limit': '$pageSize', 'offset': '0'},
    );
    final firstPage = _rows(first);
    final meta = (first['meta'] as Map?)?.cast<String, dynamic>() ?? const {};
    final total = (meta['total'] as num?)?.toInt() ?? firstPage.length;
    final remainingPages = (total - 1) ~/ pageSize;
    if (remainingPages <= 0) return List.unmodifiable(firstPage);

    // Results are written at their offset, so completion order can never
    // shuffle the catalogue.
    final pages = List<List<CommercialProperty>?>.filled(remainingPages, null);
    final workerCount = remainingPages < maxConcurrentPages
        ? remainingPages
        : maxConcurrentPages;

    Future<void> worker(int index) async {
      for (var page = index; page < remainingPages; page += workerCount) {
        final offset = (page + 1) * pageSize;
        final response = await _client.get(
          '/api/v1/catalog/properties',
          query: {'limit': '$pageSize', 'offset': '$offset'},
        );
        pages[page] = _rows(response);
      }
    }

    await Future.wait([
      for (var i = 0; i < workerCount; i++) worker(i),
    ]);

    return List.unmodifiable([
      ...firstPage,
      for (final page in pages) ...?page,
    ]);
  }

  List<CommercialProperty> _rows(Map<String, dynamic> response) {
    final raw = response['data'];
    if (raw is! List) {
      // A 200 with the wrong envelope is a contract failure, not an empty
      // catalogue. Without this the screen would claim there are no listings.
      throw const ResponseFormatFailure(
        'The property list returned by the service could not be read.',
      );
    }
    final items = <CommercialProperty>[];
    for (final row in raw.whereType<Map<String, dynamic>>()) {
      try {
        items.add(CatalogPropertyMapper.fromJson(row));
      } on Object {
        throw const ResponseFormatFailure(
          'A property record returned by the service could not be read.',
        );
      }
    }
    return items;
  }
}
