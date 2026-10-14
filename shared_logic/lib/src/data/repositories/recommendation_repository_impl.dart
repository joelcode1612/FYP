import '../../domain/entities/location_intelligence.dart';
import '../../domain/entities/recommendation.dart';
import '../../domain/repositories/recommendation_repository.dart';
import '../datasources/local/demo_data.dart';

class RecommendationRepositoryImpl implements RecommendationRepository {
  @override
  Future<List<PropertyRecommendation>> getRecommendations(
    BusinessPreferences prefs,
  ) async {
    final eligible =
        DemoData.properties
            .where(
              (p) =>
                  p.rentalRm <= prefs.maxBudgetRm &&
                  p.rentalRm >= prefs.minBudgetRm &&
                  p.sizeSqft >= prefs.minSizeSqft,
            )
            .toList()
          ..sort((a, b) => b.suitabilityScore.compareTo(a.suitabilityScore));
    final ranked = eligible.isEmpty ? DemoData.properties : eligible;
    return ranked
        .take(5)
        .map(
          (p) => PropertyRecommendation(
            property: p,
            score: p.suitabilityScore,
            reason:
                'Matches ${prefs.businessType} within ${prefs.budgetDisplay} in ${p.city}.',
            whyRecommended: [
              'Strong surrounding population',
              'Good accessibility',
              'Within your budget',
            ],
            highlights: [
              '${p.rentalDisplay} / ${p.sizeSqft.toStringAsFixed(0)} sq ft',
              p.tags.isEmpty ? p.propertyType : p.tags.first,
              'Score ${p.suitabilityScore.toStringAsFixed(0)}/100',
            ],
          ),
        )
        .toList();
  }

  @override
  Future<LocationAnalysis> getLocationAnalysis(String propertyId) async =>
      DemoData.analysisFor(propertyId);
}
