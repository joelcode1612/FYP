
// ## Wire-decoding compatibility boundary
//
// The `fromJson` factories in this library are retained for public API
// compatibility: `fyp_mobile_app` and `fyp_jaspr_web` call some of them
// directly, and removing them would require coordinated edits in both apps
// (outside this package's scope). New transport code must decode through
// the data-layer mappers (`src/data/mappers/`), which are the authoritative
// entry points for backend payloads. These factories contain no business
// rules — they only decode the wire shape, with field names preserved.

import 'commercial_property.dart';
import 'recommendation.dart';

/// Shared recommendation-search contracts.
///
/// These mirror the FastAPI `POST /api/v1/recommendations/search` payload
/// exactly, so the Jaspr web app and the Flutter app consume one shape and
/// render one ranking. No client re-ranks: the server returns the page in
/// rank order and the client appends pages in arrival order.
///
/// Three honest states are preserved end to end:
///
///  * a requirement is **met**, **unmet**, or **unverified** — a requirement
///    the catalogue cannot answer is never reported as unmet;
///  * the model score is nullable, because the trained artifact is not
///    integrated; `available == false` is a real answer, not an error;
///  * the PU association is a separate tri-state (`null` = not loaded yet),
///    never merged into the recommendation score.

/// Whether a stated requirement is satisfied by a listing.
enum RequirementState {
  /// The catalogue data satisfies the requirement.
  met,

  /// The catalogue data contradicts the requirement.
  unmet,

  /// The catalogue records nothing that can answer this requirement.
  unverified;

  static RequirementState fromWire(String? value) => switch (value) {
    'met' => RequirementState.met,
    'unmet' => RequirementState.unmet,
    _ => RequirementState.unverified,
  };
}

/// One requirement evaluated against one listing.
class RequirementMatch {
  final String label;
  final RequirementState state;

  const RequirementMatch({required this.label, required this.state});

  bool get isMet => state == RequirementState.met;
  bool get isUnmet => state == RequirementState.unmet;
  bool get isUnverified => state == RequirementState.unverified;
}

/// The recommendation verdict for one listing.
///
/// [score] is null in this build: the trained ranker is not integrated, so the
/// server returns `available: false` with a machine-readable [reason] instead
/// of a fabricated number. [matched]/[unmatched]/[unverified] are real
/// requirement evaluations and stay meaningful without a model score.
class RecommendationMatch {
  final bool available;
  final int rank;
  final double? score;
  final String scoreType;
  final String? modelVersion;
  final String? reason;
  final List<RequirementMatch> matched;
  final List<RequirementMatch> unmatched;
  final List<RequirementMatch> unverified;

  /// Met / (met + unmet). Null when no requirement is verifiable — a browse
  /// with no criteria has no ratio to report, which is not the same as 0.
  final double? matchRatio;
  final int matchedCount;
  final int verifiableCount;

  const RecommendationMatch({
    required this.available,
    required this.rank,
    this.score,
    this.scoreType = 'requirement_fit_ordering',
    this.modelVersion,
    this.reason,
    this.matched = const [],
    this.unmatched = const [],
    this.unverified = const [],
    this.matchRatio,
    this.matchedCount = 0,
    this.verifiableCount = 0,
  });

  factory RecommendationMatch.fromJson(Map<String, dynamic> json) {
    List<RequirementMatch> list(String key, RequirementState state) => [
      for (final label in (json[key] as List? ?? const []))
        RequirementMatch(label: '$label', state: state),
    ];
    return RecommendationMatch(
      available: json['available'] == true,
      rank: (json['rank'] as num?)?.toInt() ?? 0,
      score: (json['score'] as num?)?.toDouble(),
      scoreType: json['score_type'] as String? ?? 'requirement_fit_ordering',
      modelVersion: json['model_version'] as String?,
      reason: json['reason'] as String?,
      matched: list('matched_requirements', RequirementState.met),
      unmatched: list('unmatched_requirements', RequirementState.unmet),
      unverified: list('unverified_requirements', RequirementState.unverified),
      matchRatio: (json['match_ratio'] as num?)?.toDouble(),
      matchedCount: (json['matched_count'] as num?)?.toInt() ?? 0,
      verifiableCount: (json['verifiable_count'] as num?)?.toInt() ?? 0,
    );
  }

  /// "3 of 4 requirements met" — the honest headline when no model score
  /// exists. Null when nothing was verifiable.
  String? get fitSummary => verifiableCount == 0
      ? null
      : '$matchedCount of $verifiableCount requirements met';
}

/// Manager information resolved from existing backend relationships.
///
/// The backend derives the manager from a verified Agent assignment, an active
/// Owner identity or a documented platform-stewardship policy — in that order.
/// The display label is supplied by the backend so no client keeps its own copy
/// of the rule, and a property with no valid manager reads "Manager Not
/// Assigned" instead of borrowing a default name.
class ListingManagement {
  final String status;

