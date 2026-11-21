import 'dart:async';

import 'package:shared_logic/shared_logic.dart';
import 'package:fyp/features/listing/domain/property_evidence.dart';

/// API transport and JSON mapping live in data, not in presentation/domain.
/// Numeric listing IDs must not be resolved as arbitrary research subject IDs.
class ApiPropertyEvidenceReader implements PropertyEvidenceReader {
  final ApiClient api;
  const ApiPropertyEvidenceReader(this.api);

  @override
  Future<PropertyEvidenceSnapshot> load(String propertyId) async {
    if (int.tryParse(propertyId) != null) {
      return const PropertyEvidenceSnapshot(
        measurements: [], districtAvailable: false,
        districtReason: 'The listing has no verified research subject link for this evidence endpoint.');
    }
    final json = await api.get(
      '/api/v1/catalog/properties/${Uri.encodeComponent(propertyId)}/evidence');
    final measurements = <PropertyEvidenceMetric>[];
    for (final group in (json['groups'] as List? ?? const [])) {
      if (group is! Map) continue;
      for (final raw in (group['metrics'] as List? ?? const [])) {
        if (raw is! Map) continue;
        measurements.add(PropertyEvidenceMetric(
          key: '${raw['key'] ?? ''}',
          value: raw['value'] is num ? raw['value'] as num : null,
          unit: '${raw['unit'] ?? ''}',
          available: raw['status'] == 'available' && raw['value'] is num,
        ));
      }
    }
    final district = json['district_statistics'] is Map
      ? json['district_statistics'] as Map : const {};
    return PropertyEvidenceSnapshot(
      measurements: measurements,
      districtAvailable: district['available'] == true,
      districtReason: district['reason']?.toString(),
      districtName: district['district']?.toString(),
      districtPopulation: (district['district_population'] as num?)?.toInt(),
      populationAsOf: district['population_as_of']?.toString(),
      householdMedian: district['income_median_myr'] is num
        ? district['income_median_myr'] as num : null,
      incomeAsOf: district['income_as_of']?.toString(),
    );
  }
}
