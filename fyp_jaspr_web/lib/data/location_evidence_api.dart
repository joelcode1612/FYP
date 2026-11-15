import 'auth_service.dart';

/// Read-only representation of /api/v1/catalog/properties/{id}/evidence.
/// The API's null and zero values intentionally remain distinct.
class EvidenceMetric {
  final String key;
  final String label;
  final String unit;
  final num? value;
  final String status;
  final String? note;

  const EvidenceMetric({
    required this.key,
    required this.label,
    required this.unit,
    required this.value,
    required this.status,
    this.note,
  });

  factory EvidenceMetric.fromJson(Map<String, dynamic> json) => EvidenceMetric(
    key: '${json['key'] ?? ''}',
    label: '${json['label'] ?? 'Unlabelled measurement'}',
    unit: '${json['unit'] ?? ''}',
    value: json['value'] is num ? json['value'] as num : null,
    status: '${json['status'] ?? 'unavailable'}',
    note: json['note']?.toString(),
  );

  bool get available => status == 'available' && value != null;

  String get displayValue {
    if (!available) return 'Not available';
    final number = value!.toDouble();
    // Building-footprint density is stored as a ratio, not an already-scaled
    // percentage. Treat it differently from an absolute population/count.
    if (unit == 'ratio') return '${(number * 100).toStringAsFixed(1)}%';
    final formatted = number == number.roundToDouble()
        ? number.toStringAsFixed(0)
        : number.toStringAsFixed(2);
    if (unit.isEmpty || unit == 'count') return formatted;
    if (unit == 'RM/month') return 'RM $formatted / month';
    return '$formatted $unit';
  }
}

class EvidenceGroup {
  final String key;
  final String label;
  final List<EvidenceMetric> metrics;

  const EvidenceGroup({
    required this.key,
    required this.label,
    required this.metrics,
  });

  factory EvidenceGroup.fromJson(Map<String, dynamic> json) => EvidenceGroup(
    key: '${json['key'] ?? ''}',
    label: '${json['label'] ?? 'Location evidence'}',
    metrics: (json['metrics'] as List? ?? const [])
        .whereType<Map>()
        .map(
          (value) => EvidenceMetric.fromJson(Map<String, dynamic>.from(value)),
        )
        .toList(growable: false),
  );

  List<EvidenceMetric> get availableMetrics =>
      metrics.where((metric) => metric.available).toList(growable: false);
}

class PropertyEvidence {
  final String propertyId;
  final bool available;
  final String? reason;
  final String? analysisStatus;
  final String? referenceCoverage;
  final String? snapshotAt;
  final num? dataCompletenessPct;
  final List<EvidenceGroup> groups;

  /// Official DOSM demographics for the property's whole district.
  ///
  /// Deliberately a separate object from the 500 m / 1 km catchment metrics:
  /// district-wide statistics describe a much larger area and must never be
  /// presented as the people living near this property.
  final DistrictStatistics? districtStatistics;

  const PropertyEvidence({
    required this.propertyId,
    required this.available,
    required this.groups,
    this.reason,
    this.analysisStatus,
    this.referenceCoverage,
    this.snapshotAt,
    this.dataCompletenessPct,
    this.districtStatistics,
  });

  factory PropertyEvidence.unavailable(String id, String reason) =>
      PropertyEvidence(
        propertyId: id,
        available: false,
        groups: const [],
        reason: reason,
      );

  factory PropertyEvidence.fromJson(Map<String, dynamic> json) =>
      PropertyEvidence(
        propertyId: '${json['property_id'] ?? ''}',
        available: json['available'] == true,
        reason: json['reason']?.toString(),
        analysisStatus: json['analysis_status']?.toString(),
        referenceCoverage: json['reference_coverage']?.toString(),
        snapshotAt: json['feature_snapshot_at']?.toString(),
        dataCompletenessPct: json['data_completeness_pct'] is num
            ? json['data_completeness_pct'] as num
            : null,
        districtStatistics: json['district_statistics'] is Map<String, dynamic>
            ? DistrictStatistics.fromJson(
                json['district_statistics'] as Map<String, dynamic>,
              )
            : null,
        groups: (json['groups'] as List? ?? const [])
            .whereType<Map>()
            .map(
              (value) =>
                  EvidenceGroup.fromJson(Map<String, dynamic>.from(value)),
            )
            .toList(growable: false),
      );

  EvidenceGroup? group(String key) {
    for (final entry in groups) {
      if (entry.key == key) return entry;
    }
    return null;
  }
}

