import '../../domain/entities/commercial_property.dart';

/// A structured property filter, shared by the Flutter and Jaspr trees.
///
/// This is deliberately separate from [FilterProperties], which handles the
/// free-text search box. This type owns the *structured* criteria a filter panel
/// produces — budget, size, type, location, verification — and it is the single
/// definition of "does this property match", so the two apps cannot drift.
///
/// Before this existed the web tree filtered with four hardcoded city chips and
/// the mobile tree had its own `MobilePropertyFilter` in the presentation layer.
/// Both are presentation-level concerns; the rule itself belongs here.
///
/// Every field is optional and defaults to "no constraint", so
/// [PropertyFilter.empty] matches every property. That makes "no filter applied"
/// and "filter applied but permissive" the same state, which is what the UIs
/// need to show an accurate active-filter count.
class PropertyFilter {
  /// Sentinels for the three "any" selections.
  static const String anyType = 'All';
  static const String anyArea = 'All areas';
  static const String anyState = 'All states';

  final double? minRentalRm;
  final double? maxRentalRm;
  final double? minSizeSqft;
  final double? maxSizeSqft;
  final String propertyType;
  final String city;
  final String state;

  /// Restricts to [VerificationStatus.verified] listings only.
  final bool verifiedOnly;

  /// Restricts to listings that carry a published 360° virtual tour
  /// ([CommercialProperty.hasTour]).
  ///
  /// This is a *listing-attribute* filter, not a publication gate: a tour
  /// exists only after the owner's capture is approved, so `true` here can
  /// never surface an unverified listing on its own.
  final bool hasTourOnly;

  const PropertyFilter({
    this.minRentalRm,
    this.maxRentalRm,
    this.minSizeSqft,
    this.maxSizeSqft,
    this.propertyType = anyType,
    this.city = anyArea,
    this.state = anyState,
    this.verifiedOnly = false,
    this.hasTourOnly = false,
  });

  static const PropertyFilter empty = PropertyFilter();

  bool get isEmpty => activeChips.isEmpty;

  bool get isNotEmpty => !isEmpty;

  /// Number of applied criteria — drives the "Filters (3)" badge.
  int get activeCount => activeChips.length;

  /// The applied criteria as removable chips.
  ///
  /// Each chip carries the [id] needed to clear exactly that criterion, so a UI
  /// can render "RM 8,000 max ✕" and remove only that one. Order is stable so
  /// chips do not jump around as the user edits other fields.
  List<FilterChipData> get activeChips => [
    if (minRentalRm != null)
      FilterChipData(
        id: FilterField.minRental,
        label: 'From RM ${_rm(minRentalRm!)}',
      ),
    if (maxRentalRm != null)
      FilterChipData(
        id: FilterField.maxRental,
        label: 'Up to RM ${_rm(maxRentalRm!)}',
      ),
    if (minSizeSqft != null)
      FilterChipData(
        id: FilterField.minSize,
        label: 'From ${_sqft(minSizeSqft!)}',
      ),
    if (maxSizeSqft != null)
      FilterChipData(
        id: FilterField.maxSize,
        label: 'Up to ${_sqft(maxSizeSqft!)}',
      ),
    if (propertyType != anyType)
      FilterChipData(id: FilterField.propertyType, label: propertyType),
    if (city != anyArea) FilterChipData(id: FilterField.city, label: city),
    if (state != anyState) FilterChipData(id: FilterField.state, label: state),
    if (verifiedOnly)
      const FilterChipData(
        id: FilterField.verifiedOnly,
        label: 'Verified only',
      ),
    if (hasTourOnly)
      const FilterChipData(
        id: FilterField.hasTourOnly,
        label: '360° tour only',
      ),
  ];

  /// Validates the numeric ranges.
  ///
  /// Returns a human-readable message, or `null` when the filter is valid. A
  /// min above its max can never match anything, so it is treated as an error
  /// rather than silently returning zero results — the user would otherwise
  /// read "no properties" as a data problem.
  String? validate() {
    if (minRentalRm != null &&
        maxRentalRm != null &&
        minRentalRm! > maxRentalRm!) {
      return 'Minimum rent is above the maximum.';
    }
    if (minSizeSqft != null &&
        maxSizeSqft != null &&
        minSizeSqft! > maxSizeSqft!) {
      return 'Minimum floor area is above the maximum.';
    }
    return null;
  }

  /// Whether [p] satisfies every applied criterion.
  ///
  /// A criterion that is unset never rejects. Rental is compared against
  /// [CommercialProperty.rentalRm] — the asking price — not the upper bound of a
  /// range, because a listing that *might* go to RM 8,000 should still appear
  /// when the user's ceiling is RM 7,500.
  bool matches(CommercialProperty p) {
    if (minRentalRm != null && p.rentalRm < minRentalRm!) return false;
    if (maxRentalRm != null && p.rentalRm > maxRentalRm!) return false;
    if (minSizeSqft != null && p.sizeSqft < minSizeSqft!) return false;
    if (maxSizeSqft != null && p.sizeSqft > maxSizeSqft!) return false;
    if (propertyType != anyType && p.propertyType != propertyType) return false;
    if (city != anyArea && p.city != city) return false;
    if (state != anyState && p.state != state) return false;
    if (verifiedOnly && p.verification != VerificationStatus.verified) {
      return false;
    }
    if (hasTourOnly && !p.hasTour) return false;
    return true;
  }

