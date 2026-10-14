import '../../domain/entities/commercial_property.dart';

/// Data model with (de)serialisation. Convert to domain via [toEntity].
class CommercialPropertyModel {
  final String id;
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
  final String verification;
  final double suitabilityScore;
  final String ownerId;
  final bool hasTour;
  final List<String> requirements;
  final List<String> tags;

  const CommercialPropertyModel({
    required this.id,
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
    required this.verification,
    required this.suitabilityScore,
    required this.ownerId,
    required this.hasTour,
    this.requirements = const [],
    this.tags = const [],
  });

  factory CommercialPropertyModel.fromMap(Map<String, dynamic> map) =>
      CommercialPropertyModel(
        id: '${map['id']}',
        title: '${map['title']}',
        address: '${map['address'] ?? ''}',
        city: '${map['city'] ?? ''}',
        state: '${map['state'] ?? ''}',
        postcode: '${map['postcode'] ?? ''}',
        rentalRm: (map['rental_rm'] as num? ?? 0).toDouble(),
        rentalMaxRm:
            (map['rental_max_rm'] as num? ?? (map['rental_rm'] as num? ?? 0))
                .toDouble(),
        sizeSqft: (map['size_sqft'] as num? ?? 0).toDouble(),
        latitude: (map['latitude'] as num? ?? 0).toDouble(),
        longitude: (map['longitude'] as num? ?? 0).toDouble(),
        propertyType: '${map['property_type'] ?? 'Shoplot unit'}',
        verification: '${map['verification'] ?? 'draft'}',
        suitabilityScore: (map['suitability_score'] as num? ?? 0).toDouble(),
        ownerId: '${map['owner_id'] ?? ''}',
        hasTour: map['has_tour'] == true,
        requirements: List<String>.from(map['requirements'] as List? ?? []),
        tags: List<String>.from(map['tags'] as List? ?? []),
      );

  CommercialProperty toEntity() => CommercialProperty(
    id: id,
    title: title,
    address: address,
    city: city,
    state: state,
    postcode: postcode,
    rentalRm: rentalRm,
    rentalMaxRm: rentalMaxRm,
    sizeSqft: sizeSqft,
    latitude: latitude,
    longitude: longitude,
    propertyType: propertyType,
    verification: VerificationStatus.values.firstWhere(
      (v) => v.name == verification,
      orElse: () => VerificationStatus.draft,
    ),
    suitabilityScore: suitabilityScore,
    ownerId: ownerId,
    hasTour: hasTour,
    requirements: requirements,
    tags: tags,
  );
}
