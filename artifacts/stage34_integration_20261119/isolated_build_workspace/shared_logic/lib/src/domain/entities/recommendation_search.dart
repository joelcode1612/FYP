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
/// One category's conditional resemblance score (0–1) from the Stage-2 model.
class CategoryResemblance {
  final String businessType;
  final double score;
  final int rank;

  const CategoryResemblance({
    required this.businessType,
    required this.score,
    required this.rank,
  });

  factory CategoryResemblance.fromJson(Map<String, dynamic> json) =>
      CategoryResemblance(
        businessType: '${json['business_type'] ?? ''}',
        score: (json['score'] as num?)?.toDouble() ?? 0,
        rank: (json['rank'] as num?)?.toInt() ?? 0,
      );
}

/// Stage-2 evidence attached to one ranked property.
///
/// The score is a conditional resemblance among four observed F&B categories
/// — never a success probability, and never blended into the PU score or the
/// preference fit.
class CategoryEvidence {
  final bool available;
  final String? modelVersion;
  final List<CategoryResemblance> rankings;
  final String? topCategory;
  final double? topScore;

  /// The selected business type's own position, when the search carried one.
  final CategoryResemblance? selectedCategory;
  final String? reliability;
  final String? note;
  final String? reason;

  const CategoryEvidence({
    required this.available,
    this.modelVersion,
    this.rankings = const [],
    this.topCategory,
    this.topScore,
    this.selectedCategory,
    this.reliability,
    this.note,
    this.reason,
  });

  factory CategoryEvidence.fromJson(Map<String, dynamic> json) {
    final selected = json['selected_category'];
    return CategoryEvidence(
      available: json['available'] == true,
      modelVersion: json['model_version']?.toString(),
      rankings: [
        for (final r in (json['rankings'] as List? ?? const []))
          if (r is Map<String, dynamic>) CategoryResemblance.fromJson(r),
      ],
      topCategory: json['top_category']?.toString(),
      topScore: (json['top_score'] as num?)?.toDouble(),
      selectedCategory: selected is Map<String, dynamic>
          ? CategoryResemblance(
              businessType: '${selected['business_type'] ?? ''}',
              score: (selected['score'] as num?)?.toDouble() ?? 0,
              rank: (selected['rank'] as num?)?.toInt() ?? 0,
            )
          : null,
      reliability: json['reliability']?.toString(),
      note: json['note']?.toString(),
      reason: json['reason']?.toString(),
    );
  }

  /// True when the backend flags weak discrimination (research-only model).
  bool get isWeak => (reliability ?? '').contains('weak');
}

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

  /// Stage-2 business-type resemblance, when the two-stage research variant
  /// produced it. Deliberately separate from [puScore] and from the
  /// requirement-fit fields: three scores, three meanings.
  final CategoryEvidence? category;

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
    this.category,
  });

  String get id => property.id;

  factory RankedProperty.fromJson(Map<String, dynamic> json) {
    final research = json['research'] as Map<String, dynamic>? ?? const {};
    final suitability = (research['catalog_suitability_score'] as num?)
        ?.toDouble();
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
      category: json['category'] is Map<String, dynamic>
          ? CategoryEvidence.fromJson(json['category'] as Map<String, dynamic>)
          : null,
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

  /// The criteria a contextual facets call needs.
  ///
  /// Only the hard filters are sent, because only they can change a count:
  /// `business_type` re-sequences the eligible set and `layout_preferences` is
  /// a requirement the catalogue records no column for, so neither adds nor
  /// removes a listing. Both the GET parameter names and their values are the
  /// search request's own — one vocabulary, so an option can never be priced
  /// by a rule the search does not apply.
  Map<String, String> get facetsQuery => {
    if (preferredState != null) 'preferred_state': preferredState!,
    if (preferredArea != null) 'preferred_area': preferredArea!,
    if (minRentalRm != null) 'min_rental_rm': _plain(minRentalRm!),
    if (maxRentalRm != null) 'max_rental_rm': _plain(maxRentalRm!),
    if (minSizeSqft != null) 'min_size_sqft': _plain(minSizeSqft!),
    if (maxSizeSqft != null) 'max_size_sqft': _plain(maxSizeSqft!),
    if (propertyType != null) 'property_type': propertyType!,
    if (query != null) 'query': query!,
    if (managedOnly) 'managed_only': 'true',
  };

  /// Query parameters are compared as text, so a whole number must not arrive
  /// as `3000.0` while the search sends `3000`.
  static String _plain(double value) => value == value.roundToDouble()
      ? value.toStringAsFixed(0)
      : '$value';

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
    managedOnly: managedOnly ?? this.managedOnly,
  );
}

/// Filter vocabulary and intervals, counted over the listings the CURRENT
/// selections still leave eligible.
///
/// The server prices each field leave-one-out: every OTHER hard filter is
/// applied and only that field's own constraint is released. Choosing Johor
/// therefore re-counts the property types, budgets and sizes over Johor
/// listings, and choosing a budget restates which states still have anything
/// inside it. Nothing here is derived locally — a hand-built option list
/// drifts, and an option that matches no row silently filters everything out.
class RecommendationFacets {
  final List<FacetOption> states;
  final List<FacetOption> propertyTypes;