  /// ``agent`` | ``owner`` | ``platform`` | ``unresolved`` | ``unavailable``.
  final String type;

  /// Manager display name. Null for platform stewardship and unresolved
  /// states — those have no person, and none is invented.
  final String? name;

  /// Backend-supplied display base, e.g. "Managed by Agent".
  final String? label;

  const ListingManagement({
    this.status = 'unavailable',
    this.type = 'unavailable',
    this.name,
    this.label,
  });

  factory ListingManagement.fromJson(Map<String, dynamic> json) =>
      ListingManagement(
        status: json['status'] as String? ?? 'unavailable',
        type: json['type'] as String? ?? json['status'] as String? ?? 'unavailable',
        name: json['name'] as String? ?? json['manager_name'] as String?,
        label: json['label'] as String?,
      );

  /// Fallback label for a payload that predates ``label``. Kept minimal so the
  /// backend stays the single source of the wording.
  String get _fallbackLabel {
    switch (status) {
      case 'agent_managed':
        return 'Managed by Agent';
      case 'owner_managed':
        return 'Managed by Owner';
      case 'platform_managed':
        return 'Managed by SiteWise';
      case 'unresolved':
      case 'unassigned':
        return 'Manager Not Assigned';
      default:
        return 'Management unavailable';
    }
  }

  String get display {
    final base = (label ?? _fallbackLabel).trim();
    final manager = name?.trim() ?? '';
    if (manager.isEmpty) return base;
    return '$base — $manager';
  }
}

/// One ranked listing: the shared property entity plus its verdict.
class RankedProperty {
  final CommercialProperty property;
  final String source;
  final RecommendationMatch match;
  final ListingManagement management;

  /// Workbook P-vs-U association index (0–100). A relative research ranking
  /// input, never a probability of business success.
  final double? catalogSuitabilityScore;
  final bool suitabilityAvailable;

  /// PU association. `null` = not loaded in this response (the list endpoint
  /// deliberately does not run 20 model inferences); `available == false`
  /// means the model reported the property as unavailable.
  final double? puScore;
  final bool? puAvailable;

  /// Where the ranking PU score came from: `stored_catalogue` (the original
  /// model's stored output) or `expanded64_live_inference` (the 2026-11-15
  /// expanded model's live prediction). Null on older payloads.
  final String? puScoreSource;

  /// The model version behind [puScore] when it was computed live.
  final String? puModelVersion;

  /// Server-verified 360° panorama for this catalogue property. The URL is
  /// non-null ONLY when the backend resolved a completed stitching job
  /// through a verified subject link (`status == 'ready'`); `processing` and
  /// `unavailable` never carry a URL. Ordinary wide photos are never
  /// promoted to panoramas.
  final String? panoramaUrl;
  final String? panoramaStatus;

  /// Verified research characteristics returned for this row. Absent keys
  /// mean "not measured", never zero; the UI must say unavailable.
  final Map<String, dynamic> characteristics;

  const RankedProperty({
    required this.property,
    required this.match,
    this.management = const ListingManagement(),
    this.source = 'catalog',
    this.catalogSuitabilityScore,
    this.suitabilityAvailable = false,
    this.puScore,
    this.puAvailable,
    this.puScoreSource,
    this.puModelVersion,
    this.panoramaUrl,
    this.panoramaStatus,
    this.characteristics = const {},
  });

  String get id => property.id;

  /// City / District: the address prefix, because the catalogue city column
  /// is empty for every research row.
  String get district => property.address.split(',').first.trim();

  /// True when an immersive 360° view can actually be opened.
  bool get hasPanorama => panoramaUrl != null && panoramaUrl!.isNotEmpty;

