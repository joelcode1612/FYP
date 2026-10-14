/// Outbound payload for creating/updating a property (§32, §40).
/// Mirrors the Supabase/API contract; domain entities never leak here.
class PropertyDto {
  final String? id;
  final String title;
  final String address;
  final String city;
  final String state;
  final String postcode;
  final double rentalRm;
  final double rentalMaxRm;
  final double sizeSqft;
  final double latitude;
  final double longitude;
  final String propertyType;
  final String ownerId;

  const PropertyDto({
    this.id,
    required this.title,
    required this.address,
    required this.city,
    required this.state,
    required this.postcode,
    required this.rentalRm,
    required this.rentalMaxRm,
    required this.sizeSqft,
    required this.latitude,
    required this.longitude,
    required this.propertyType,
    required this.ownerId,
  });

  Map<String, dynamic> toMap() => {
    if (id != null) 'id': id,
    'title': title,
    'address': address,
    'city': city,
    'state': state,
    'postcode': postcode,
    'rental_rm': rentalRm,
    'rental_max_rm': rentalMaxRm,
    'size_sqft': sizeSqft,
    'latitude': latitude,
    'longitude': longitude,
    'property_type': propertyType,
    'owner_id': ownerId,
    'verification': 'draft',
  };
}