  /// The orderings the server accepts, `value -> label`, in server order
  /// (first = default). Read from the API so the UI keeps no second copy of
  /// this list; empty when the facets call failed.
  final Map<String, String> sortOptions;

  /// Monthly-rent intervals of the scoped set. `low`/`high` are the exact
  /// `min_rental_rm`/`max_rental_rm` a search must receive to return them.
  final List<FacetRange> rentalRanges;

  /// Floor-area intervals of the scoped set, keyed to `min_size_sqft`/
  /// `max_size_sqft`.
  final List<FacetRange> sizeRanges;

  /// Listings the scoped set holds with NO budget chosen, and with no size
  /// chosen — the counts the "any" option carries.
  final int rentalUnboundedTotal;
  final int sizeUnboundedTotal;

  /// The interval the selections describe, whether or not the server generated
  /// it as a bucket. A saved preference can hold a bound the catalogue never
  /// offers as a range (a ceiling with no floor); reporting it separately keeps
  /// that choice visible and counted instead of pretending it was never made.
  final FacetRange? selectedRentalRange;
  final FacetRange? selectedSizeRange;

  /// Listings matching every selection, counted before pagination over the
  /// whole eligible population — never from the current result page. Null
  /// until the first facets response arrives.
  final int? matchingTotal;

  /// Listings in the PU-gated population the search ranks.
  final int universeTotal;

  /// Each active hard filter with the number of listings that remain if ONLY
  /// it is released. These are the alternatives a conflict panel can offer
  /// with real counts, in the server's own most-promising-first order.
  final List<FilterRelaxation> relaxations;

  /// What each input actually does, so the form can tell a hard filter from a
  /// ranking input and from a requirement the catalogue cannot verify.
  final List<FilterInput> fields;

  /// The PU eligibility gate these counts already respect, so the UI quotes
  /// the threshold the backend applied instead of its own copy.
  final double? puThreshold;

  /// False when the server predates contextual facets (its counts are
  /// catalogue-wide) or the response carried no flag.
  final bool contextual;

  const RecommendationFacets({
    this.states = const [],
    this.propertyTypes = const [],
    this.sortOptions = const {},
    this.rentalRanges = const [],
    this.sizeRanges = const [],
    this.rentalUnboundedTotal = 0,
    this.sizeUnboundedTotal = 0,
    this.selectedRentalRange,
    this.selectedSizeRange,
    this.matchingTotal,
    this.universeTotal = 0,
    this.relaxations = const [],
    this.fields = const [],
    this.puThreshold,
    this.contextual = false,
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
    FacetRange? block(String key, String lowKey, String highKey) {
      final section = json[key] as Map<String, dynamic>? ?? const {};
      final selected = section['selected'];
      return selected is Map<String, dynamic>
          ? FacetRange.fromJson(selected, lowKey: lowKey, highKey: highKey)
          : null;
    }

    List<FacetRange> blocks(String key, String lowKey, String highKey) {
      final section = json[key] as Map<String, dynamic>? ?? const {};
      return [
        for (final row in (section['options'] as List? ?? const []))
          if (row is Map<String, dynamic>)
            FacetRange.fromJson(row, lowKey: lowKey, highKey: highKey),
      ];
    }

    final eligibility = json['pu_eligibility'] as Map<String, dynamic>?;
    return RecommendationFacets(
      states: options('states'),
      propertyTypes: options('property_types'),
      sortOptions: {
        for (final row in (json['sort_options'] as List? ?? const []))
          if (row is Map<String, dynamic> && row['value'] != null)
            '${row['value']}': '${row['label'] ?? row['value']}',
      },
      rentalRanges: blocks('rental_ranges', 'min_rental_rm', 'max_rental_rm'),
      sizeRanges: blocks('size_ranges', 'min_size_sqft', 'max_size_sqft'),
      rentalUnboundedTotal:
          ((json['rental_ranges'] as Map?)?['unbounded_total'] as num?)
              ?.toInt() ??
          0,
      sizeUnboundedTotal:
          ((json['size_ranges'] as Map?)?['unbounded_total'] as num?)?.toInt() ??
          0,
      selectedRentalRange: block(
        'rental_ranges',
        'min_rental_rm',
        'max_rental_rm',
      ),
      selectedSizeRange: block('size_ranges', 'min_size_sqft', 'max_size_sqft'),
      matchingTotal: (json['matching_total'] as num?)?.toInt(),
      universeTotal: (json['universe_total'] as num?)?.toInt() ?? 0,
      relaxations: [
        for (final row in (json['relaxations'] as List? ?? const []))
          if (row is Map<String, dynamic>)
            FilterRelaxation(
              field: '${row['field']}',
              label: '${row['label']}',
              total: (row['total'] as num?)?.toInt() ?? 0,
            ),
      ],
      fields: [
        for (final row in (json['fields'] as List? ?? const []))
          if (row is Map<String, dynamic>)
            FilterInput(
              key: '${row['key']}',
              label: '${row['label']}',
              role: FilterRole.fromWire(row['role']?.toString()),
              effect: '${row['effect'] ?? ''}',
            ),
      ],
      puThreshold: (eligibility?['threshold'] as num?)?.toDouble(),
      contextual: json['contextual'] == true,
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

/// One selectable filter value with the number of listings behind it.
class FacetOption {
  final String value;
  final int total;

  const FacetOption({required this.value, this.total = 0});
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
