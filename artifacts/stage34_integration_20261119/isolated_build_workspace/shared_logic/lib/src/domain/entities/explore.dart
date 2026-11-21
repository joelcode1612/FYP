import 'commercial_property.dart';

/// Server-driven Explore contract over the authenticated FastAPI
/// `/api/v1/explore/*` endpoints (`backend/src/sitewise/api/v1/explore.py`,
/// table `fyp.rental_properties`).
///
/// These entities mirror the backend's actual response columns — nothing here
/// is invented. Nullable means the backend returned SQL NULL for that column
/// (or the endpoint reported `available: false`), and every consumer must
/// render that honestly rather than substituting a zero.

/// Sort keys the backend's `_SORTS` map accepts. Anything else silently falls
/// back to `newest` server-side, so the client only ever sends these.
enum ExploreSortOption {
  newest('newest'),
  priceAsc('price_asc'),
  priceDesc('price_desc'),
  sizeAsc('size_asc'),
  sizeDesc('size_desc'),
  psfAsc('psf_asc');

  final String wire;
  const ExploreSortOption(this.wire);
}

/// One page of an Explore search: the structured criteria the backend
/// actually accepts as query parameters.
///
/// [query] searches name/address/city/property type server-side
/// (`ILIKE %term%`); [state], [city], [propertyType] and [availability] are
/// exact matches; the numeric bounds are inclusive. [limit] is capped at 100
/// by the backend (`Query(le=100)`).
class ExploreQuery {
  final String query;
  final String? state;
  final String? city;
  final String? propertyType;
  final String? availability;
  final double? minPrice;
  final double? maxPrice;
  final double? minSize;
  final double? maxSize;

  /// `true` sends `fnb_suitable=true`, restricting to rows where
  /// `is_fnb_suitable = 1`.
  final bool fnbSuitable;

  /// Spatial default filter. When `true`, the request carries
  /// `min_nearby_properties` + `nearby_radius_m`: only listings with at
  /// least [minNearbyProperties] OTHER approved+published listings within
  /// [nearbyRadiusM] (geodesic PostGIS metres) come back, and every row
  /// carries its real `nearbyPropertyCount`. `false` keeps the wire format
  /// identical to the pre-filter API.
  final bool nearbyOnly;

  /// Neighbour threshold for [nearbyOnly]. The product default is 3
  /// ("3+ properties nearby").
  final int minNearbyProperties;

  /// Geodesic radius in metres for [nearbyOnly]. The backend accepts only
  /// (250, 500, 1000); 500 m is the product default.
  final int nearbyRadiusM;

  final ExploreSortOption sort;
  final int limit;
  final int offset;

  const ExploreQuery({
    this.query = '',
    this.state,
    this.city,
    this.propertyType,
    this.availability,
    this.minPrice,
    this.maxPrice,
    this.minSize,
    this.maxSize,
    this.fnbSuitable = false,
    this.nearbyOnly = false,
    this.minNearbyProperties = 3,
    this.nearbyRadiusM = 500,
    this.sort = ExploreSortOption.newest,
    this.limit = 24,
    this.offset = 0,
  }) : assert(
         minNearbyProperties >= 1,
         'minNearbyProperties must be >= 1 (backend rejects 0 with 422)',
       ),
             assert(
        // A constant-expression comparison, not `const [..].contains(..)`:
        // a method invocation is not a potentially-constant expression, so
        // the list form fails to compile in a const constructor initializer.
        nearbyRadiusM == 250 ||
            nearbyRadiusM == 500 ||
            nearbyRadiusM == 1000,
        'nearbyRadiusM must be one of (250, 500, 1000) — backend whitelist',
      );

  /// The first page for these criteria.
  ExploreQuery firstPage() => copyWith(offset: 0);

  /// The next page after [page], preserving every criterion.
  ExploreQuery nextPage(int fetchedSoFar) =>
      copyWith(offset: offset + fetchedSoFar);