  /// Applies this filter to [properties], preserving the input order so ranking
  /// from a recommendation is never disturbed.
  List<CommercialProperty> apply(List<CommercialProperty> properties) =>
      properties.where(matches).toList();

  /// Clears exactly one criterion, by chip id.
  PropertyFilter without(String id) {
    switch (id) {
      case FilterField.minRental:
        return copyWith(clearMinRental: true);
      case FilterField.maxRental:
        return copyWith(clearMaxRental: true);
      case FilterField.minSize:
        return copyWith(clearMinSize: true);
      case FilterField.maxSize:
        return copyWith(clearMaxSize: true);
      case FilterField.propertyType:
        return copyWith(propertyType: anyType);
      case FilterField.city:
        return copyWith(city: anyArea);
      case FilterField.state:
        return copyWith(state: anyState);
      case FilterField.verifiedOnly:
        return copyWith(verifiedOnly: false);
      case FilterField.hasTourOnly:
        return copyWith(hasTourOnly: false);
      default:
        return this;
    }
  }

  PropertyFilter copyWith({
    double? minRentalRm,
    bool clearMinRental = false,
    double? maxRentalRm,
    bool clearMaxRental = false,
    double? minSizeSqft,
    bool clearMinSize = false,
    double? maxSizeSqft,
    bool clearMaxSize = false,
    String? propertyType,
    String? city,
    String? state,
    bool? verifiedOnly,
    bool? hasTourOnly,
  }) => PropertyFilter(
    minRentalRm: clearMinRental ? null : (minRentalRm ?? this.minRentalRm),
    maxRentalRm: clearMaxRental ? null : (maxRentalRm ?? this.maxRentalRm),
    minSizeSqft: clearMinSize ? null : (minSizeSqft ?? this.minSizeSqft),
    maxSizeSqft: clearMaxSize ? null : (maxSizeSqft ?? this.maxSizeSqft),
    propertyType: propertyType ?? this.propertyType,
    city: city ?? this.city,
    state: state ?? this.state,
    verifiedOnly: verifiedOnly ?? this.verifiedOnly,
    hasTourOnly: hasTourOnly ?? this.hasTourOnly,
  );

  // --- Option derivation ----------------------------------------------------
  //
  // The web tree used to hardcode ['All', 'Subang Jaya', 'Petaling Jaya',
  // 'Shah Alam']. Those are real places, but they are *data*, so they are
  // derived from the loaded set instead — a new listing in a new city appears in
  // the filter automatically, and a city with no listings never does.

  /// Distinct property types present in [properties], sorted, with the "any"
  /// sentinel first.
  static List<String> typesIn(List<CommercialProperty> properties) {
    final values = {for (final p in properties) p.propertyType}.toList()
      ..sort();
    return [anyType, ...values];
  }

  /// Distinct cities present in [properties].
  static List<String> citiesIn(List<CommercialProperty> properties) {
    final values = {for (final p in properties) p.city}.toList()..sort();
    return [anyArea, ...values];
  }

  /// Distinct states present in [properties].
  static List<String> statesIn(List<CommercialProperty> properties) {
    final values = {for (final p in properties) p.state}.toList()..sort();
    return [anyState, ...values];
  }

  /// Highest asking rental in [properties] — used to bound the budget input so
  /// it never offers a ceiling below the data.
  static double rentalCeilingIn(
    List<CommercialProperty> properties, {
    double fallback = 20000,
  }) {
    if (properties.isEmpty) return fallback;
    return properties.map((p) => p.rentalMaxRm).reduce((a, b) => a > b ? a : b);
  }

  /// Highest floor area in [properties].
  static double sizeCeilingIn(
    List<CommercialProperty> properties, {
    double fallback = 5000,
  }) {
    if (properties.isEmpty) return fallback;
    return properties.map((p) => p.sizeSqft).reduce((a, b) => a > b ? a : b);
  }

  static String _rm(double v) => v.toStringAsFixed(0);

  static String _sqft(double v) => '${v.toStringAsFixed(0)} sq ft';

  @override
  String toString() =>
      'PropertyFilter(${activeChips.map((c) => c.label).join(', ')})';
}

/// Stable identifiers for the clearable criteria.
abstract final class FilterField {
  static const String minRental = 'minRental';
  static const String maxRental = 'maxRental';
  static const String minSize = 'minSize';
  static const String maxSize = 'maxSize';
  static const String propertyType = 'propertyType';
  static const String city = 'city';
  static const String state = 'state';
  static const String verifiedOnly = 'verifiedOnly';
  static const String hasTourOnly = 'hasTourOnly';
}

/// One applied criterion, as a removable chip.
class FilterChipData {
  /// Pass to [PropertyFilter.without] to clear just this criterion.
  final String id;

  /// Human-readable text, e.g. `'Up to RM 8,000'`.
  final String label;

  const FilterChipData({required this.id, required this.label});
}
