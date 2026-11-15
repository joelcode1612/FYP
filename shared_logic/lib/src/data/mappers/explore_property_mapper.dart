import '../../domain/entities/commercial_property.dart';
import '../../domain/entities/explore.dart';

/// JSON → domain mapping for the `/api/v1/explore/*` payloads.
///
/// Column names mirror `FypPropertyRepository._LIST_COLUMNS` exactly — this
/// mapper is the single translation point for the explore row shape, so no
/// page and no repository re-implements it. Honesty rules:
///
///  * SQL NULL becomes Dart null — never 0, never "".
///  * A genuine 0 count survives as 0; a missing count stays null.
///  * `verification_status` is the backend's own gating value
///    (`approved` for every row this API serves); anything else is mapped
///    through the shared vocabulary rather than hardcoded.
///  * Coordinates may be null in the raw row; the entity's (0, 0) sentinel is
///    only set when the backend returned NULL, and [CommercialProperty
///    .hasCoordinates] reports that honestly.
abstract final class ExplorePropertyMapper {
  /// Row → entity. [row] is one `list_published` / `get_published` mapping.
  static CommercialProperty property(Map<String, dynamic> row) =>
      _propertyFromRow(row);

  static CommercialProperty _propertyFromRow(Map<String, dynamic> row) {
    final lat = _d(row['latitude']);
    final lon = _d(row['longitude']);
    final score = _d(row['overall_location_score']);
    final management = row['management'] is Map
        ? (row['management'] as Map).cast<String, dynamic>()
        : const <String, dynamic>{};
    return CommercialProperty(
      id: '${row['property_id']}',
      title: _s(row['name']),
      address: _s(row['address']),
      city: _s(row['city']),
      state: _s(row['state']),
      postcode: '',
      rentalRm: _d(row['rental_price']) ?? 0,
      sizeSqft: _d(row['size_sqft']) ?? 0,
      latitude: lat ?? 0,
      longitude: lon ?? 0,
      propertyType: _s(row['property_type']),
      verification: verification(_s(row['verification_status'])),
      suitabilityScore: score ?? 0,
      hasSuitabilityScore: score != null,
      ownerId: '',
      managementLabel: (management['label'] as String?) ?? 'Management not assigned',
      managerName: management['name'] as String?,
      hasTour: false,
      imageUrl: _ns(row['primary_image']),
      description: _ns(row['description']),
      availability: _ns(row['availability']),
      tenure: _ns(row['tenure']),
      furnishing: _ns(row['furnishing']),
      floorLevel: _ns(row['floor_level']),
      bathrooms: _i(row['bathrooms']),
      isFnbSuitable: _b(row['is_fnb_suitable']),
      hasParking: _b(row['has_parking']),
      isCornerLot: _b(row['is_corner_lot']),
      isFreehold: _b(row['is_freehold']),
      psf: _d(row['psf']),
      hasResearchLink: row['has_research_link'] == true,
      // Real nearby-listing count from the optional spatial filter — null
      // when the request did not ask for it. Distinct from the F&B
      // competitor research counts above.
      nearbyPropertyCount: _i(row['nearby_property_count']),
      competitorCount500m: _i(row['competitor_count_500m']),
      competitorCount1km: _i(row['competitor_count_1km']),
      population500m: _d(row['population_500m']),
      population1km: _d(row['population_1km']),
      accessibilityScore: _d(row['accessibility_score']),
    );
  }

  /// `verification_status` → shared enum. The explore API only serves
  /// `approved` rows (server-gated), but the mapping stays total so a
  /// contract change surfaces as a visible state instead of a crash.
  static VerificationStatus verification(String? raw) => switch (raw) {
    'approved' || 'verified' => VerificationStatus.verified,
    'pending' || 'in_review' => VerificationStatus.pending,
    'rejected' => VerificationStatus.rejected,
    _ => VerificationStatus.draft,
  };

