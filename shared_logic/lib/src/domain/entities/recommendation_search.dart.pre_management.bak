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

/// One ranked listing: the shared property entity plus its verdict.
class RankedProperty {
  final CommercialProperty property;
  final String source;
  final RecommendationMatch match;

  /// Workbook P-vs-U association index (0–100). A relative research ranking
  /// input, never a probability of business success.
  final double? catalogSuitabilityScore;
  final bool suitabilityAvailable;

  /// PU association. `null` = not loaded in this response (the list endpoint
  /// deliberately does not run 20 model inferences); `available == false`
  /// means the model reported the property as unavailable.
  final double? puScore;
  final bool? puAvailable;

  const RankedProperty({
    required this.property,
    required this.match,
    this.source = 'catalog',
    this.catalogSuitabilityScore,
    this.suitabilityAvailable = false,
    this.puScore,
    this.puAvailable,
  });

  String get id => property.id;

  factory RankedProperty.fromJson(Map<String, dynamic> json) {
    final research = json['research'] as Map<String, dynamic>? ?? const {};
    final suitability = (research['catalog_suitability_score'] as num?)
        ?.toDouble();
    return RankedProperty(
      source: json['property_source'] as String? ?? 'catalog',
      catalogSuitabilityScore: suitability,
      suitabilityAvailable:
          research['suitability_available'] == true && suitability != null,
      puScore: (research['pu_score'] as num?)?.toDouble(),
      puAvailable: research['pu_available'] as bool?,
      match: RecommendationMatch.fromJson(
        json['recommendation'] as Map<String, dynamic>? ?? const {},
      ),
      // The catalogue records no owner, no tour and no owner-verification
      // state, so those fields are reported empty rather than borrowed from
      // an unrelated listing. `verification` stays `pending`: a catalogue row
      // has not been verified as an available listing, and the UI must not
      // imply that it has.
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
        hasTour: false,
        imageUrl: json['image_url'] as String?,
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
  String get label => available
      ? 'Experimental preference match${version == null ? '' : ' · $version'}'
      : 'Requirement-fit ordering (model score unavailable)';
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
  final List<String> layoutPreferences;
  final String? query;
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
    this.layoutPreferences = const [],
    this.query,
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
      businessType: preferences.businessType.isEmpty
          ? null
          : preferences.businessType,
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
      layoutPreferences.isEmpty &&
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
    if (layoutPreferences.isNotEmpty) 'layout_preferences': layoutPreferences,
    if (query != null) 'query': query,
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
    List<String>? layoutPreferences,
    String? query,
    int? pageSize,
    String? cursor,
    String? sort,
    bool clearCursor = false,
    bool clearBusinessType = false,
    bool clearState = false,
    bool clearArea = false,
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
    layoutPreferences: layoutPreferences ?? this.layoutPreferences,
    query: clearQuery ? null : (query ?? this.query),
    pageSize: pageSize ?? this.pageSize,
    cursor: clearCursor ? null : (cursor ?? this.cursor),
    sort: sort ?? this.sort,
  );
}

/// Filter vocabulary and ranges read from the catalogue itself.
class RecommendationFacets {
  final List<FacetOption> states;
  final List<FacetOption> propertyTypes;

  /// The orderings the server accepts, `value -> label`, in server order
  /// (first = default). Read from the API so the UI keeps no second copy of
  /// this list; empty when the facets call failed.
  final Map<String, String> sortOptions;

  final double? minRentalRm;
  final double? maxRentalRm;
  final double? minSizeSqft;
  final double? maxSizeSqft;
  final int total;

  const RecommendationFacets({
    this.states = const [],
    this.propertyTypes = const [],
    this.sortOptions = const {},
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
    final ranges = json['ranges'] as Map<String, dynamic>? ?? const {};
    return RecommendationFacets(
      states: options('states'),
      propertyTypes: options('property_types'),
      sortOptions: {
        for (final row in (json['sort_options'] as List? ?? const []))
          if (row is Map<String, dynamic> && row['value'] != null)
            '${row['value']}': '${row['label'] ?? row['value']}',
      },
      minRentalRm: (ranges['min_rental_rm'] as num?)?.toDouble(),
      maxRentalRm: (ranges['max_rental_rm'] as num?)?.toDouble(),
      minSizeSqft: (ranges['min_size_sqft'] as num?)?.toDouble(),
      maxSizeSqft: (ranges['max_size_sqft'] as num?)?.toDouble(),
      total: (ranges['total'] as num?)?.toInt() ?? 0,
    );
  }
}

/// One selectable filter value with the number of listings behind it.
class FacetOption {
  final String value;
  final int total;

  const FacetOption({required this.value, this.total = 0});
}