/// One aggregated DOSM age band for a district.
class DistrictAgeGroup {
  final String key;
  final String label;

  /// Headcount, or null when the DOSM import holds none of the five-year bands
  /// behind this group. Null is a missing category and must be rendered as
  /// such; coercing it to 0 would claim a district with no children in it.
  final int? persons;

  /// Share of the district's grouped population, 0-1. Null when the groups are
  /// partial or the total is zero, which the UI must never draw as a usable
  /// distribution.
  final double? share;

  const DistrictAgeGroup({
    required this.key,
    required this.label,
    required this.persons,
    required this.share,
  });

  factory DistrictAgeGroup.fromJson(Map<String, dynamic> json) =>
      DistrictAgeGroup(
        key: '${json['key'] ?? ''}',
        label: '${json['label'] ?? json['key'] ?? ''}',
        persons: (json['persons'] as num?)?.toInt(),
        share: (json['share'] as num?)?.toDouble(),
      );
}

/// The official DOSM district demographics block of the evidence payload.
///
/// [available] is false with a [reason] when the property has no verified
/// district match, or when DOSM publishes none of these datasets for the
/// matched district. When it is true each block is still resolved on its own:
/// population, age bands and household income come from different datasets and
/// different reference years, so a null value plus its note means that one
/// figure is unpublished for this district and the UI says so instead of
/// collapsing the whole section or inventing a number.
class DistrictStatistics {
  final bool available;
  final String? reason;
  final String? district;
  final String? state;
  final String? ageYear;
  final int totalPopulation;
  final List<DistrictAgeGroup> ageGroups;
  final String? ageNote;

  /// DOSM's published district sex split, from the same dataset and date as
  /// [districtPopulation]. Null when that dataset holds no split (or no record)
  /// for the district — the UI must not invent one.
  final int? malePopulation;
  final int? femalePopulation;
  final int? districtPopulation;
  final String? populationAsOf;
  final String? populationNote;

  /// Median monthly household income from the DOSM household income survey,
  /// whose reference year differs from the population estimates.
  final num? incomeMedianMyr;
  final String? incomeAsOf;
  final String? incomeNote;

  const DistrictStatistics({
    required this.available,
    required this.totalPopulation,
    required this.ageGroups,
    this.reason,
    this.district,
    this.state,
    this.ageYear,
    this.ageNote,
    this.malePopulation,
    this.femalePopulation,
    this.districtPopulation,
    this.populationAsOf,
    this.populationNote,
    this.incomeMedianMyr,
    this.incomeAsOf,
    this.incomeNote,
  });

  factory DistrictStatistics.fromJson(Map<String, dynamic> json) =>
      DistrictStatistics(
        available: json['available'] == true,
        reason: json['reason']?.toString(),
        district: json['district']?.toString(),
        state: json['state']?.toString(),
        ageYear: json['age_year']?.toString(),
        ageNote: json['age_note']?.toString(),
        totalPopulation: (json['total_population'] as num?)?.toInt() ?? 0,
        ageGroups: [
          for (final g in (json['age_groups'] as List? ?? const []))
            if (g is Map<String, dynamic>) DistrictAgeGroup.fromJson(g),
        ],
        malePopulation: (json['male_population'] as num?)?.toInt(),
        femalePopulation: (json['female_population'] as num?)?.toInt(),
        districtPopulation: (json['district_population'] as num?)?.toInt(),
        populationAsOf: json['population_as_of']?.toString(),
        populationNote: json['population_note']?.toString(),
        incomeMedianMyr: json['income_median_myr'] as num?,
        incomeAsOf: json['income_as_of']?.toString(),
        incomeNote: json['income_note']?.toString(),
      );
}

abstract final class LocationEvidenceApi {
  /// Catalogue evidence is joined to an analysed subject by the backend.
  /// Do not infer a catalogue subject_id from a numeric rental-property ID.
  static Future<PropertyEvidence> load(
    String propertyId, {
    bool catalog = true,
  }) async {
    if (!catalog) {
      return PropertyEvidence.unavailable(
        propertyId,
        'No verified analytics mapping is exposed for this numeric listing. '
        'Do not combine it with an unrelated research property.',
      );
    }
    final response = await WebAuth.request(
      '/api/v1/catalog/properties/${Uri.encodeComponent(propertyId)}/evidence',
    );
    return PropertyEvidence.fromJson(response);
  }
}
