/// Shared, read-only models for direct property comparison.
///
/// These mirror `POST /api/v1/compare`. Comparison never produces an overall
/// score or a winner: every value is an observable measurement and every
/// sentence is a deterministic statement about measured differences.

/// One comparison measurement, including its honest availability state.
class CompareMetric {
  final num? value;
  final bool available;
  final String label;
  final String unit;
  final int? radiusM;
  final String group;
  final String source;
  final String display;

  const CompareMetric({
    this.value,
    this.available = false,
    this.label = '',
    this.unit = '',
    this.radiusM,
    this.group = '',
    this.source = '',
    this.display = 'Data not available',
  });

  factory CompareMetric.fromJson(Map<String, dynamic> json) => CompareMetric(
    value: json['value'] as num?,
    available: json['available'] == true,
    label: '${json['label'] ?? ''}',
    unit: '${json['unit'] ?? ''}',
    radiusM: (json['radius_m'] as num?)?.toInt(),
    group: '${json['group'] ?? ''}',
    source: '${json['source'] ?? ''}',
    display: '${json['display'] ?? 'Data not available'}',
  );

  String get caption => radiusM == null ? label : '$label ($radiusM m)';
}

/// A missing measurement with the reason the backend reported.
class CompareDataGap {
  final String metric;
  final String label;
  final String reason;

  const CompareDataGap({
    required this.metric,
    required this.label,
    required this.reason,
  });

  factory CompareDataGap.fromJson(Map<String, dynamic> json) => CompareDataGap(
    metric: '${json['metric'] ?? ''}',
    label: '${json['label'] ?? ''}',
    reason: '${json['reason'] ?? 'Data not available'}',
  );
}

/// One shortlisted property with all comparison measurements.
class CompareProperty {
  final String id;
  final String title;
  final String address;
  final String city;
  final String state;
  final String postcode;
  final String propertyType;
  final String? imageUrl;
  final bool panoramaAvailable;
  final String? panoramaStatus;
  final String? panoramaUrl;
  final bool availabilityConfirmed;
  final String availabilityStatus;
  final String researchAvailabilityStatus;
  final String? availabilityNotice;
  final bool verifiedListing;
  final String verificationProvenance;
  final num? researchIndex;
  final bool researchIndexAvailable;
  final String researchIndexMeaning;
  final Map<String, CompareMetric> metrics;
  final List<CompareDataGap> dataGaps;

  const CompareProperty({
    required this.id,
    required this.title,
    this.address = '',
    this.city = '',
    this.state = '',
    this.postcode = '',
    this.propertyType = '',
    this.imageUrl,
    this.panoramaAvailable = false,
    this.panoramaStatus,
    this.panoramaUrl,
    this.availabilityConfirmed = false,
    this.availabilityStatus = 'Not confirmed',
    this.researchAvailabilityStatus = 'UNKNOWN_NOT_VERIFIED',
    this.availabilityNotice,
    this.verifiedListing = false,
    this.verificationProvenance = 'research_unverified',
    this.researchIndex,
    this.researchIndexAvailable = false,
    this.researchIndexMeaning = '',
    this.metrics = const {},
    this.dataGaps = const [],
  });

  CompareMetric metric(String key) => metrics[key] ?? const CompareMetric();

  String get location => [city, state].where((v) => v.trim().isNotEmpty).join(', ');

  factory CompareProperty.fromJson(Map<String, dynamic> json) {
    final panorama = json['panorama'] is Map
        ? (json['panorama'] as Map).cast<String, dynamic>()
        : const <String, dynamic>{};
    final availability = json['availability'] is Map
        ? (json['availability'] as Map).cast<String, dynamic>()
        : const <String, dynamic>{};
    final verification = json['verification'] is Map
        ? (json['verification'] as Map).cast<String, dynamic>()
        : const <String, dynamic>{};
    final research = json['research_index'] is Map
        ? (json['research_index'] as Map).cast<String, dynamic>()
        : const <String, dynamic>{};
    return CompareProperty(
      id: '${json['property_id'] ?? ''}',
      title: '${json['title'] ?? ''}',
      address: '${json['address'] ?? ''}',
      city: '${json['city'] ?? ''}',
      state: '${json['state'] ?? ''}',
      postcode: '${json['postcode'] ?? ''}',
      propertyType: '${json['property_type'] ?? ''}',
      imageUrl: json['image_url']?.toString(),
      panoramaAvailable: panorama['available'] == true,
      panoramaStatus: panorama['status']?.toString(),
      panoramaUrl: panorama['url']?.toString(),
      availabilityConfirmed: availability['confirmed'] == true,
      availabilityStatus: '${availability['status'] ?? 'Not confirmed'}',
      researchAvailabilityStatus:
          '${availability['research_status'] ?? 'UNKNOWN_NOT_VERIFIED'}',
      availabilityNotice: availability['notice']?.toString(),
      verifiedListing: verification['verified_listing'] == true,
      verificationProvenance:
          '${verification['provenance'] ?? 'research_unverified'}',
      researchIndex: (research['value'] as num?) ?? (research['value'] is String
          ? num.tryParse(research['value'] as String)
          : null),
      researchIndexAvailable: research['available'] == true,
      researchIndexMeaning: '${research['meaning'] ?? ''}',
      metrics: {
        for (final entry in (json['metrics'] as Map? ?? const {}).entries)
          '${entry.key}': CompareMetric.fromJson(
            Map<String, dynamic>.from(entry.value as Map),
          ),
      },
      dataGaps: [
        for (final row in (json['data_gaps'] as List? ?? const []))
          if (row is Map<String, dynamic>) CompareDataGap.fromJson(row),
      ],
    );
  }
}

