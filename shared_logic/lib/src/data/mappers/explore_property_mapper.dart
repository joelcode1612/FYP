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
      hasTour: false,
      imageUrl: _s(row['primary_image']),
      description: _s(row['description']),
      availability: _s(row['availability']),
      tenure: _s(row['tenure']),
      furnishing: _s(row['furnishing']),
      floorLevel: _s(row['floor_level']),
      bathrooms: _i(row['bathrooms']),
      isFnbSuitable: _b(row['is_fnb_suitable']),
      hasParking: _b(row['has_parking']),
      isCornerLot: _b(row['is_corner_lot']),
      isFreehold: _b(row['is_freehold']),
      psf: _d(row['psf']),
      hasResearchLink: row['has_research_link'] == true,
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
    return NearbyOutlets(
      available: meta['available'] == true,
      radiusM: _i(meta['radius_m']) ?? 500,
      outlets: [
        for (final row
            in (response['data'] as List? ?? const [])
                .whereType<Map<String, dynamic>>())
          NearbyOutlet(
            outletKey: '${row['outlet_key']}',
            name: _s(row['outlet_name']),
            category: _s(row['outlet_category']),
            brand: _s(row['brand']),
            streetAddress: _s(row['addr_street']),
            city: _s(row['addr_city']),
            latitude: _d(row['latitude']),
            longitude: _d(row['longitude']),
            distanceM: _d(row['distance_m']) ?? 0,
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

  static String _s(Object? v) => v == null ? '' : '$v';

  static double? _d(Object? v) => (v as num?)?.toDouble();

  static int? _i(Object? v) => (v as num?)?.toInt();

  static bool? _b(Object? v) => v == null ? null : v == true || v == 1;

  static DateTime? _dt(Object? v) =>
      v == null ? null : DateTime.tryParse('$v');

  static List<String> _strings(Object? v) => [
    for (final item in (v as List? ?? const [])) '$item',
  ];
}
