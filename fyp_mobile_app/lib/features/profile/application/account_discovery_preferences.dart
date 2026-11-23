// sitewise-expanded-user-preferences-v1
import 'package:shared_logic/shared_logic.dart';

/// Account-scoped defaults, read from the existing preferences endpoint.
/// Location and notification flags record intent only; they do not grant
/// device permissions or enable background tracking/notification delivery.
class AccountDiscoveryPreferences {
  final Map<String, dynamic> raw;
  final Map<String, dynamic> settings;

  AccountDiscoveryPreferences(Map<String, dynamic>? value)
      : raw = Map.unmodifiable(value ?? const <String, dynamic>{}),
        settings = Map.unmodifiable(
          value?['user_settings'] is Map
              ? Map<String, dynamic>.from(value!['user_settings'] as Map)
              : const <String, dynamic>{},
        );

  static const sorts = <String, String>{
    'best_match': 'Recommended properties first',
    'rent_asc': 'Lowest monthly rent',
    'rent_desc': 'Highest monthly rent',
    'size_asc': 'Smallest floor area',
    'size_desc': 'Largest floor area',
    'pu_desc': 'Highest PU research index',
  };

  String text(String key) => settings[key] is String
      ? (settings[key] as String).trim() : '';
  double? _number(Map<String, dynamic> source, String key, {bool zero = false}) {
    final value = source[key];
    if (value is! num || !value.isFinite || value < 0 || (!zero && value == 0)) {
      return null;
    }
    return value.toDouble();
  }
  String? _nonEmpty(String value) => value.isEmpty || value == 'Any' ? null : value;
  String get state => text('preferred_state');
  String get city => text('preferred_city');
  int get radius => settings['search_radius_m'] == 1000 ? 1000 : 500;
  String get sort => sorts.containsKey(text('default_sort'))
      ? text('default_sort') : 'best_match';

  RecommendationSearchRequest recommendationRequest() {
    final type = raw['property_type']?.toString().trim() ?? '';
    final market = raw['target_market']?.toString().trim() ?? '';
    return RecommendationSearchRequest(
      preferredState: _nonEmpty(state),
      preferredArea: _nonEmpty(city),
      minRentalRm: _number(raw, 'min_budget_rm'),
      maxRentalRm: _number(raw, 'max_budget_rm') ?? _number(raw, 'max_monthly_rent_myr'),
      minSizeSqft: _number(raw, 'min_size_sqft') ?? _number(raw, 'min_floor_area_sqft'),
      maxSizeSqft: _number(raw, 'max_size_sqft'),
      propertyType: _nonEmpty(type),
      layoutPreferences: <String>{
        if (raw['requirements'] is List)
          for (final value in (raw['requirements'] as List).whereType<String>())
            if (value.trim().isNotEmpty) value.trim(),
        if (market.isNotEmpty) market,
      }.toList(),
      transitMaxM: _number(settings, 'transit_max_m'),
      nearbyParkingMin: _number(settings, 'nearby_parking_min'),
      fnbCompetitionMax: _number(settings, 'fnb_competition_max', zero: true),
      sort: sort,
    );
  }

  PropertyFilter listingFilter() {
    final request = recommendationRequest();
    return PropertyFilter(
      state: request.preferredState ?? PropertyFilter.anyState,
      city: request.preferredArea ?? PropertyFilter.anyArea,
      propertyType: request.propertyType ?? PropertyFilter.anyType,
      minRentalRm: request.minRentalRm,
      maxRentalRm: request.maxRentalRm,
      minSizeSqft: request.minSizeSqft,
      maxSizeSqft: request.maxSizeSqft,
    );
  }

  ExploreSortOption get listingSort => switch (sort) {
    'rent_asc' => ExploreSortOption.priceAsc,
    'rent_desc' => ExploreSortOption.priceDesc,
    'size_asc' => ExploreSortOption.sizeAsc,
    'size_desc' => ExploreSortOption.sizeDesc,
    _ => ExploreSortOption.newest,
  };
}
