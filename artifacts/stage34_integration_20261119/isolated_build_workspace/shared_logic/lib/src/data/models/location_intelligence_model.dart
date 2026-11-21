import '../../domain/entities/location_intelligence.dart';

class LocationIntelligenceModel {
  final String propertyId;
  final double suitabilityScore;
  final int competitorCount;
  final String demandSummary;
  final String socioeconomicSummary;
  final List<Map<String, dynamic>> factors;

  const LocationIntelligenceModel({
    required this.propertyId,
    required this.suitabilityScore,
    required this.competitorCount,
    required this.demandSummary,
    this.socioeconomicSummary = '',
    this.factors = const [],
  });

  LocationAnalysis toEntity() => LocationAnalysis(
    propertyId: propertyId,
    suitabilityScore: suitabilityScore,
    competitorCount: competitorCount,
    demandSummary: demandSummary,
    socioeconomicSummary: socioeconomicSummary,
    factors: [
      for (final f in factors)
        LocationFactor(
          name: '${f['name']}',
          score: (f['score'] as num? ?? 0).toDouble(),
          rating: '${f['rating'] ?? 'Moderate'}',
          evidence: '${f['evidence'] ?? ''}',
          impact: '${f['impact'] ?? 'Neutral'}',
        ),
    ],
  );
}
