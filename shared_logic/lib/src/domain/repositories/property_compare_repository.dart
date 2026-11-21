import '../../domain/entities/property_compare.dart';

/// Port for direct shortlist comparison. Deliberately separate from the
/// recommendation search repository: Compare must not re-rank or re-score.
abstract class PropertyCompareRepository {
  Future<PropertyCompareResult> compare(List<String> propertyIds);
}
