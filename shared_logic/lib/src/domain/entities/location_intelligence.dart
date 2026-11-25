/// One measured feature of a property's surroundings.
///
/// [value] is null when nothing was measured — never zero. A genuine measured
/// zero arrives as `0.0` and is therefore distinguishable from "unavailable",
/// which is the whole point of keeping the value nullable.
class LocationMeasurement {
  /// The backend feature name, e.g. `pop_500m`.
  final String key;
  final String label;
  final String unit;

  /// Measured value, or null when no measurement exists for these coordinates.
  final double? value;

  /// `validated`, `calculated_unvalidated`, `unavailable`, `stale`,
  /// `not_calculated`, `failed`, `pending` or `running`.
  final String state;
  final String? source;
  final String? method;

  const LocationMeasurement({
    required this.key,
    required this.label,
    required this.unit,
    required this.value,
    required this.state,
    this.source,
    this.method,
  });

  bool get measured => value != null;

  /// True when the value is measured but has not been approved as an input for
  /// the active model. It is still a real measurement and is displayed as one;
  /// this flag only explains why it is absent from a score.
  bool get informationalOnly => measured && state == 'calculated_unvalidated';

  /// Display string with its unit. Integers render without decimals so a count
  /// reads as `1 920` rather than `1920.00`.
  String get display {
    final v = value;
    if (v == null) return 'Not measured';
    final text = v == v.roundToDouble()
        ? v.toStringAsFixed(0)
        : v.abs() >= 100
        ? v.toStringAsFixed(1)
        : v.toStringAsFixed(3).replaceFirst(RegExp(r'0+$'), '');
    return unit.isEmpty ? text : '$text $unit';
  }
}

/// One category of measurements (population, transit, competition, ...).
class LocationMeasurementGroup {
  final String key;
  final String title;

  /// The category's own calculation state: `current`, `pending`, `running`,
  /// `failed`, `stale`, `unavailable` or `not_calculated`.
  final String status;
  final String? reason;
  final List<LocationMeasurement> rows;

  const LocationMeasurementGroup({
    required this.key,
    required this.title,
    required this.status,
    required this.rows,
    this.reason,
  });

  int get measuredCount => rows.where((row) => row.measured).length;
  bool get available => measuredCount > 0;
  int get total => rows.length;
}

/// A single explainable location factor, expressed in business language
/// (Strong / Good / Moderate) — never raw geospatial calculations.
class LocationFactor {
  final String name;
  final double score; // 0–100, drives the progress bar only
  final String rating; // Strong, Good, Moderate, Weak
  final String evidence;
  final String impact; // Positive / Neutral / Risk

  const LocationFactor({
    required this.name,
    required this.score,
    required this.rating,
    required this.evidence,
    required this.impact,
  });
}

/// Aggregated location intelligence for one property.
class LocationAnalysis {
  final String propertyId;
  final double suitabilityScore;
  final List<LocationFactor> factors;
  final int competitorCount;
  final String demandSummary;
  final String socioeconomicSummary;

  /// Null when the server supplied no measured location/association figure.
  /// The non-nullable [suitabilityScore]/[competitorCount] fields remain for
  /// older callers, but a UI that must not display an invented zero uses
  /// these measured fields and says so explicitly when they are null.
  final double? measuredScore;
  final int? measuredCompetitorCount;

  /// Measured surroundings, grouped. Empty when the backend returned no
  /// measurement block at all (for example a catalogue reference that has no
  /// property record yet) — in that case the section is simply not rendered.
  /// A non-empty list with every value null means "this property has
  /// coordinates but has not been measured yet", which is rendered as such.
  final List<LocationMeasurementGroup> measurementGroups;

  /// True when at least one measurement exists for this property.
  final bool hasMeasuredValues;

  const LocationAnalysis({
    required this.propertyId,
    required this.suitabilityScore,
    required this.factors,
    required this.competitorCount,
    required this.demandSummary,
    this.socioeconomicSummary = '',
    this.measuredScore,
    this.measuredCompetitorCount,
    this.measurementGroups = const [],
    this.hasMeasuredValues = false,
  });

  bool get hasMeasuredScore => measuredScore != null;

  /// True when the backend described the measurement state for this property,
  /// whether or not anything was measured.
  bool get hasMeasurementReport => measurementGroups.isNotEmpty;

  int get measuredValueCount =>
      measurementGroups.fold(0, (sum, group) => sum + group.measuredCount);

  /// Plain-language verdict for the suitability page.
  String get verdict {
    final value = measuredScore;
    if (value == null) return 'Not measured';
    if (value >= 80) return 'Good potential';
    if (value >= 60) return 'Moderate potential';
    return 'Consider carefully';
  }
}
