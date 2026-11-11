/// Two-phase geospatial enrichment, as the backend reports it.
///
/// The Add Property wizard starts enrichment in two independent phases:
///
/// * **Phase 1** — F&B competitors, demand generators, roads/transportation and
///   parking. Fast PostGIS aggregates, run while the owner is still on the page.
/// * **Phase 2** — population. Raster work, started separately and the only
///   category that can legitimately be *unavailable*.
///
/// Each category owns its own lifecycle, so one failure never hides the other
/// four results. This file is the single definition of that vocabulary for both
/// the web and the mobile app: never hard-code the strings in a page.
library;

/// The five enrichment categories, in presentation order.
enum EnrichmentCategory {
  fnbCompetitors('fnb_competitors', 'F&B competitors', EnrichmentPhase.postgis),
  demandGenerators('demand_generators', 'Demand generators', EnrichmentPhase.postgis),
  roadsTransport('roads_transport', 'Roads & transportation', EnrichmentPhase.postgis),
  parking('parking', 'Parking', EnrichmentPhase.postgis),
  population('population', 'Population', EnrichmentPhase.population);

  const EnrichmentCategory(this.wire, this.label, this.phase);

  /// Backend wire value (`fyp.property_enrichment_category.category`).
  final String wire;
  final String label;
  final EnrichmentPhase phase;

  /// Categories Phase 1 computes, in order.
  static List<EnrichmentCategory> get phaseOne =>
      values.where((c) => c.phase == EnrichmentPhase.postgis).toList();

  /// Categories Phase 2 computes.
  static List<EnrichmentCategory> get phaseTwo =>
      values.where((c) => c.phase == EnrichmentPhase.population).toList();

  static EnrichmentCategory? fromWire(String? wire) {
    for (final category in values) {
      if (category.wire == wire) return category;
    }
    return null;
  }
}

/// Which phase owns a category.
enum EnrichmentPhase {
  postgis('postgis', 'Location data'),
  population('population', 'Population');

  const EnrichmentPhase(this.wire, this.label);
  final String wire;
  final String label;
}

/// A category's lifecycle state.
///
/// [unavailable] means the data genuinely does not exist for these
/// coordinates — it is never a zero. [stale] means the input changed and the
/// stored values are still shown until a recalculation succeeds.
enum EnrichmentStatus {
  pending('pending', 'Waiting'),
  running('running', 'Calculating'),
  current('current', 'Ready'),
  unavailable('unavailable', 'Not available'),
  failed('failed', 'Failed'),
  stale('stale', 'Needs refresh');

  const EnrichmentStatus(this.wire, this.label);
  final String wire;
  final String label;

  static EnrichmentStatus fromWire(String? wire) {
    for (final status in values) {
      if (status.wire == wire) return status;
    }
    return EnrichmentStatus.pending;
  }

  /// A settled state will not change without a new request.
  bool get settled =>
      this == current ||
      this == unavailable ||
      this == failed ||
      this == stale;

  /// The state can be retried by the owner.
  bool get retryable => this == failed || this == unavailable || this == stale;

  /// The stored measurement is usable by the product.
  bool get hasMeasurement => this == current || this == stale;
}

/// One category's stored state, measurement and provenance.
class EnrichmentCategoryState {
  const EnrichmentCategoryState({
    required this.category,
    required this.status,
    this.measurement,
    this.provenance,
    this.attemptCount = 0,
    this.startedAt,
    this.completedAt,
    this.lastError,
  });

  final EnrichmentCategory category;
  final EnrichmentStatus status;

  /// Measured values, keyed by the wide feature-table column name.
  /// `null` when the category produced nothing — never an empty map.
  final Map<String, dynamic>? measurement;

  /// Where the values came from: source table, method, licence, reason.
  final Map<String, dynamic>? provenance;

  final int attemptCount;
  final String? startedAt;
  final String? completedAt;
  final String? lastError;

  bool get isRunning => status == EnrichmentStatus.running;