  bool get isConstrained =>
      query.isNotEmpty ||
      state != null ||
      city != null ||
      propertyType != null ||
      availability != null ||
      minPrice != null ||
      maxPrice != null ||
      minSize != null ||
      maxSize != null ||
      fnbSuitable;

  /// Builds a map from a [PropertyFilter]-shaped criteria set plus a search
  /// term, so the existing shared filter vocabulary can drive the server
  /// query without a second filter model.
  factory ExploreQuery.fromCriteria({
    String query = '',
    String? state,
    String? city,
    String? propertyType,
    String? availability,
    double? minPrice,
    double? maxPrice,
    double? minSize,
    double? maxSize,
    bool fnbSuitable = false,
    bool nearbyOnly = false,
    int minNearbyProperties = 3,
    int nearbyRadiusM = 500,
    ExploreSortOption sort = ExploreSortOption.newest,
    int limit = 24,
    int offset = 0,
  }) => ExploreQuery(
    query: query,
    state: (state == null || state.isEmpty) ? null : state,
    city: (city == null || city.isEmpty) ? null : city,
    propertyType:
        (propertyType == null || propertyType == 'Any' || propertyType.isEmpty)
        ? null
        : propertyType,
    availability:
        (availability == null || availability.isEmpty) ? null : availability,
    minPrice: minPrice,
    maxPrice: maxPrice,
    minSize: minSize,
    maxSize: maxSize,
    fnbSuitable: fnbSuitable,
    nearbyOnly: nearbyOnly,
    minNearbyProperties: minNearbyProperties,
    nearbyRadiusM: nearbyRadiusM,
    sort: sort,
    limit: limit,
    offset: offset,
  );

  ExploreQuery copyWith({
    String? query,
    String? state,
    String? city,
    String? propertyType,
    String? availability,
    double? minPrice,
    bool clearMinPrice = false,
    double? maxPrice,
    bool clearMaxPrice = false,
    double? minSize,
    bool clearMinSize = false,
    double? maxSize,
    bool clearMaxSize = false,
    bool? fnbSuitable,
    bool? nearbyOnly,
    int? minNearbyProperties,
    int? nearbyRadiusM,
    ExploreSortOption? sort,
    int? limit,
    int? offset,
  }) => ExploreQuery(
    query: query ?? this.query,
    state: state ?? this.state,
    city: city ?? this.city,
    propertyType: propertyType ?? this.propertyType,
    availability: availability ?? this.availability,
    minPrice: clearMinPrice ? null : (minPrice ?? this.minPrice),
    maxPrice: clearMaxPrice ? null : (maxPrice ?? this.maxPrice),
    minSize: clearMinSize ? null : (minSize ?? this.minSize),
    maxSize: clearMaxSize ? null : (maxSize ?? this.maxSize),
    fnbSuitable: fnbSuitable ?? this.fnbSuitable,
    nearbyOnly: nearbyOnly ?? this.nearbyOnly,
    minNearbyProperties: minNearbyProperties ?? this.minNearbyProperties,
    nearbyRadiusM: nearbyRadiusM ?? this.nearbyRadiusM,
    sort: sort ?? this.sort,
    limit: limit ?? this.limit,
    offset: offset ?? this.offset,
  );

  /// Query parameters exactly as the FastAPI route declares them. Empty
  /// strings and nulls are omitted so the backend keeps its own defaults.
  Map<String, String> toQueryMap() => {
    if (query.isNotEmpty) 'q': query,
    if (state != null) 'state': state!,
    if (city != null) 'city': city!,
    if (propertyType != null) 'property_type': propertyType!,
    if (availability != null) 'availability': availability!,
    if (minPrice != null) 'min_price': _num(minPrice!),
    if (maxPrice != null) 'max_price': _num(maxPrice!),
    if (minSize != null) 'min_size': _num(minSize!),
    if (maxSize != null) 'max_size': _num(maxSize!),
    if (fnbSuitable) 'fnb_suitable': 'true',
    if (nearbyOnly) ...{
      'min_nearby_properties': '$minNearbyProperties',
      'nearby_radius_m': '$nearbyRadiusM',
    },
    'sort': sort.wire,
    'limit': '$limit',
    'offset': '$offset',
  };

