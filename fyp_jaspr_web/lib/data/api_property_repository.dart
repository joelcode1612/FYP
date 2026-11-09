import 'package:shared_logic/shared_logic.dart';
import 'auth_service.dart';

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
