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

  const PropertyEvidence({
    required this.propertyId,
    required this.available,
    required this.groups,
    this.reason,
    this.analysisStatus,
    this.referenceCoverage,
    this.snapshotAt,
    this.dataCompletenessPct,
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
