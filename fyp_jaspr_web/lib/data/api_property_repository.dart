import 'package:shared_logic/shared_logic.dart';
import 'auth_service.dart';

class ApiPropertyRepository implements PropertyRepository {
  Future<List<CommercialProperty>>? _cached;

  static CommercialProperty fromJson(
    Map<String, dynamic> row,
  ) => CommercialProperty(
    id: row['id'] as String,
    title: row['title'] as String,
    address: row['address'] as String,
    city: row['city'] as String? ?? '',
    state: row['state'] as String,
    postcode: row['postcode'] as String? ?? '',
    rentalRm: (row['rental_rm'] as num).toDouble(),
    sizeSqft: (row['size_sqft'] as num).toDouble(),
    latitude: (row['latitude'] as num).toDouble(),
    longitude: (row['longitude'] as num).toDouble(),
    propertyType: row['property_type'] as String,
    // Dataset quality checks are not administrator verification of a listing.
    verification: VerificationStatus.pending,
    suitabilityScore: (row['suitability_score'] as num).toDouble(),
    ownerId: '',
    hasTour: false,
    imageUrl: row['image_url'] as String?,
    sourceUrl: row['source_url'] as String?,
    tags: ['Imported dataset', 'Quality: ${row['dataset_validation']}'],
  );

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
    for (final property in await getProperties()) {
      if (property.id == id) return property;
    }
    return null;
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
