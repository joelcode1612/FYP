import 'package:shared_logic/shared_logic.dart';

/// A missing listing (404) is different from an unreadable or failed request.
/// Never delete a saved ref as a side effect of loading it.
class FavouritePropertyDetails {
  final List<CommercialProperty> properties;
  final Set<String> missing;
  final Map<String, Object> failures;

  const FavouritePropertyDetails({
    required this.properties,
    required this.missing,
    required this.failures,
  });
}

/// Uses the existing application service, not a new transport or repository.
/// Bound concurrent requests to four. One bad record cannot hide other cards.
Future<FavouritePropertyDetails> loadFavouritePropertyDetails(
  PropertyService service,
  Set<String> refs,
) async {
  final ids = refs.toList(growable: false);
  final properties = <CommercialProperty>[];
  final missing = <String>{};
  final failures = <String, Object>{};
  const batchSize = 4;
  for (var offset = 0; offset < ids.length; offset += batchSize) {
    final results = await Future.wait([
      for (final id in ids.skip(offset).take(batchSize))
        _loadOneFavourite(service, id),
    ]);
    for (final result in results) {
      if (result.error != null) {
        failures[result.id] = result.error!;
      } else if (result.property == null) {
        missing.add(result.id);
      } else {
        properties.add(result.property!);
      }
    }
  }
  return FavouritePropertyDetails(
    properties: List.unmodifiable(properties),
    missing: Set.unmodifiable(missing),
    failures: Map.unmodifiable(failures),
  );
}

Future<({String id, CommercialProperty? property, Object? error})>
    _loadOneFavourite(PropertyService service, String id) async {
  try {
    final property = await service.detail(id);
    if (property != null && property.id != id) {
      throw const ResponseFormatFailure('Property identifier mismatch.');
    }
    return (id: id, property: property, error: null);
  } on NotFoundFailure {
    return (id: id, property: null, error: null);
  } on Object catch (error) {
    return (id: id, property: null, error: error);
  }
}