  factory RankedProperty.fromJson(Map<String, dynamic> json) {
    final research = json['research'] as Map<String, dynamic>? ?? const {};
    final suitability = (research['catalog_suitability_score'] as num?)
        ?.toDouble();
    final rawPhotos = json['photos'];
    final photoUrls = <String>[
      if (rawPhotos is List)
        for (final photo in rawPhotos)
          if (photo is String && photo.trim().isNotEmpty) photo.trim(),
    ];
    final panorama = json['panorama'] is Map<String, dynamic>
        ? json['panorama'] as Map<String, dynamic>
        : const <String, dynamic>{};
    final panoramaStatus = panorama['status']?.toString();
    final rawPanoUrl = panorama['url']?.toString().trim() ?? '';
    final panoramaUrl = panorama['available'] == true &&
            panoramaStatus == 'ready' &&
            rawPanoUrl.isNotEmpty
        ? rawPanoUrl
        : null;
    return RankedProperty(
      management: ListingManagement.fromJson(
        json['management'] is Map<String, dynamic>
            ? json['management'] as Map<String, dynamic>
            : const {},
      ),
      source: json['property_source'] as String? ?? 'catalog',
      catalogSuitabilityScore: suitability,
      suitabilityAvailable:
          research['suitability_available'] == true && suitability != null,
      puScore: (research['pu_score'] as num?)?.toDouble(),
      puAvailable: research['pu_available'] as bool?,
      puScoreSource: research['pu_score_source']?.toString(),
      puModelVersion: research['pu_model_version']?.toString(),
      panoramaUrl: panoramaUrl,
      panoramaStatus: panoramaStatus,
      characteristics: json['characteristics'] is Map<String, dynamic>
          ? json['characteristics'] as Map<String, dynamic>
          : const {},
      match: RecommendationMatch.fromJson(
        json['recommendation'] as Map<String, dynamic>? ?? const {},
      ),
      // The catalogue records no owner and no owner-verification state, so
      // those fields are reported empty rather than borrowed from an
      // unrelated listing. `verification` stays `pending`: a catalogue row
      // has not been verified as an available listing, and the UI must not
      // imply that it has. Photos and the panorama ARE reported: the search
      // response batch-resolves them server-side through the verified
      // catalogue chain.
      property: CommercialProperty(
        id: json['property_id'] as String? ?? '',
        title: json['title'] as String? ?? '',
        address: json['address'] as String? ?? '',
        city: json['city'] as String? ?? '',
        state: json['state'] as String? ?? '',
        postcode: json['postcode'] as String? ?? '',
        rentalRm: (json['rental_rm'] as num?)?.toDouble() ?? 0,
        sizeSqft: (json['size_sqft'] as num?)?.toDouble() ?? 0,
        latitude: (json['latitude'] as num?)?.toDouble() ?? 0,
        longitude: (json['longitude'] as num?)?.toDouble() ?? 0,
        propertyType: json['property_type'] as String? ?? '',
        verification: VerificationStatus.pending,
        suitabilityScore: suitability ?? 0,
        hasSuitabilityScore: suitability != null,
        ownerId: '',
        hasTour: panoramaUrl != null,
        imageUrl: json['image_url'] as String?,
        imageUrls: photoUrls,
      ),
    );
  }
}

/// Model provenance for one search response.
class RecommendationModelStatus {
  final bool available;
  final String? version;
  final String scoreType;
  final String reason;

  const RecommendationModelStatus({
    required this.available,
    this.version,
    this.scoreType = 'requirement_fit_ordering',
    this.reason = '',
  });

  factory RecommendationModelStatus.fromJson(Map<String, dynamic> json) =>
      RecommendationModelStatus(
        available: json['available'] == true,
        version: json['version'] as String?,
        scoreType: json['score_type'] as String? ?? 'requirement_fit_ordering',
        reason: json['reason'] as String? ?? '',
      );

  /// Shown next to the ranking, so a client can never present a
  /// requirement-fit ordering as a model score.
  ///
  /// The 2026-11-15 expanded 64-feature variant reports
  /// `live_pu_association_requirement_fit_ordering`: the ranking is still
  /// requirement-fit, but eligibility and tie-breaks come from LIVE PU
  /// inference, so the label must say "research association", never
  /// "preference match".
  static const livePuScoreType =
      'live_pu_association_requirement_fit_ordering';

  bool get isLivePuAssociation => scoreType == livePuScoreType;

  String get label => switch (scoreType) {
        livePuScoreType when available =>
          'Live PU research association${version == null ? '' : ' · $version'}',
        _ when available =>
          'Experimental preference match${version == null ? '' : ' · $version'}',
        _ => 'Requirement-fit ordering (model score unavailable)',
      };
}

/// One page of ranked results.
class RecommendationSearchPage {
  final List<RankedProperty> items;
  final String? nextCursor;
  final bool hasMore;
  final int total;
  final RecommendationModelStatus model;

  const RecommendationSearchPage({
    required this.items,
    this.nextCursor,
    this.hasMore = false,
    this.total = 0,
    this.model = const RecommendationModelStatus(available: false),
  });

  factory RecommendationSearchPage.fromJson(Map<String, dynamic> json) {
    final pagination =
        json['pagination'] as Map<String, dynamic>? ?? const {};
    final model = json['model'] as Map<String, dynamic>? ?? const {};
    return RecommendationSearchPage(
      items: [
        for (final row in (json['data'] as List? ?? const []))
          if (row is Map<String, dynamic>) RankedProperty.fromJson(row),
      ],
      nextCursor: pagination['next_cursor'] as String?,
      hasMore: pagination['has_more'] == true,
      total: (pagination['total'] as num?)?.toInt() ?? 0,
      model: RecommendationModelStatus.fromJson(model),
    );
  }
}

