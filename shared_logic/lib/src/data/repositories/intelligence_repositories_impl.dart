import '../../core/constants/app_constants.dart';
import '../../domain/entities/location_intelligence.dart';
import '../../domain/entities/sitewise_records.dart';
import '../../domain/repositories/intelligence_repositories.dart';
import '../datasources/local/demo_data.dart';

class LocationIntelligenceRepositoryImpl
    implements LocationIntelligenceRepository {
  @override
  Future<LocationAnalysis> getLocationIntelligence(String propertyId) async =>
      DemoData.analysisFor(propertyId);

  @override
  Future<RecommendationExplanation> getExplanation(String propertyId) async {
    final analysis = DemoData.analysisFor(propertyId);
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
          'Recommended because demand and accessibility outweigh the moderate competition nearby.',
    );
  }
}

class ComparisonRepositoryImpl implements ComparisonRepository {
  final List<SavedProperty> _saved = [];
  final List<String> _compared = [];

  @override
  Future<List<SavedProperty>> getSaved() async => List.unmodifiable(_saved);

  @override
  Future<void> saveProperty(String propertyId) async {
    if (_saved.any((s) => s.propertyId == propertyId)) return;
    _saved.add(SavedProperty(propertyId: propertyId, savedAt: DateTime.now()));
  }

  @override
  Future<void> removeSavedProperty(String propertyId) async {
    _saved.removeWhere((s) => s.propertyId == propertyId);
  }

  @override
  Future<PropertyComparison> getComparison() async =>
      PropertyComparison(propertyIds: List.of(_compared));

  @override
  Future<void> addToComparison(String propertyId) async {
    if (_compared.contains(propertyId)) return;
    if (_compared.length >= AppBreakpoints.maxCompare) return;
    _compared.add(propertyId);
  }

  @override
  Future<void> removeFromComparison(String propertyId) async {
    _compared.remove(propertyId);
  }

  @override
  Future<void> clearComparison() async => _compared.clear();
}