  /// The explanation the UI shows for a non-current state.
  String? get reason {
    if (status == EnrichmentStatus.current) return null;
    final fromProvenance = provenance?['reason'];
    if (fromProvenance is String && fromProvenance.isNotEmpty) {
      return switch (fromProvenance) {
        'no_population_raster_coverage' =>
          'No population raster covers these coordinates.',
        'property_has_no_coordinates' =>
          'This listing has no confirmed coordinates yet.',
        _ => fromProvenance.replaceAll('_', ' '),
      };
    }
    if (status == EnrichmentStatus.failed && (lastError ?? '').isNotEmpty) {
      return lastError;
    }
    if (status == EnrichmentStatus.running) return 'Calculating…';
    if (status == EnrichmentStatus.pending) return 'Not started yet.';
    return null;
  }

  /// A numeric measurement, or `null` when it is absent.
  ///
  /// Absence is returned as `null` so the caller renders "Not available"
  /// instead of a misleading `0`.
  num? number(String key) {
    final value = measurement?[key];
    return value is num ? value : null;
  }

  /// The radii that could not be measured for this category.
  List<String> get unavailableRadii {
    final raw = provenance?['radii_unavailable'];
    if (raw is List) return raw.map((r) => '$r').toList();
    return const [];
  }

  factory EnrichmentCategoryState.fromJson(
    EnrichmentCategory category,
    Map<String, dynamic>? row,
  ) {
    final data = row ?? const <String, dynamic>{};
    final measurement = data['measurement'];
    final provenance = data['provenance'];
    return EnrichmentCategoryState(
      category: category,
      status: EnrichmentStatus.fromWire('${data['status'] ?? 'pending'}'),
      measurement: measurement is Map
          ? measurement.cast<String, dynamic>()
          : null,
      provenance: provenance is Map
          ? provenance.cast<String, dynamic>()
          : null,
      attemptCount: (data['attempt_count'] as num?)?.toInt() ?? 0,
      startedAt: data['started_at']?.toString(),
      completedAt: data['completed_at']?.toString(),
      lastError: data['last_error']?.toString(),
    );
  }
}

/// The whole enrichment picture for one property.
class PropertyEnrichmentSummary {
  const PropertyEnrichmentSummary({
    required this.propertyId,
    required this.categories,
    required this.phaseOneComplete,
    required this.phaseTwoComplete,
    required this.readyToSubmit,
    required this.populationUnavailable,
    this.calculationVersion,
  });

  final int propertyId;
  final Map<EnrichmentCategory, EnrichmentCategoryState> categories;
  final bool phaseOneComplete;
  final bool phaseTwoComplete;

  /// Every category is settled as current/unavailable — safe to submit.
  final bool readyToSubmit;

  /// Population could not be measured; submitting needs an acknowledgement.
  final bool populationUnavailable;

  final String? calculationVersion;

  EnrichmentCategoryState state(EnrichmentCategory category) =>
      categories[category] ??
      EnrichmentCategoryState(
        category: category,
        status: EnrichmentStatus.pending,
      );

  EnrichmentCategoryState get population => state(EnrichmentCategory.population);

  /// Categories the owner can retry right now.
  List<EnrichmentCategory> get retryable => categories.entries
      .where((entry) => entry.value.status.retryable)
      .map((entry) => entry.key)
      .toList();

  /// Any category still being calculated.
  bool get isRunning =>
      categories.values.any((state) => state.isRunning);

  /// Progress across all five categories, 0..1, for the progress bar.
  double get progress {
    if (categories.isEmpty) return 0;
    final settled = categories.values
        .where((state) => state.status.settled)
        .length;
    return settled / categories.length;
  }

  factory PropertyEnrichmentSummary.fromJson(Map<String, dynamic> json) {
    final rawCategories =
        (json['categories'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};
    final states = <EnrichmentCategory, EnrichmentCategoryState>{};
    for (final category in EnrichmentCategory.values) {
      final row = rawCategories[category.wire];
      states[category] = EnrichmentCategoryState.fromJson(
        category,
        row is Map ? row.cast<String, dynamic>() : null,
      );
    }
    final phase1 = (json['phase1'] as Map?)?.cast<String, dynamic>();
    final phase2 = (json['phase2'] as Map?)?.cast<String, dynamic>();
    return PropertyEnrichmentSummary(
      propertyId: (json['property_id'] as num?)?.toInt() ?? 0,
      categories: states,
      phaseOneComplete: phase1?['complete'] == true,
      phaseTwoComplete: phase2?['complete'] == true,
      readyToSubmit: json['ready_to_submit'] == true,
      populationUnavailable: json['population_unavailable'] == true,
      calculationVersion: json['calculation_version']?.toString(),
    );
  }
}