/// The request the two clients send. Built from [BusinessPreferences] so the
/// ranking always uses the same criteria the entrepreneur saved.
class RecommendationSearchRequest {
  final String? businessType;
  final String? preferredState;
  final String? preferredArea;
  final double? minRentalRm;
  final double? maxRentalRm;
  final double? minSizeSqft;
  final double? maxSizeSqft;
  final String? propertyType;
  final String? city;

  /// Data-supported advanced filters. Every value is a server-verified
  /// measurement or a documented preference; no client-side guessing.
  final String? floorLevel;
  final double? transitMaxM;
  final double? nearbyParkingMin;
  final double? fnbCompetitionMax;
  final String? demandGenerator;
  final double? populationMin1000m;
  final double? populationMax1000m;
  final List<String> layoutPreferences;
  final String? query;
  final bool managedOnly;
  final int pageSize;
  final String? cursor;

  /// Ordering of the eligible set — `best_match` (default), `rent_asc`,
  /// `rent_desc`, `size_desc`, `size_asc` or `pu_desc`.
  ///
  /// `null` means "let the server apply its default", which is what a saved
  /// preference does: sort is a view of the results, not a stored requirement.
  final String? sort;

  const RecommendationSearchRequest({
    this.businessType,
    this.preferredState,
    this.preferredArea,
    this.minRentalRm,
    this.maxRentalRm,
    this.minSizeSqft,
    this.maxSizeSqft,
    this.propertyType,
    this.city,
    this.floorLevel,
    this.transitMaxM,
    this.nearbyParkingMin,
    this.fnbCompetitionMax,
    this.demandGenerator,
    this.populationMin1000m,
    this.populationMax1000m,
    this.layoutPreferences = const [],
    this.query,
    this.managedOnly = false,
    this.pageSize = 20,
    this.cursor,
    this.sort,
  });

  /// Builds the search from saved preferences.
  ///
  /// A default `maxSizeSqft` of `double.infinity` means "no ceiling" and is
  /// therefore omitted rather than sent as a number JSON cannot represent.
  /// `propertyType == 'Any'` is likewise not a constraint.
  factory RecommendationSearchRequest.fromPreferences(
    BusinessPreferences preferences, {
    String? state,
    String? area,
    String? query,
    int pageSize = 20,
    String? cursor,
  }) {
    return RecommendationSearchRequest(
      // Business type is deliberately NOT a recommendation filter: the
      // general PU model ranks the same eligible set for every F&B operation.
      // The field exists only for backward-compatible API consumers.
      businessType: null,
      preferredState: (state ?? preferences.preferredLocation).isEmpty
          ? null
          : (state ?? preferences.preferredLocation),
      preferredArea: (area == null || area.isEmpty) ? null : area,
      minRentalRm: preferences.minBudgetRm > 0
          ? preferences.minBudgetRm
          : null,
      maxRentalRm: preferences.maxBudgetRm > 0
          ? preferences.maxBudgetRm
          : null,
      minSizeSqft: preferences.minSizeSqft > 0 ? preferences.minSizeSqft : null,
      maxSizeSqft: preferences.maxSizeSqft.isFinite && preferences.maxSizeSqft > 0
          ? preferences.maxSizeSqft
          : null,
      propertyType:
          (preferences.propertyType.isEmpty ||
              preferences.propertyType == 'Any')
          ? null
          : preferences.propertyType,
      layoutPreferences: preferences.requirements,
      query: (query == null || query.trim().isEmpty) ? null : query.trim(),
      pageSize: pageSize,
      cursor: cursor,
    );
  }

  /// Reads a request previously serialised by [toJson]. Used when the applied
  /// search filters travel with a property-detail link, so the comparison on
  /// that page can show the criteria the entrepreneur actually used — never
  /// a reconstructed guess from saved preferences.
  factory RecommendationSearchRequest.fromJson(Map<String, dynamic> json) =>
      RecommendationSearchRequest(
        businessType: json['business_type'] as String?,
        preferredState: json['preferred_state'] as String?,
        preferredArea: json['preferred_area'] as String?,
        minRentalRm: (json['min_rental_rm'] as num?)?.toDouble(),
        maxRentalRm: (json['max_rental_rm'] as num?)?.toDouble(),
        minSizeSqft: (json['min_size_sqft'] as num?)?.toDouble(),
        maxSizeSqft: (json['max_size_sqft'] as num?)?.toDouble(),
        propertyType: json['property_type'] as String?,
        city: json['city'] as String?,
        floorLevel: json['floor_level'] as String?,
        transitMaxM: (json['transit_max_m'] as num?)?.toDouble(),
        nearbyParkingMin: (json['nearby_parking_min'] as num?)?.toDouble(),
        fnbCompetitionMax: (json['fnb_competition_max'] as num?)?.toDouble(),
        demandGenerator: json['demand_generator'] as String?,
        populationMin1000m: (json['population_min_1000m'] as num?)?.toDouble(),
        populationMax1000m: (json['population_max_1000m'] as num?)?.toDouble(),
        layoutPreferences: [
          for (final value in (json['layout_preferences'] as List? ?? const []))
            '$value',
        ],
        query: json['query'] as String?,
        managedOnly: json['managed_only'] == true,
        pageSize: (json['page_size'] as num?)?.toInt() ?? 20,
        cursor: json['cursor'] as String?,
        sort: json['sort'] as String?,
      );

