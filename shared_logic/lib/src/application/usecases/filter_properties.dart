import '../../domain/entities/commercial_property.dart';

/// Business rule: which listings match the current search query and filter.
///
/// Extracted verbatim from `EntrepreneurViewModel.loadExplore()` in the Flutter
/// app, where this predicate was inlined in the presentation layer. It is a
/// genuine business rule — the definition of "matches" — so it belongs in the
/// shared application layer where both apps use the same one instead of each
/// re-implementing it.
///
/// A listing matches when:
///   * the query is empty, or the lowercased query appears in the concatenated
///     `title city state address id` (the id is searchable so the explore tab
///     can be driven straight from a record's identifier, and the state is
///     searchable so "Selangor" / "Penang" work without opening a filter);
///     **and**
///   * the filter is `'All'`, or equals the property type, or equals the city.
///
/// Note the original matched the filter against *either* type or city — that is
/// preserved deliberately, including the consequence that a filter value which
/// is neither is treated as matching nothing.
class FilterProperties {
  const FilterProperties();

  List<CommercialProperty> call({
    required List<CommercialProperty> properties,
    required String query,
    required String filter,
  }) {
    final needle = query.toLowerCase();
    return properties.where((p) {
      final matchesQuery =
          query.isEmpty ||
          '${p.title} ${p.city} ${p.state} ${p.address} ${p.id}'
              .toLowerCase()
              .contains(needle);
      final matchesFilter =
          filter == 'All' || p.propertyType == filter || p.city == filter;
      return matchesQuery && matchesFilter;
    }).toList();
  }
}