/// A measured difference between two of the selected properties.
class CompareDifference {
  final String metric;
  final String fromId;
  final String toId;
  final String fromTitle;
  final String toTitle;
  final num value;
  final String unit;
  final int? radiusM;
  final String sentence;

  const CompareDifference({
    required this.metric,
    required this.fromId,
    required this.toId,
    required this.fromTitle,
    required this.toTitle,
    required this.value,
    required this.unit,
    required this.radiusM,
    required this.sentence,
  });

  factory CompareDifference.fromJson(Map<String, dynamic> json) =>
      CompareDifference(
        metric: '${json['metric'] ?? ''}',
        fromId: '${json['from_id'] ?? ''}',
        toId: '${json['to_id'] ?? ''}',
        fromTitle: '${json['from_title'] ?? ''}',
        toTitle: '${json['to_title'] ?? ''}',
        value: (json['value'] as num?) ?? 0,
        unit: '${json['unit'] ?? ''}',
        radiusM: (json['radius_m'] as num?)?.toInt(),
        sentence: '${json['sentence'] ?? ''}',
      );
}

/// Objective, factually restrained observation about one property.
class CompareInsight {
  final String propertyId;
  final String title;
  final List<String> points;

  const CompareInsight({
    required this.propertyId,
    required this.title,
    required this.points,
  });

  factory CompareInsight.fromJson(Map<String, dynamic> json) => CompareInsight(
    propertyId: '${json['property_id'] ?? ''}',
    title: '${json['title'] ?? ''}',
    points: [for (final value in (json['points'] as List? ?? const [])) '$value'],
  );
}

/// A deterministic trade-off sentence with the properties it concerns.
class CompareTradeoff {
  final List<String> propertyIds;
  final String text;

  const CompareTradeoff({required this.propertyIds, required this.text});

  factory CompareTradeoff.fromJson(Map<String, dynamic> json) => CompareTradeoff(
    propertyIds: [
      for (final value in (json['property_ids'] as List? ?? const [])) '$value',
    ],
    text: '${json['text'] ?? ''}',
  );
}

/// Complete comparison result returned to web and mobile.
class PropertyCompareResult {
  final int selectedCount;
  final int resolvedCount;
  final List<String> unresolvedIds;
  final List<CompareProperty> properties;
  final List<CompareDifference> differences;
  final List<CompareInsight> insights;
  final List<CompareTradeoff> tradeoffs;
  final List<String> notes;

  const PropertyCompareResult({
    required this.selectedCount,
    required this.resolvedCount,
    this.unresolvedIds = const [],
    this.properties = const [],
    this.differences = const [],
    this.insights = const [],
    this.tradeoffs = const [],
    this.notes = const [],
  });

  factory PropertyCompareResult.fromJson(Map<String, dynamic> json) =>
      PropertyCompareResult(
        selectedCount: (json['selected_count'] as num?)?.toInt() ?? 0,
        resolvedCount: (json['resolved_count'] as num?)?.toInt() ?? 0,
        unresolvedIds: [
          for (final value in (json['unresolved_ids'] as List? ?? const []))
            '$value',
        ],
        properties: [
          for (final row in (json['properties'] as List? ?? const []))
            if (row is Map<String, dynamic>) CompareProperty.fromJson(row),
        ],
        differences: [
          for (final row in (json['differences'] as List? ?? const []))
            if (row is Map<String, dynamic>) CompareDifference.fromJson(row),
        ],
        insights: [
          for (final row in (json['insights'] as List? ?? const []))
            if (row is Map<String, dynamic>) CompareInsight.fromJson(row),
        ],
        tradeoffs: [
          for (final row in (json['tradeoffs'] as List? ?? const []))
            if (row is Map<String, dynamic>) CompareTradeoff.fromJson(row),
        ],
        notes: [for (final value in (json['notes'] as List? ?? const [])) '$value'],
      );

  /// Differences that concern one metric, for grouped comparison rows.
  List<CompareDifference> differencesFor(String metric) =>
      differences.where((item) => item.metric == metric).toList();
}
