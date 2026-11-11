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

/// Provider verdict for one address. Deliberately separate from property
/// verification: a validated address never implies ownership or approval.
class AddressCheckResult {
  const AddressCheckResult({
    required this.status,
    this.formattedAddress,
    this.granularity,
    this.postalCode,
    this.latitude,
    this.longitude,
  });

  final String status; // validated | partially_validated | unconfirmed
  final String? formattedAddress;
  final String? granularity;
  final String? postalCode;
  final double? latitude;
  final double? longitude;

  bool get confirmed => status == 'validated';

  factory AddressCheckResult.fromData(Map<String, dynamic> data) => AddressCheckResult(
    status: '${data['status'] ?? 'unconfirmed'}',
    formattedAddress: data['formatted_address'] as String?,
    granularity: data['validation_granularity'] as String?,
    postalCode: data['postal_code'] as String?,
    latitude: (data['latitude'] as num?)?.toDouble(),
    longitude: (data['longitude'] as num?)?.toDouble(),
  );
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
    final rows = <CommercialProperty>[];
    var offset = 0;
    while (true) {
      // Intended FastAPI backend (FYP/backend). The Jaspr same-origin proxy
      // forwards /api/* to it; `test/app-server.js` is no longer used.
      final response = await WebAuth.request(
        '/api/v1/catalog/properties?limit=200&offset=$offset',
      );
      final page = (response['data'] as List).cast<Map<String, dynamic>>();
      rows.addAll(page.map(fromJson));
      offset += page.length;
      if (page.isEmpty || offset >= (response['meta']['total'] as int)) break;
    }
    return List.unmodifiable(rows);
  }

  @override
  Future<CommercialProperty?> getPropertyById(String id) async {
    // Single-record read: scanning the paged catalogue for one id wasted up
    // to 2,126 rows per detail view and drift-prone against live imports.
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

  /// Ask the backend to validate an address (Google Address Validation).
  ///
  /// The Google key stays on the server. A 503 means the provider is not
  /// enabled/configured — the thrown message says so explicitly, so the UI can
  /// distinguish "address rejected" from "service unavailable".
  Future<AddressCheckResult> validateAddress({
    required List<String> addressLines,
    String? city,
    String? state,
    String? postcode,
  }) async {
    final response = await WebAuth.request(
      '/api/v1/properties/validate-address',
      method: 'POST',
      body: {
        'address_lines': addressLines.where((line) => line.trim().isNotEmpty).toList(),
        if (city != null && city.trim().isNotEmpty) 'city': city.trim(),
        if (state != null && state.trim().isNotEmpty) 'state': state.trim(),
        if (postcode != null && postcode.trim().isNotEmpty) 'postcode': postcode.trim(),
        'region_code': 'MY',
      },
    );
    final data = (response['data'] as Map?)?.cast<String, dynamic>() ?? const {};
    return AddressCheckResult.fromData(data);
  }
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