  /// True when nothing constrains the search — a plain browse. The UI uses
  /// this to show "browse all properties" instead of an empty-state that
  /// demands preferences the user may not have yet.
  bool get isBrowseOnly =>
      minRentalRm == null &&
      maxRentalRm == null &&
      minSizeSqft == null &&
      maxSizeSqft == null &&
      preferredState == null &&
      preferredArea == null &&
      propertyType == null &&
      city == null &&
      floorLevel == null &&
      transitMaxM == null &&
      nearbyParkingMin == null &&
      fnbCompetitionMax == null &&
      demandGenerator == null &&
      populationMin1000m == null &&
      populationMax1000m == null &&
      layoutPreferences.isEmpty &&
      !managedOnly &&
      query == null;

  Map<String, dynamic> toJson() => {
    if (businessType != null) 'business_type': businessType,
    if (preferredState != null) 'preferred_state': preferredState,
    if (preferredArea != null) 'preferred_area': preferredArea,
    if (minRentalRm != null) 'min_rental_rm': minRentalRm,
    if (maxRentalRm != null) 'max_rental_rm': maxRentalRm,
    if (minSizeSqft != null) 'min_size_sqft': minSizeSqft,
    if (maxSizeSqft != null) 'max_size_sqft': maxSizeSqft,
    if (propertyType != null) 'property_type': propertyType,
    if (city != null) 'city': city,
    if (floorLevel != null) 'floor_level': floorLevel,
    if (transitMaxM != null) 'transit_max_m': transitMaxM,
    if (nearbyParkingMin != null) 'nearby_parking_min': nearbyParkingMin,
    if (fnbCompetitionMax != null) 'fnb_competition_max': fnbCompetitionMax,
    if (demandGenerator != null) 'demand_generator': demandGenerator,
    if (populationMin1000m != null) 'population_min_1000m': populationMin1000m,
    if (populationMax1000m != null) 'population_max_1000m': populationMax1000m,
    if (layoutPreferences.isNotEmpty) 'layout_preferences': layoutPreferences,
    if (query != null) 'query': query,
    'managed_only': managedOnly,
    'page_size': pageSize,
    if (cursor != null) 'cursor': cursor,
    if (sort != null) 'sort': sort,
  };

  RecommendationSearchRequest copyWith({
    String? businessType,
    String? preferredState,
    String? preferredArea,
    double? minRentalRm,
    double? maxRentalRm,
    double? minSizeSqft,
    double? maxSizeSqft,
    String? propertyType,
    String? city,
    String? floorLevel,
    double? transitMaxM,
    double? nearbyParkingMin,
    double? fnbCompetitionMax,
    String? demandGenerator,
    double? populationMin1000m,
    double? populationMax1000m,
    List<String>? layoutPreferences,
    String? query,
    int? pageSize,
    String? cursor,
    String? sort,
    bool? managedOnly,
    bool clearCursor = false,
    bool clearBusinessType = false,
    bool clearState = false,
    bool clearArea = false,
    bool clearCity = false,
    bool clearAdvanced = false,
    bool clearFloorLevel = false,
    bool clearTransit = false,
    bool clearParking = false,
    bool clearCompetition = false,
    bool clearDemand = false,
    bool clearPopulation = false,
    bool clearPropertyType = false,
    bool clearQuery = false,
    bool clearRentRange = false,
    bool clearSizeRange = false,
  }) => RecommendationSearchRequest(
    businessType: clearBusinessType
        ? null
        : (businessType ?? this.businessType),
    preferredState: clearState ? null : (preferredState ?? this.preferredState),
    preferredArea: clearArea ? null : (preferredArea ?? this.preferredArea),
    minRentalRm: clearRentRange ? null : (minRentalRm ?? this.minRentalRm),
    maxRentalRm: clearRentRange ? null : (maxRentalRm ?? this.maxRentalRm),
    minSizeSqft: clearSizeRange ? null : (minSizeSqft ?? this.minSizeSqft),
    maxSizeSqft: clearSizeRange ? null : (maxSizeSqft ?? this.maxSizeSqft),
    propertyType: clearPropertyType
        ? null
        : (propertyType ?? this.propertyType),
    city: clearCity ? null : (city ?? this.city),
    floorLevel: clearAdvanced || clearFloorLevel
        ? null
        : (floorLevel ?? this.floorLevel),
    transitMaxM: clearAdvanced || clearTransit
        ? null
        : (transitMaxM ?? this.transitMaxM),
    nearbyParkingMin: clearAdvanced || clearParking
        ? null
        : (nearbyParkingMin ?? this.nearbyParkingMin),
    fnbCompetitionMax: clearAdvanced || clearCompetition
        ? null
        : (fnbCompetitionMax ?? this.fnbCompetitionMax),
    demandGenerator: clearAdvanced || clearDemand
        ? null
        : (demandGenerator ?? this.demandGenerator),
    populationMin1000m: clearAdvanced || clearPopulation
        ? null
        : (populationMin1000m ?? this.populationMin1000m),
    populationMax1000m: clearAdvanced || clearPopulation
        ? null
        : (populationMax1000m ?? this.populationMax1000m),
    layoutPreferences: layoutPreferences ?? this.layoutPreferences,
    query: clearQuery ? null : (query ?? this.query),
    pageSize: pageSize ?? this.pageSize,
    cursor: clearCursor ? null : (cursor ?? this.cursor),
    sort: sort ?? this.sort,
    managedOnly: managedOnly ?? this.managedOnly,
  );
}

