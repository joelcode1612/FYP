import '../../domain/entities/location_intelligence.dart';
import '../../domain/entities/recommendation.dart';
import '../../domain/entities/sitewise_records.dart';
import '../../domain/repositories/intelligence_repositories.dart';
import '../../domain/repositories/recommendation_repository.dart';
import '../../core/network/api_client.dart';

/// Live [LocationIntelligenceRepository] over the authenticated FastAPI
/// `/explore/analysis` endpoint (the cross-universe property analysis in
/// `backend/src/sitewise/api/v1/explore.py`).
///
/// Depends only on the abstract [ApiClient] port: pure Dart, browser-safe.
/// The platform supplies the bearer-aware client; the backend enforces
/// authentication. This class never decides authorization and never calls
/// Supabase directly.
///
/// Honesty contract (mirrors the backend): all figures are RESEARCH dataset
/// features — precomputed geospatial counts, DOSM population statistics, or
/// the imported workbook's suitability index. None of them is a verified
/// commercial-success probability, and the evidence strings say so. Sections
/// without backing data are omitted rather than invented, so [LocationAnalysis]
/// may carry an empty [LocationAnalysis.factors] list when a property has no
/// research coverage.
class ApiLocationIntelligenceRepository implements LocationIntelligenceRepository {
  final ApiClient _client;

  ApiLocationIntelligenceRepository(this._client);

  /// The backend `analysis` payload for one property reference — either a
  /// `fyp.rental_properties` numeric id or a workbook catalogue id
  /// (`EP-xxxxx` / `MD-xxxxx`). The backend resolves both.
  Future<Map<String, dynamic>> _analysis(String propertyId) async {
    final response = await _client.get(
      '/api/v1/explore/analysis',
      query: {'ref': propertyId},
    );
    // Bare-object payloads pass through the bridge unwrapped; wrapped ones
    // (array-like) arrive as {'data': ...}. The analysis endpoint always
    // returns an object, so read it directly and tolerate the wrapper.
    final payload = response.containsKey('data') && response.containsKey('meta')
        ? response
        : (response['data'] as Map<String, dynamic>? ?? response);
    return payload['data'] as Map<String, dynamic>;
  }

  static String _rating(double score) {
    if (score >= 75) return 'Strong';
    if (score >= 60) return 'Good';
    if (score >= 45) return 'Moderate';
    return 'Weak';
  }

  /// Presentation bands for F&B competition density. These are fixed
  /// display thresholds chosen for readability — NOT model thresholds.
  static (String, String) _competitionRating(int count500m) {
    if (count500m <= 15) return ('Strong', 'Positive');
    if (count500m <= 40) return ('Moderate', 'Neutral');
    return ('Weak', 'Risk');
  }

  static (String, String) _populationRating(double? pop1km) {
    if (pop1km == null) return ('Moderate', 'Neutral');
    if (pop1km >= 50000) return ('Strong', 'Positive');
    if (pop1km >= 15000) return ('Good', 'Positive');
    if (pop1km >= 5000) return ('Moderate', 'Neutral');
    return ('Weak', 'Risk');
  }

