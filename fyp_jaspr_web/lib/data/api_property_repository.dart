import 'package:shared_logic/shared_logic.dart';
import 'auth_service.dart';

/// Result of a real owner submission (`POST /api/v1/properties/listings`).
///
/// The listing is committed first and enriched second; [enrichmentStatus] tells
/// the UI which of those two steps succeeded, so a spatial failure is reported
/// instead of hidden behind a generic "saved".
class OwnerListingResult {
  const OwnerListingResult({
    required this.propertyId,
    required this.name,
    required this.verificationStatus,
    required this.isPublished,
    required this.enrichmentStatus,
    this.features,
    this.enrichmentDetail,
  });

  final int propertyId;
  final String name;
  final String verificationStatus;
  final bool isPublished;
  final String enrichmentStatus;
  final Map<String, dynamic>? features;
  final String? enrichmentDetail;

  bool get enriched => enrichmentStatus == 'ok';

  int? featureInt(String key) => switch (features?[key]) {
    final num value => value.toInt(),
    _ => null,
  };

  factory OwnerListingResult.fromResponse(Map<String, dynamic> response) {
    final data = (response['data'] as Map?)?.cast<String, dynamic>() ?? const {};
    final enrichment = (response['enrichment'] as Map?)?.cast<String, dynamic>() ?? const {};
    final features = (enrichment['features'] as Map?)?.cast<String, dynamic>();
    return OwnerListingResult(
      propertyId: (data['id'] as num?)?.toInt() ?? 0,
      name: '${data['name'] ?? ''}',
      verificationStatus: '${data['verification_status'] ?? 'pending'}',
      isPublished: data['is_published'] == true,
      enrichmentStatus: '${enrichment['status'] ?? 'failed'}',
      features: features,
      enrichmentDetail: enrichment['detail'] as String?,
    );
  }
}

class ApiPropertyRepository implements PropertyRepository {
  Future<List<CommercialProperty>>? _cached;

  /// Shared mapping lives in `shared_logic` ([CatalogPropertyMapper]); this
  /// static forwarder stays for the assessment workspace, which decodes
  /// catalogue rows through the same mapper.
  static CommercialProperty fromJson(Map<String, dynamic> row) =>
      CatalogPropertyMapper.fromJson(row);

  @override
  Future<List<CommercialProperty>> getProperties() async {
    try {
      return await (_cached ??= _load());
    } catch (_) {
      _cached = null;
      rethrow;
    }
  }

  Future<List<CommercialProperty>> _load() async {
    // Fetch the first page to obtain a consistent total. Do not issue an
    // unbounded burst of simultaneous requests against FastAPI/PostgreSQL.
    const pageSize = 200;
    const maxConcurrentPages = 4;
    final firstResponse = await WebAuth.request(
      '/api/v1/catalog/properties?limit=$pageSize&offset=0',
    );
    final firstRows = (firstResponse['data'] as List)
        .cast<Map<String, dynamic>>();
    final firstPage = firstRows.map(fromJson).toList(growable: false);
    final total = (firstResponse['meta']['total'] as num).toInt();
    final remainingPages = (total - 1) ~/ pageSize;

    if (remainingPages <= 0) return List.unmodifiable(firstPage);

    // A bounded worker pool overlaps HTTP latency. Each batch is written at
    // its offset, so response completion order cannot shuffle property cards.
    final pages = List<List<CommercialProperty>?>.filled(
      remainingPages,
      null,
    );
    final workerCount = remainingPages < maxConcurrentPages
        ? remainingPages
        : maxConcurrentPages;

    Future<void> fetchWorker(int worker) async {
      for (var pageIndex = worker;
          pageIndex < remainingPages;
          pageIndex += workerCount) {
        final offset = (pageIndex + 1) * pageSize;
        final response = await WebAuth.request(
          '/api/v1/catalog/properties?limit=$pageSize&offset=$offset',
        );
        final rows = (response['data'] as List)
            .cast<Map<String, dynamic>>();
        pages[pageIndex] = rows.map(fromJson).toList(growable: false);
      }
    }

    await Future.wait([
      for (var worker = 0; worker < workerCount; worker++)
        fetchWorker(worker),
    ]);
    return List.unmodifiable([
      ...firstPage,
      for (final page in pages) ...page!,
    ]);
  }