/// Filter vocabulary and ranges read from the catalogue itself.
/// One interval generated by the backend from the eligible properties.
///
/// Both bounds come from values that actually exist in the scoped catalogue,
/// so selecting an option sends exactly that minimum and maximum to the
/// recommendation search. The count is the number of listings inside the
/// interval, under the other active filters (leave-one-out faceting).
class FacetRangeOption {
  final double min;
  final double max;
  final String label;
  final int total;

  /// False for a saved selection whose bounds the backend did not generate.
  /// It is shown until the entrepreneur changes or clears it — never dropped.
  final bool generated;

  const FacetRangeOption({
    required this.min,
    required this.max,
    required this.label,
    this.total = 0,
    this.generated = true,
  });

  /// Stable identity for a draft selection, including saved custom ranges.
  String get key => '$min|$max';

  static FacetRangeOption? fromJson(
    Object? value, {
    required String minKey,
    required String maxKey,
  }) {
    if (value is! Map<String, dynamic>) return null;
    final min = (value[minKey] as num?)?.toDouble();
    final max = (value[maxKey] as num?)?.toDouble();
    if (min == null || max == null) return null;
    return FacetRangeOption(
      min: min,
      max: max,
      label: '${value['label'] ?? ''}',
      total: (value['total'] as num?)?.toInt() ?? 0,
      generated: value['generated'] != false,
    );
  }

  /// Reads a selection key back into request boundaries. An empty key is
  /// "Any", so both boundaries are cleared.
  static ({double? min, double? max}) boundsFromKey(String key) {
    if (key.isEmpty) return (min: null, max: null);
    final parts = key.split('|');
    if (parts.length != 2) return (min: null, max: null);
    return (min: double.tryParse(parts[0]), max: double.tryParse(parts[1]));
  }
}

/// A filter the backend identified as removable to recover matches.
class FacetRelaxation {
  final String field;
  final String label;
  final int total;

  const FacetRelaxation({
    required this.field,
    required this.label,
    required this.total,
  });

  static FacetRelaxation? fromJson(Object? value) {
    if (value is! Map<String, dynamic> || value['field'] == null) return null;
    return FacetRelaxation(
      field: '${value['field']}',
      label: '${value['label'] ?? value['field']}',
      total: (value['total'] as num?)?.toInt() ?? 0,
    );
  }
}

class RecommendationFacets {
  final List<FacetOption> states;
  final List<FacetOption> cities;
  final List<FacetOption> propertyTypes;

  /// Data-supported advanced filters keyed by backend field. Only fields
  /// with verified measurements appear; the UI never invents an option.
  final Map<String, RecommendationAdvancedFacet> advanced;

  /// The orderings the server accepts, `value -> label`, in server order
  /// (first = default). Read from the API so the UI keeps no second copy of
  /// this list; empty when the facets call failed.
  final Map<String, String> sortOptions;

  /// Contextual monthly-rent intervals, generated from the eligible listings
  /// with the rental filter's own constraint released.
  final List<FacetRangeOption> rentalRanges;
  final List<FacetRangeOption> sizeRanges;

  /// The active bounds even when they are not one of [rentalRanges] — a saved
  /// preference can hold a custom range that must stay visible until changed.
  final FacetRangeOption? selectedRental;
  final FacetRangeOption? selectedSize;

  /// Listings under ALL active filters, and under none of them. Both are
  /// counted before pagination over the same PU-gated population the search
  /// ranks; neither is read from the 20 cards on screen.
  final int matchingTotal;
  final int universeTotal;

  /// Hard filters whose removal would recover matches, server-ranked.
  final List<FacetRelaxation> relaxations;

  /// Backend-defined meaning of each recommendation filter.
  final List<FilterInput> fields;
  final bool contextual;

