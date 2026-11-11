import 'malaysia_locations.dart';

/// One commercial property type offered by the Add Property form.
///
/// [label] is what the owner sees; [wire] is the value persisted in
/// `fyp.rental_properties.property_type` (a free-text column, default `Shop`).
/// The list is deliberately limited to F&B commercial premises: residential,
/// office, industrial, warehouse and "unrestricted other" are not SiteWise
/// use cases.
class CommercialPropertyType {
  const CommercialPropertyType(this.label, this.wire);

  final String label;
  final String wire;
}

/// The only property types the Add Property form may submit, in display order.
const List<CommercialPropertyType> commercialPropertyTypes =
    <CommercialPropertyType>[
      CommercialPropertyType('Shoplot', 'Shoplot'),
      CommercialPropertyType('Retail Space', 'Retail Space'),
      CommercialPropertyType('Ground Floor Shop', 'Ground Floor Shop'),
      CommercialPropertyType('Corner Shoplot', 'Corner Shoplot'),
      CommercialPropertyType('Retail Unit', 'Retail Unit'),
      CommercialPropertyType('Kiosk', 'Kiosk'),
      CommercialPropertyType('Commercial F&B Premise', 'Commercial F&B Premise'),
    ];

/// Display labels only (for choice grids / dropdowns).
List<String> get commercialPropertyTypeLabels =>
    commercialPropertyTypes.map((type) => type.label).toList(growable: false);

/// True when [value] is one of the seven allowed commercial types.
bool isCommercialPropertyType(String? value) {
  final needle = (value ?? '').trim().toLowerCase();
  if (needle.isEmpty) return false;
  return commercialPropertyTypes.any(
    (type) => type.label.toLowerCase() == needle,
  );
}

/// Maps a persisted or legacy `property_type` onto an allowed label.
///
/// Older rows use values such as `Shop`, `Shop lot` or `Ground floor retail`.
/// Returning the closest allowed label keeps the edit form valid without
/// rewriting existing records; an unsupported legacy value (office,
/// industrial, ...) returns null so the owner must choose a commercial type.
String? normalizeCommercialPropertyType(String? value) {
  final raw = (value ?? '').trim();
  if (raw.isEmpty) return null;
  for (final type in commercialPropertyTypes) {
    if (type.label.toLowerCase() == raw.toLowerCase() ||
        type.wire.toLowerCase() == raw.toLowerCase()) {
      return type.label;
    }
  }
  final lower = raw.toLowerCase();
  if (lower.contains('corner')) return 'Corner Shoplot';
  if (lower.contains('kiosk')) return 'Kiosk';
  if (lower.contains('f&b') || lower.contains('fnb') || lower.contains('food')) {
    return 'Commercial F&B Premise';
  }
  if (lower.contains('ground')) return 'Ground Floor Shop';
  if (lower.contains('mall') || lower.contains('retail unit')) return 'Retail Unit';
  if (lower.contains('shop') || lower.contains('shophouse')) return 'Shoplot';
  if (lower.contains('retail')) return 'Retail Space';
  return null;
}

/// The wire value persisted for a display label.
String commercialPropertyTypeWire(String label) {
  for (final type in commercialPropertyTypes) {
    if (type.label == label) return type.wire;
  }
  return label;
}

/// Framework-free validation rules shared by the Jaspr and Flutter forms.
///
/// The backend re-validates every one of these rules; this layer exists so the
/// two clients cannot drift apart, not to replace server enforcement.
abstract final class PropertyFormRules {
  static const int titleMinLength = 4;
  static const int titleMaxLength = 160;

  static String? titleError(String? value) {
    final text = (value ?? '').trim();
    if (text.isEmpty) return 'Enter a property title.';
    if (text.length < titleMinLength) {
      return 'Enter a property title of at least $titleMinLength characters.';
    }
    if (text.length > titleMaxLength) {
      return 'Keep the property title under $titleMaxLength characters.';
    }
    return null;
  }

  static String? propertyTypeError(String? value) {
    if (!isCommercialPropertyType(value)) {
      return 'Select a commercial property type.';
    }
    return null;
  }

  static String? rentError(String? value) {
    final text = (value ?? '').trim();
    if (text.isEmpty) return 'Enter the monthly rental.';
    final parsed = double.tryParse(text);
    if (parsed == null || !parsed.isFinite || parsed <= 0) {
      return 'Enter a monthly rental greater than 0.';
    }
    return null;
  }

  static String? areaError(String? value) {
    final text = (value ?? '').trim();
    if (text.isEmpty) return 'Enter the built-up area.';
    final parsed = double.tryParse(text);
    if (parsed == null || !parsed.isFinite || parsed <= 0) {
      return 'Enter a built-up area greater than 0.';
    }
    return null;
  }

  static String? addressError(String? value) {
    final text = (value ?? '').trim();
    if (text.isEmpty) return 'Enter the building/unit number and street address.';
    if (text.length < 5) {
      return 'Enter a complete building/unit number and street address.';
    }
    return null;
  }

  static String? stateError(String? value) {
    if (!MalaysiaLocations.isKnownState(value)) {
      return 'Select a Malaysian state or federal territory.';
    }
    return null;
  }

  static String? cityError(String? state, String? city) {
    final text = (city ?? '').trim();
    if (text.isEmpty) return 'Select a city or township.';
    if (!MalaysiaLocations.isKnownCity(state, text)) {
      return 'Select a city or township listed for the chosen state.';
    }
    return null;
  }

  /// Five digits, and — when [state] and [city] are supplied — a postcode the
  /// dataset actually publishes for that locality. Format plus locality keep
  /// obvious typos out of the form; existence is established by admin review.
  static String? postcodeError(
    String? value, {
    String? state,
    String? city,
  }) {
    final text = (value ?? '').trim();
    if (text.isEmpty) return 'Enter the postcode.';
    if (!RegExp(r'^\d{5}$').hasMatch(text)) {
      return 'Enter a 5-digit Malaysian postcode.';
    }
    if (state != null && city != null && state.isNotEmpty && city.isNotEmpty) {
      if (!MalaysiaLocations.isKnownPostcode(state, city, text)) {
        return 'This postcode is not listed for the selected city.';
      }
    }
    return null;
  }

  static String? coordinateError(double? value, {required bool latitude}) {
    if (value == null || !value.isFinite) {
      return latitude ? 'Latitude is not a valid number.' : 'Longitude is not a valid number.';
    }
    final min = latitude ? -90.0 : -180.0;
    final max = latitude ? 90.0 : 180.0;
    if (value < min || value > max) {
      return latitude
          ? 'Latitude must be between -90 and 90.'
          : 'Longitude must be between -180 and 180.';
    }
    return null;
  }
}