  @override
  Future<CommercialProperty?> getPropertyById(String id) async {
    // Single-record read: scanning the paged catalogue for one id wasted up
    // to the full catalogue per detail view and drift-prone against live imports.
    // A 404 (unknown/unpublished id) or any other failure throws from the
    // bridge; callers treat every throw as "not found" — the same contract
    // as before, without the scan.
    try {
      return fromJson(await WebAuth.request('/api/v1/catalog/properties/$id'));
    } on Object {
      return null;
    }
  }

  @override
  Future<List<CommercialProperty>> getPropertiesByOwner(String ownerId) async =>
      [];
  Never _readOnly() => throw UnsupportedError(
    'Imported research properties are read-only. Owner listing submission is not connected yet.',
  );
  @override
  Future<CommercialProperty> createProperty(
    CommercialProperty property,
  ) async => _readOnly();
  @override
  Future<void> updateProperty(CommercialProperty property) async => _readOnly();
  @override
  Future<void> submitForVerification(String id) async => _readOnly();
  @override
  Future<void> updateVerification(String id, VerificationStatus status) async =>
      _readOnly();

  /// Create a REAL owner listing through FastAPI.
  ///
  /// This is the write path the Add Property wizard uses: the backend stamps
  /// the owner from the verified token, saves the row as `pending` +
  /// unpublished, then enriches it from the PostGIS data and reports that
  /// outcome separately. Errors propagate to the caller so the UI can show
  /// the backend's own message instead of pretending a save happened.
  Future<OwnerListingResult> submitOwnerListing(Map<String, dynamic> body) async {
    final response = await WebAuth.request(
      '/api/v1/properties/listings',
      method: 'POST',
      body: body,
    );
    return OwnerListingResult.fromResponse(response);
  }

  /// Re-run enrichment for an owned listing (idempotent server-side).
  Future<Map<String, dynamic>> enrichListing(int propertyId) =>
      WebAuth.request('/api/v1/properties/listings/$propertyId/enrich', method: 'POST');
}

/// Deterministic workbook-index ranking, not a trained prediction or demo data.
class DatasetRecommendationRepository implements RecommendationRepository {
  final PropertyRepository properties;
  DatasetRecommendationRepository(this.properties);
  @override
  Future<List<PropertyRecommendation>> getRecommendations(
    BusinessPreferences prefs,
  ) async {
    final candidates =
        (await properties.getProperties())
            .where(
              (p) =>
                  p.rentalRm >= prefs.minBudgetRm &&
                  p.rentalRm <= prefs.maxBudgetRm &&
                  p.sizeSqft >= prefs.minSizeSqft &&
                  p.sizeSqft <= prefs.maxSizeSqft &&
                  (prefs.preferredLocation.isEmpty ||
                      '${p.address} ${p.state}'.toLowerCase().contains(
                        prefs.preferredLocation.toLowerCase(),
                      )) &&
                  (prefs.propertyType == 'Any' ||
                      prefs.propertyType.isEmpty ||
                      p.propertyType == prefs.propertyType),
            )
            .toList()
          ..sort((a, b) => b.suitabilityScore.compareTo(a.suitabilityScore));
    return candidates
        .take(10)
        .map(
          (p) => PropertyRecommendation(
            property: p,
            score: p.suitabilityScore,
            reason:
                'Within your budget and size limits; ranked by the imported F&B suitability index.',
            whyRecommended: [
              'Matches budget',
              'Matches floor-area range',
              'Uses the source workbook index',
            ],
            highlights: [
              p.rentalDisplay,
              '${p.sizeSqft.toStringAsFixed(0)} sq ft',
            ],
          ),
        )
        .toList();
  }

  @override
  Future<LocationAnalysis> getLocationAnalysis(
    String propertyId,
  ) async => throw UnsupportedError(
    'Live competitor and demand analysis is not included in this workbook. No demo analysis is substituted.',
  );
}

class UnavailableIntelligenceRepository
    implements LocationIntelligenceRepository {
  @override
  Future<LocationAnalysis> getLocationIntelligence(
    String propertyId,
  ) async => throw UnsupportedError(
    'Competitor and demand analysis has not been imported for this property.',
  );
  @override
  Future<RecommendationExplanation> getExplanation(
    String propertyId,
  ) async => throw UnsupportedError(
    'An explanation model is not connected. The workbook suitability index is not a prediction.',
  );
}