  final double? minRentalRm;
  final double? maxRentalRm;
  final double? minSizeSqft;
  final double? maxSizeSqft;
  final int total;

  const RecommendationFacets({
    this.states = const [],
    this.cities = const [],
    this.propertyTypes = const [],
    this.advanced = const {},
    this.sortOptions = const {},
    this.rentalRanges = const [],
    this.sizeRanges = const [],
    this.selectedRental,
    this.selectedSize,
    this.matchingTotal = 0,
    this.universeTotal = 0,
    this.relaxations = const [],
    this.fields = const [],
    this.contextual = false,
    this.minRentalRm,
    this.maxRentalRm,
    this.minSizeSqft,
    this.maxSizeSqft,
    this.total = 0,
  });

  factory RecommendationFacets.fromJson(Map<String, dynamic> json) {
    List<FacetOption> options(String key) => [
      for (final row in (json[key] as List? ?? const []))
        if (row is Map<String, dynamic>)
          FacetOption(
            value: '${row['value']}',
            total: (row['total'] as num?)?.toInt() ?? 0,
          ),
    ];
    List<FacetRangeOption> ranges(
      Object? block, {
      required String min,
      required String max,
    }) {
      final result = <FacetRangeOption>[];
      if (block is! Map<String, dynamic>) return result;
      for (final row in (block['options'] as List? ?? const [])) {
        final option = FacetRangeOption.fromJson(row, minKey: min, maxKey: max);
        if (option != null) result.add(option);
      }
      return result;
    }

    final rangesBlock = json['ranges'] as Map<String, dynamic>? ?? const {};
    final rentalBlock = json['rental_ranges'] as Map<String, dynamic>? ?? const {};
    final sizeBlock = json['size_ranges'] as Map<String, dynamic>? ?? const {};
    final relaxationList = <FacetRelaxation>[];
    for (final row in (json['relaxations'] as List? ?? const [])) {
      final relaxation = FacetRelaxation.fromJson(row);
      if (relaxation != null) relaxationList.add(relaxation);
    }
    return RecommendationFacets(
      states: options('states'),
      cities: options('cities'),
      propertyTypes: options('property_types'),
      advanced: {
        for (final entry in (json['advanced'] as Map? ?? const {}).entries)
          if (entry.value is Map)
            '${entry.key}': RecommendationAdvancedFacet.fromJson(
              '${entry.key}',
              Map<String, dynamic>.from(entry.value as Map),
            ),
      },
      sortOptions: {
        for (final row in (json['sort_options'] as List? ?? const []))
          if (row is Map<String, dynamic> && row['value'] != null)
            '${row['value']}': '${row['label'] ?? row['value']}',
      },
      rentalRanges: ranges(
        rentalBlock,
        min: 'min_rental_rm',
        max: 'max_rental_rm',
      ),
      sizeRanges: ranges(
        sizeBlock,
        min: 'min_size_sqft',
        max: 'max_size_sqft',
      ),
      selectedRental: FacetRangeOption.fromJson(
        rentalBlock['selected'],
        minKey: 'min_rental_rm',
        maxKey: 'max_rental_rm',
      ),
      selectedSize: FacetRangeOption.fromJson(
        sizeBlock['selected'],
        minKey: 'min_size_sqft',
        maxKey: 'max_size_sqft',
      ),
      matchingTotal: (json['matching_total'] as num?)?.toInt() ?? 0,
      universeTotal: (json['universe_total'] as num?)?.toInt() ?? 0,
      relaxations: relaxationList,
      fields: [
        for (final row in (json['fields'] as List? ?? const []))
          if (row is Map<String, dynamic>)
            FilterInput(
              key: '${row['key']}',
              label: '${row['label'] ?? row['key']}',
              role: FilterRole.fromWire(row['role']?.toString()),
              effect: '${row['effect'] ?? ''}',
            ),
      ],
      contextual: json['contextual'] == true,
      minRentalRm: (rangesBlock['min_rental_rm'] as num?)?.toDouble(),
      maxRentalRm: (rangesBlock['max_rental_rm'] as num?)?.toDouble(),
      minSizeSqft: (rangesBlock['min_size_sqft'] as num?)?.toDouble(),
      maxSizeSqft: (rangesBlock['max_size_sqft'] as num?)?.toDouble(),
      total: (rangesBlock['total'] as num?)?.toInt() ?? 0,
    );
  }

  /// The role a field plays, for the form's own wording. A key the server did
  /// not describe falls back to [FilterRole.hardFilter], because that is what
  /// the search applies to everything it currently lists in `FILTER_FIELDS`.
  FilterRole roleOf(String key) {
    for (final field in fields) {
      if (field.key == key) return field.role;
    }
    return FilterRole.hardFilter;
  }