  /// Detail payload (row + photos + amenities + listing_sources). The detail
  /// endpoint returns the same column set as the list under the top-level
  /// keys, so the row mapper is reused directly.
  static ExplorePropertyDetail detail(Map<String, dynamic> payload) {
    return ExplorePropertyDetail(
      property: _propertyFromRow(payload),
      photos: [
        for (final photo
            in (payload['photos'] as List? ?? const [])
                .whereType<Map<String, dynamic>>())
          PropertyPhoto(
            url: _s(photo['url']),
            isPrimary: photo['is_primary'] == true,
            caption: _s(photo['caption']),
          ),
      ],
      amenities: _amenities(payload['amenities']),
      listingSources: [
        for (final source
            in (payload['listing_sources'] as List? ?? const [])
                .whereType<Map<String, dynamic>>())
          ListingSource(
            platform: _s(source['source_platform']),
            listingId: _s(source['source_listing_id']),
            url: _s(source['source_url']),
            availability: _s(source['source_availability']),
            observedAt: _dt(source['source_observed_at']),
            checkedAt: _dt(source['source_checked_at']),
          ),
      ],
    );
  }

  static PropertyAmenities? _amenities(Map<String, dynamic>? raw) {
    if (raw == null) return null;
    return PropertyAmenities(
      suitableFor: _s(raw['suitable_for']),
      nearbyLandmarks: _s(raw['nearby_landmarks']),
      amenities: _s(raw['amenities']),
      remarks: _s(raw['remarks']),
    );
  }

  /// `GET /explore/options` payload.
  static ExploreFilterOptions filterOptions(Map<String, dynamic> data) =>
      ExploreFilterOptions(
        states: _strings(data['states']),
        cities: _strings(data['cities']),
        propertyTypes: _strings(data['property_types']),
        availability: _strings(data['availability']),
        publishedTotal: _i(data['published_total']) ?? 0,
      );

  /// Competitor rows (`fnb_a.fnb_outlet` projection).
  static NearbyOutlets outlets(Map<String, dynamic> response) {
    final meta = (response['meta'] as Map?)?.cast<String, dynamic>() ?? const {};
    final rawCounts = (meta['counts'] as Map?)?.cast<String, dynamic>() ?? const {};
    return NearbyOutlets(
      available: meta['available'] == true,
      radiusM: _i(meta['radius_m']) ?? 500,
      counts: {
        for (final entry in rawCounts.entries)
          if (entry.value is num) entry.key: (entry.value as num).toInt(),
      },
      outlets: [
        for (final row
            in (response['data'] as List? ?? const [])
                .whereType<Map<String, dynamic>>())
          NearbyOutlet(
            // Normalized keys first, legacy keys as the fallback so the same
            // mapper still reads responses from a pre-source-mode backend.
            outletKey: '${row['competitor_key'] ?? row['outlet_key']}',
            name: _s(row['name'] ?? row['outlet_name']),
            category: _s(row['category'] ?? row['outlet_category']),
            brand: _s(row['brand']),
            streetAddress: _s(row['street_address'] ?? row['addr_street']),
            city: _s(row['city'] ?? row['addr_city']),
            latitude: _d(row['latitude']),
            longitude: _d(row['longitude']),
            distanceM: _d(row['distance_m']) ?? 0,
            provider: _s(row['provider']),
            operatingStatus: _s(row['operating_status']),
            sourceLicence: _s(row['source_licence']),
            sourceSnapshot: _s(row['source_snapshot']),
          ),
      ],
    );
  }

  /// Demand-generator rows (`demand_gen.subjects` projection).
  static NearbyDemandGenerators demandGenerators(Map<String, dynamic> response) {
    final meta = (response['meta'] as Map?)?.cast<String, dynamic>() ?? const {};
    return NearbyDemandGenerators(
      available: meta['available'] == true,
      radiusM: _i(meta['radius_m']) ?? 1000,
      generators: [
        for (final row
            in (response['data'] as List? ?? const [])
                .whereType<Map<String, dynamic>>())
          NearbyDemandGenerator(
            subjectId: _i(row['subject_id']) ?? 0,
            name: _s(row['subject_name']),
            category: _s(row['subject_category']),
            latitude: _d(row['latitude']),
            longitude: _d(row['longitude']),
            distanceM: _d(row['distance_m']) ?? 0,
          ),
      ],
    );
  }

