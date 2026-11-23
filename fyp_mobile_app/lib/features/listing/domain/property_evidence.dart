import 'dart:async';

/// Read-only location evidence contracts shared by listing UI and data layer.
/// Unavailable is not zero; district statistics describe a wider geography.
class PropertyEvidenceSnapshot {
  final List<PropertyEvidenceMetric> measurements;
  final bool districtAvailable;
  final String? districtReason;
  final String? districtName;
  final int? districtPopulation;
  final String? populationAsOf;
  final num? householdMedian;
  final String? incomeAsOf;

  const PropertyEvidenceSnapshot({
    required this.measurements,
    required this.districtAvailable,
    this.districtReason,
    this.districtName,
    this.districtPopulation,
    this.populationAsOf,
    this.householdMedian,
    this.incomeAsOf,
  });

  PropertyEvidenceMetric? metric(String key) {
    for (final m in measurements) {
      if (m.key == key) return m;
    }
    return null;
  }
}

class PropertyEvidenceMetric {
  final String key;
  final num? value;
  final String unit;
  final bool available;

  const PropertyEvidenceMetric({
    required this.key,
    required this.value,
    required this.unit,
    required this.available,
  });

  String get display {
    if (!available || value == null) return 'Not measured';
    final n = value!.toDouble();
    final formatted = n == n.roundToDouble()
      ? n.toStringAsFixed(0) : n.toStringAsFixed(2);
    if (unit == 'ratio') return '${(n * 100).toStringAsFixed(1)}%';
    if (unit.isEmpty || unit == 'count') return formatted;
    return '$formatted $unit';
  }
}

abstract class PropertyEvidenceReader {
  Future<PropertyEvidenceSnapshot> load(String propertyId);
}