  String labelOf(String key, {required String fallback}) {
    for (final field in fields) {
      if (field.key == key) return field.label;
    }
    return fallback;
  }

  String effectOf(String key) {
    for (final field in fields) {
      if (field.key == key) return field.effect;
    }
    return '';
  }
}

/// One data-supported advanced filter and the options the backend generated.
///
/// ``kind`` is `value`, `choice` or a range kind (`max`/`min`/`range`). A
/// backend field with no measurements is simply absent from the map — clients
/// must never render a placeholder control for it.
class RecommendationAdvancedFacet {
  final String key;
  final String label;
  final String kind;
  final String group;
  final String source;
  final List<FacetOption> valueOptions;
  final List<FacetRangeOption> rangeOptions;

  const RecommendationAdvancedFacet({
    required this.key,
    required this.label,
    required this.kind,
    required this.group,
    required this.source,
    this.valueOptions = const [],
    this.rangeOptions = const [],
  });

  bool get isRange => rangeOptions.isNotEmpty || !kind.contains('value');
  bool get isChoice => kind == 'choice';

  static RecommendationAdvancedFacet fromJson(
    String key,
    Map<String, dynamic> json,
  ) {
    final options = json['options'] as List? ?? const [];
    final isRange = ['max', 'min', 'range'].contains(json['kind']);
    return RecommendationAdvancedFacet(
      key: key,
      label: '${json['label'] ?? key}',
      kind: '${json['kind'] ?? 'value'}',
      group: '${json['group'] ?? 'property'}',
      source: '${json['source'] ?? ''}',
      valueOptions: isRange
          ? const []
          : [
              for (final row in options)
                if (row is Map<String, dynamic>)
                  FacetOption(
                    value: '${row['value'] ?? ''}',
                    label: '${row['label'] ?? row['value'] ?? ''}',
                    total: (row['total'] as num?)?.toInt() ?? 0,
                  ),
            ],
      rangeOptions: [
        for (final row in options)
          FacetRangeOption.fromJson(
                row,
                minKey: 'min_value',
                maxKey: 'max_value',
              )
              ?? const FacetRangeOption(min: 0, max: 0, label: ''),
      ]..removeWhere((item) => item.label.isEmpty),
    );
  }
}

/// One selectable filter value with the number of listings behind it.
class FacetOption {
  final String value;
  final String label;
  final int total;

  const FacetOption({
    required this.value,
    this.label = '',
    this.total = 0,
  });
}

/// Whether an input changes WHICH properties qualify, only their order, or
/// neither (because the catalogue cannot answer it).
enum FilterRole {
  /// Applied as a hard constraint on the eligible set.
  hardFilter,

  /// Re-sequences the eligible set; removes nothing.
  rankingOnly,

  /// Recorded nowhere in the catalogue; reported per property as a requirement
  /// that cannot be verified.
  unverified;

  static FilterRole fromWire(String? value) => switch (value) {
    'ranking_only' => FilterRole.rankingOnly,
    'unverified' => FilterRole.unverified,
    _ => FilterRole.hardFilter,
  };
}

/// What one filter input does, in the server's own words.
class FilterInput {
  final String key;
  final String label;
  final FilterRole role;
  final String effect;

  const FilterInput({
    required this.key,
    required this.label,
    required this.role,
    this.effect = '',
  });

  bool get isHardFilter => role == FilterRole.hardFilter;
}

/// An active filter that could be released, with the count releasing it would
/// restore.
class FilterRelaxation {
  /// One of the server's `FILTER_FIELDS` keys, e.g. `rental_budget`.
  final String field;
  final String label;
  final int total;

  const FilterRelaxation({
    required this.field,
    required this.label,
    required this.total,
  });
}

/// One numeric interval from the catalogue, with the listings inside it.
///
/// The bounds are observed listing values, so consecutive intervals neither
/// overlap nor leave a priced listing outside every option, and the count is
/// exactly what sending these two bounds to the search returns.
class FacetRange {
  /// Inclusive lower bound. Null only for a selected open interval, which a
  /// saved preference can hold but a generated bucket never is.
  final double? low;
  final double? high;
  final int total;
  final String label;

  /// False when this is a saved selection the generated buckets do not offer.
  final bool generated;

  const FacetRange({
    this.low,
    this.high,
    this.total = 0,
    this.label = '',
    this.generated = true,
  });

  factory FacetRange.fromJson(
    Map<String, dynamic> json, {
    required String lowKey,
    required String highKey,
  }) => FacetRange(
    low: (json[lowKey] as num?)?.toDouble(),
    high: (json[highKey] as num?)?.toDouble(),
    total: (json['total'] as num?)?.toInt() ?? 0,
    label: '${json['label'] ?? ''}',
    generated: json['generated'] != false,
  );

  /// Whether this interval is the one the two request fields carry.
  bool matches(double? min, double? max) => low == min && high == max;
}