  /// Maps the analysis payload to the business-language [LocationAnalysis].
  static LocationAnalysis analysisFromJson(
    String propertyId,
    Map<String, dynamic> data,
  ) {
    final geo = data['geospatial_features'] as Map<String, dynamic>?;
    final counts =
        data['competitor_counts'] as Map<String, dynamic>? ?? const {};
    final research = data['research_link'] as Map<String, dynamic>?;
    final population = data['population'] as Map<String, dynamic>?;

    // Score provenance is explicit: a precomputed research location score
    // first, then the workbook's imported suitability index. Never a
    // success probability.
    final double? locationScore =
        (geo?['overall_location_score'] as num?)?.toDouble();
    final double? catalogScore =
        (data['catalog_suitability_score'] as num?)?.toDouble();
    final score = locationScore ?? catalogScore ?? 0;

    final int? comp500 =
        (geo?['competitor_count_500m'] as num?)?.toInt() ??
        (counts['competitor_count_500m'] as num?)?.toInt();
    final int? comp1km =
        (geo?['competitor_count_1km'] as num?)?.toInt() ??
        (counts['competitor_count_1km'] as num?)?.toInt();
    final double? pop1km =
        (geo?['population_1km'] as num?)?.toDouble() ??
        (population?['pop_total_1km'] as num?)?.toDouble();
    final double? pop500m =
        (geo?['population_500m'] as num?)?.toDouble() ??
        (population?['pop_ring_0_500m'] as num?)?.toDouble();
    final double? accessibility =
        (geo?['accessibility_score'] as num?)?.toDouble();
    final double? income =
        (geo?['income_median'] as num?)?.toDouble() ??
        (research?['district_income_median_myr'] as num?)?.toDouble();

    final factors = <LocationFactor>[];
    if (pop1km != null || pop500m != null) {
      final (rating, impact) = _populationRating(pop1km);
      factors.add(
        LocationFactor(
          name: 'Nearby population',
          score: rating == 'Strong'
              ? 85
              : rating == 'Good'
              ? 70
              : rating == 'Moderate'
              ? 50
              : 30,
          rating: rating,
          evidence:
              'Research population estimates — '
              '${pop500m != null ? '${pop500m.round()} within 500 m' : 'no 500 m figure'}'
              '${pop1km != null ? ', ${pop1km.round()} within 1 km' : ''}.',
          impact: impact,
        ),
      );
    }
    if (comp500 != null) {
      final (rating, impact) = _competitionRating(comp500);
      factors.add(
        LocationFactor(
          name: 'F&B competition nearby',
          score: rating == 'Strong'
              ? 80
              : rating == 'Moderate'
              ? 55
              : 30,
          rating: rating,
          evidence:
              '$comp500 F&B outlets within 500 m'
              '${comp1km != null ? ' ($comp1km within 1 km)' : ''} in the '
              'research competitor dataset — a count, not a success forecast.',
          impact: impact,
        ),
      );
    }
    if (accessibility != null) {
      factors.add(
        LocationFactor(
          name: 'Accessibility',
          score: accessibility.clamp(0, 100).toDouble(),
          rating: _rating(accessibility),
          evidence:
              'Research accessibility score ${accessibility.toStringAsFixed(1)} '
              '(road network within 1 km).',
          impact: accessibility >= 45 ? 'Positive' : 'Risk',
        ),
      );
    }
    if (income != null) {
      factors.add(
        LocationFactor(
          name: 'District income',
          score: 60,
          rating: _rating(income > 0 ? (income / 100).clamp(0, 100) : 0),
          evidence:
              'Median district income RM ${income.toStringAsFixed(0)} '
              '(research dataset).',
          impact: 'Neutral',
        ),
      );
    }

    final demandParts = <String>[];
    if (comp500 != null) demandParts.add('$comp500 F&B outlets within 500 m');
    if (pop1km != null) {
      demandParts.add('≈${pop1km.round()} residents within 1 km');
    }
    final socioParts = <String>[];
    if (income != null) {
      socioParts.add('median district income RM ${income.toStringAsFixed(0)}');
    }
    final market = geo?['market_segment'] as String?;
    if (market != null && market.isNotEmpty) socioParts.add('segment: $market');

    return LocationAnalysis(
      propertyId: propertyId,
      suitabilityScore: score,
      factors: List.unmodifiable(factors),
      competitorCount: comp500 ?? 0,
      demandSummary: demandParts.isEmpty
          ? 'No research demand coverage for this property yet.'
          : demandParts.join(' · '),
      socioeconomicSummary: socioParts.isEmpty ? '' : socioParts.join(' · '),
    );
  }

  @override
  Future<LocationAnalysis> getLocationIntelligence(String propertyId) async =>
      analysisFromJson(propertyId, await _analysis(propertyId));

  @override
  Future<RecommendationExplanation> getExplanation(String propertyId) async {
    final analysis = await getLocationIntelligence(propertyId);
    final strengths = [
      for (final f in analysis.factors)
        if (f.impact == 'Positive') '${f.name} — ${f.rating}',
    ];
    final considerations = [
      for (final f in analysis.factors)
        if (f.impact != 'Positive') '${f.name} is ${f.rating.toLowerCase()}',
    ];
    return RecommendationExplanation(
      propertyId: propertyId,
      suitabilityScore: analysis.suitabilityScore,
      strengths: strengths,
      considerations: considerations,
      summary:
          'Built from research dataset features (population, competitor and '
          'accessibility counts). These are not verified success '
          'probabilities; validate on site before committing.',
    );
  }
}

/// [RecommendationRepository] adapter that delegates ranking to one
/// repository and location analysis to the live [LocationIntelligenceRepository].
///
/// This is the composition-root glue for the split the shared package makes:
/// ranking and analysis live on separate contracts, but the
/// [GetLocationAnalysis] use case (and therefore the entrepreneur state
/// owner) consumes a [RecommendationRepository]. Without this adapter a
/// composition root had to wire analysis to a ranking implementation that
/// could only throw.
class IntelligenceBackedRecommendationRepository
    implements RecommendationRepository {
  final RecommendationRepository _ranking;
  final LocationIntelligenceRepository _intelligence;

  IntelligenceBackedRecommendationRepository(this._ranking, this._intelligence);

  @override
  Future<List<PropertyRecommendation>> getRecommendations(
    BusinessPreferences prefs,
  ) => _ranking.getRecommendations(prefs);

  @override
  Future<LocationAnalysis> getLocationAnalysis(String propertyId) =>
      _intelligence.getLocationIntelligence(propertyId);
}