  static String _num(double v) =>
      v == v.roundToDouble() ? v.round().toString() : '$v';
}

/// Filter facets served by `GET /explore/options` — read from the database so
/// an option can never match zero rows. [publishedTotal] is the count of
/// approved + published listings the search runs against.
class ExploreFilterOptions {
  final List<String> states;
  final List<String> cities;
  final List<String> propertyTypes;
  final List<String> availability;
  final int publishedTotal;

  const ExploreFilterOptions({
    required this.states,
    required this.cities,
    required this.propertyTypes,
    required this.availability,
    required this.publishedTotal,
  });
}

/// One page of search results plus the server's paging metadata.
class ExplorePage {
  final List<CommercialProperty> items;
  final int total;

  /// The limit/offset echoed by the server, so a caller can detect short
  /// pages and server-side paging drift instead of guessing.
  final int limit;
  final int offset;

  const ExplorePage({
    required this.items,
    required this.total,
    required this.limit,
    required this.offset,
  });

  /// True when another page exists for the criteria that produced this page.
  bool get hasMore => offset + items.length < total;
}

/// One stored photograph (`fyp.property_photos`). [url] is the only required
/// field because the backend table can hold rows whose url is present but
/// caption is null — never the other way round.
class PropertyPhoto {
  final String url;

  /// `is_primary` from the table; a listing has at most one primary photo.
  final bool isPrimary;
  final String? caption;

  const PropertyPhoto({required this.url, this.isPrimary = false, this.caption});
}

/// The `fyp.property_features` row for a listing, when one exists.
class PropertyAmenities {
  final String? suitableFor;
  final String? nearbyLandmarks;
  final String? amenities;
  final String? remarks;

  const PropertyAmenities({
    this.suitableFor,
    this.nearbyLandmarks,
    this.amenities,
    this.remarks,
  });
}

/// One `fyp.property_listing_sources` row: where the listing was imported
/// from and when its availability was last observed.
class ListingSource {
  final String? platform;
  final String? listingId;
  final String? url;
  final String? availability;
  final DateTime? observedAt;
  final DateTime? checkedAt;

  const ListingSource({
    this.platform,
    this.listingId,
    this.url,
    this.availability,
    this.observedAt,
    this.checkedAt,
  });
}

/// A detail payload: the same row shape the list serves plus photos,
/// amenities and listing sources. [property] is never null — a missing
/// listing is a repository error, not an entity with blank fields.
class ExplorePropertyDetail {
  final CommercialProperty property;
  final List<PropertyPhoto> photos;
  final PropertyAmenities? amenities;
  final List<ListingSource> listingSources;

  const ExplorePropertyDetail({
    required this.property,
    this.photos = const [],
    this.amenities,
    this.listingSources = const [],
  });

  /// Primary photo URL, or null when the listing has none (the photos table
  /// can be empty — that state must reach the UI verbatim).
  String? get primaryImageUrl {
    for (final photo in photos) {
      if (photo.isPrimary) return photo.url;
    }
    return photos.isEmpty ? null : photos.first.url;
  }
}

/// One nearby F&B competitor outlet from `fnb_a.fnb_outlet` — a real
/// research record, NOT a nearby commercial property and NOT an aggregate
/// count. Distances come from the backend's `ST_DistanceSphere`.
class NearbyOutlet {
  final String outletKey;
  final String? name;
  final String? category;
  final String? brand;
  final String? streetAddress;
  final String? city;
  final double? latitude;
  final double? longitude;
  final double distanceM;

