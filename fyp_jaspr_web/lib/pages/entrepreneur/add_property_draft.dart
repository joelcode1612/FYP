/// In-memory presentation state for all five Add Property screens.
/// This is not persisted and deliberately has no backend dependency.
class AddPropertyDraft {
  String propertyName = 'SS15 Corner Retail';
  String propertyType = 'Shoplot';
  String monthlyRent = '7800';
  String builtUpArea = '1680';
  String address = '';
  String state = 'Selangor';
  String district = 'Petaling';
  String postcode = '';
  String latitude = '';
  String longitude = '';

  static String display(String value) =>
      value.trim().isEmpty ? 'Not provided' : value;
}
