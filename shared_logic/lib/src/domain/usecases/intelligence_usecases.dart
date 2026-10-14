import '../entities/location_intelligence.dart';
import '../entities/sitewise_records.dart';
import '../repositories/intelligence_repositories.dart';
import '../repositories/property_repository.dart';
import '../repositories/recommendation_repository.dart';

class GetLocationIntelligence {
  final LocationIntelligenceRepository repo;
  const GetLocationIntelligence(this.repo);
  Future<LocationAnalysis> call(String propertyId) =>
      repo.getLocationIntelligence(propertyId);
}

class GetLocationSuitability {
  final LocationIntelligenceRepository repo;
  const GetLocationSuitability(this.repo);
  Future<LocationAnalysis> call(String propertyId) =>
      repo.getLocationIntelligence(propertyId);
}

class GetRecommendationExplanation {
  final LocationIntelligenceRepository repo;
  const GetRecommendationExplanation(this.repo);
  Future<RecommendationExplanation> call(String propertyId) =>
      repo.getExplanation(propertyId);
}

class CompareProperties {
  final PropertyRepository properties;
  final ComparisonRepository comparison;
  const CompareProperties(this.properties, this.comparison);

  Future<List<dynamic>> call() async {
    final ids = (await comparison.getComparison()).propertyIds;
    final all = await properties.getProperties();
    return all.where((p) => ids.contains(p.id)).toList();
  }
}

class SaveProperty {
  final ComparisonRepository repo;
  const SaveProperty(this.repo);
  Future<void> call(String id) => repo.saveProperty(id);
}

class RemoveSavedProperty {
  final ComparisonRepository repo;
  const RemoveSavedProperty(this.repo);
  Future<void> call(String id) => repo.removeSavedProperty(id);
}

class GenerateEvaluationReport {
  final PropertyRepository properties;
  final RecommendationRepository recommendations;
  const GenerateEvaluationReport(this.properties, this.recommendations);

  Future<EvaluationReport> call(String propertyId) async {
    final property = await properties.getPropertyById(propertyId);
    if (property == null) {
      throw StateError('Property $propertyId not found');
    }
    final analysis = await recommendations.getLocationAnalysis(propertyId);
    return EvaluationReport(
      propertyId: property.id,
      propertyTitle: property.title,
      locationLine:
          '${property.address}, ${property.postcode} ${property.city}, ${property.state}',
      rentalLine: '${property.rentalDisplay} / month',
      sizeLine: '${property.sizeSqft.toStringAsFixed(0)} sq ft',
      suitabilityScore: analysis.suitabilityScore,
      keyFactors: [for (final f in analysis.factors) '${f.name} — ${f.rating}'],
      recommendation:
          'Shortlist this unit if ${analysis.factors.first.name.toLowerCase()} '
          'and rental fit match your concept margins.',
      considerations: [
        for (final f in analysis.factors)
          if (f.impact != 'Positive') '${f.name}: ${f.evidence}',
      ],
      tourAvailable: property.hasTour,
    );
  }
}