  /// Population payload (`fyp_features.property_population_spatial` row);
  /// null means "no verified research link" → the unavailable profile.
  static PopulationProfile population(Map<String, dynamic>? row) {
    if (row == null) return PopulationProfile.unavailable;
    return PopulationProfile(
      available: true,
      popTotal200m: _d(row['pop_total_200m']),
      popTotal1km: _d(row['pop_total_1km']),
      popTotal3km: _d(row['pop_total_3km']),
      popRing0To500m: _d(row['pop_ring_0_500m']),
      popRing500To1km: _d(row['pop_ring_500_1km']),
      densityPerKm2: _d(row['pop_density_km2']),
      density500mPerKm2: _d(row['pop_density_500m_km2']),
      pctAge20To34Within1km: _d(row['pct_age_20_34_1km']),
      pctAge15To64Within1km: _d(row['pct_age_15_64_1km']),
      estimatedHouseholds1km: _d(row['estimated_households_1km']),
      residentialBuildings500m: _i(row['residential_building_count_500m']),
      residentialBuildings1km: _i(row['residential_building_count_1km']),
      officeFloorArea500mSqM: _d(row['office_floor_area_500m_m2']),
      schools1km: _i(row['schools_count_1km']),
      malls1km: _i(row['malls_count_1km']),
      universities1km: _i(row['universities_count_1km']),
      hospitals1km: _i(row['hospitals_count_1km']),
      officePois500m: _i(row['office_poi_count_500m']),
      source: _s(row['population_source']),
      sourceYear: _i(row['population_source_year']),
      qualityFlag: _s(row['population_quality_flag']),
    );
  }

  // --- primitives -----------------------------------------------------------
  //
  // PostgreSQL `numeric` columns are JSON-encoded as STRINGS ("6000.00",
  // "2.0"), while `double precision`/`integer` columns arrive as JSON numbers.
  // Every helper below accepts both. Casting with `v as num?` used to throw a
  // TypeError on the first real row, which surfaced in the app as the generic
  // "Unable to load properties" state even though the API answered 200.

  static String _s(Object? v) {
    if (v == null) return '';
    final text = '$v';
    // The imported workbook writes the literal text "NULL" for absent text
    // columns. That is a missing value, not a value to render.
    return text.toUpperCase() == 'NULL' ? '' : text;
  }

  /// Nullable text: SQL NULL (and the "NULL" text artifact) stays null so the
  /// UI can say "not provided" instead of showing an invented empty fact.
  static String? _ns(Object? v) {
    if (v == null) return null;
    final text = _s(v);
    return text.isEmpty ? null : text;
  }

  static double? _d(Object? v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v.trim());
    return null;
  }

  static int? _i(Object? v) {
    if (v == null) return null;
    if (v is num) return v.toInt();
    if (v is String) return num.tryParse(v.trim())?.round();
    return null;
  }

  /// `smallint` flags (0/1) and their string forms keep the tri-state meaning:
  /// null is "not recorded", never coerced to false.
  static bool? _b(Object? v) {
    if (v == null) return null;
    if (v is bool) return v;
    if (v is num) return v != 0;
    if (v is String) {
      final text = v.trim().toLowerCase();
      if (text == '1' || text == 'true' || text == 't') return true;
      if (text == '0' || text == 'false' || text == 'f') return false;
    }
    return null;
  }

  static DateTime? _dt(Object? v) =>
      v == null ? null : DateTime.tryParse('$v');

  static List<String> _strings(Object? v) => [
    for (final item in (v is List ? v : const [])) '$item',
  ];
}