  /// `openstreetmap` or `overture` — which provider supplied this record.
  final String? provider;

  /// `unknown` when the provider cannot establish it (Overture's
  /// `operating_status` is NULL for essentially every row in this release).
  final String? operatingStatus;

  /// Provider licence + dataset snapshot, preserved for attribution.
  final String? sourceLicence;
  final String? sourceSnapshot;

  const NearbyOutlet({
    required this.outletKey,
    required this.distanceM,
    this.name,
    this.category,
    this.brand,
    this.streetAddress,
    this.city,
    this.latitude,
    this.longitude,
    this.provider,
    this.operatingStatus,
    this.sourceLicence,
    this.sourceSnapshot,
  });
}

/// The competitor lookup result. [available] is false exactly when the
/// property has no coordinates — the backend's honest "cannot compute" state,
/// distinct from an empty list around a real location.
class NearbyOutlets {
  final bool available;
  final int radiusM;
  final List<NearbyOutlet> outlets;

  /// `meta.counts` from the backend: `osm`, `overture_raw`,
  /// `overture_unique`, `merged` and `duplicates_removed` for the radius.
  /// Empty when the backend did not report them (older response).
  final Map<String, int> counts;

  const NearbyOutlets({
    required this.available,
    required this.radiusM,
    this.outlets = const [],
    this.counts = const {},
  });

  /// The deduplicated number a user should see (falls back to the list length).
  int? get mergedCount => counts['merged'];
}

/// One demand generator (mall, transit hub, office cluster…) from
/// `demand_gen.subjects` within the radius.
class NearbyDemandGenerator {
  final int subjectId;
  final String? name;
  final String? category;
  final double? latitude;
  final double? longitude;
  final double distanceM;

  const NearbyDemandGenerator({
    required this.subjectId,
    required this.distanceM,
    this.name,
    this.category,
    this.latitude,
    this.longitude,
  });
}

/// The demand-generator lookup result; same honesty contract as
/// [NearbyOutlets].
class NearbyDemandGenerators {
  final bool available;
  final int radiusM;
  final List<NearbyDemandGenerator> generators;

  const NearbyDemandGenerators({
    required this.available,
    required this.radiusM,
    this.generators = const [],
  });
}

/// DOSM/population-raster indicators for one property, joined through its
/// verified research link. Every figure is nullable because the whole record
/// is `available: false` when no verified link exists, and individual rings
/// can be NULL inside an available record.
class PopulationProfile {
  final bool available;
  final double? popTotal200m;
  final double? popTotal1km;
  final double? popTotal3km;
  final double? popRing0To500m;
  final double? popRing500To1km;
  final double? densityPerKm2;
  final double? density500mPerKm2;
  final double? pctAge20To34Within1km;
  final double? pctAge15To64Within1km;
  final double? estimatedHouseholds1km;
  final int? residentialBuildings500m;
  final int? residentialBuildings1km;
  final double? officeFloorArea500mSqM;
  final int? schools1km;
  final int? malls1km;
  final int? universities1km;
  final int? hospitals1km;
  final int? officePois500m;
  final String? source;
  final int? sourceYear;
  final String? qualityFlag;

  const PopulationProfile({
    required this.available,
    this.popTotal200m,
    this.popTotal1km,
    this.popTotal3km,
    this.popRing0To500m,
    this.popRing500To1km,
    this.densityPerKm2,
    this.density500mPerKm2,
    this.pctAge20To34Within1km,
    this.pctAge15To64Within1km,
    this.estimatedHouseholds1km,
    this.residentialBuildings500m,
    this.residentialBuildings1km,
    this.officeFloorArea500mSqM,
    this.schools1km,
    this.malls1km,
    this.universities1km,
    this.hospitals1km,
    this.officePois500m,
    this.source,
    this.sourceYear,
    this.qualityFlag,
  });

  static const PopulationProfile unavailable = PopulationProfile(
    available: false,
  );
}
