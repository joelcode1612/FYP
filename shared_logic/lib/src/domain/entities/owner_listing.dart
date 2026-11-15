import 'commercial_property.dart' show VerificationStatus;
import 'recommendation_search.dart' show ListingManagement;

/// One property photo of an owner listing (`fyp.property_photos`).
class OwnerListingPhoto {
  final int id;
  final String url;
  final String caption;
  final bool isPrimary;
  final String? createdAt;

  const OwnerListingPhoto({
    required this.id,
    required this.url,
    required this.caption,
    required this.isPrimary,
    this.createdAt,
  });

  factory OwnerListingPhoto.fromJson(Map<String, dynamic> row) =>
      OwnerListingPhoto(
        id: (row['id'] as num?)?.toInt() ?? 0,
        url: '${row['url'] ?? ''}',
        caption: '${row['caption'] ?? ''}',
        isPrimary: row['is_primary'] == true,
        createdAt: row['created_at']?.toString(),
      );
}

/// One owner-created rental listing in ANY lifecycle state
/// (`fyp.rental_properties` via `/api/v1/properties/listings*`).
///
/// [verificationStatus] is the backend wire value: `draft`, `pending`,
/// `approved` or `rejected`. [rejectionReason] carries the administrator's
/// rejection/correction text surfaced to the submitter.
class OwnerListing {
  final String id;
  final String? ownerUserId;
  final String name;
  final String? propertyType;
  final String? description;
  final String? address;
  final String? city;
  final String? state;
  /// Five-digit Malaysian postcode (string so leading zeros survive).
  final String? postcode;
  /// Server-attested Google Address Validation verdict: `validated`,
  /// `partially_validated`, `unconfirmed` or null when never validated.
  final String? addressValidationStatus;
  final double? latitude;
  final double? longitude;
  final double? rentalPrice;
  final double? sizeSqft;
  final double? psf;
  final String? availability;
  final double? floorLevel;
  final double? frontageFt;
  final bool hasParking;
  final bool isFnbSuitable;
  final String verificationStatus;
  final String? rejectionReason;
  final bool isPublished;
  final String? createdAt;
  final String? updatedAt;
  final List<OwnerListingPhoto> photos;

  /// Who manages this listing right now, derived by the backend. Null when the
  /// response did not include the block (older server); the owner still sees
  /// their own listing, so no manager is implied.
  final ListingManagement? management;

  const OwnerListing({
    required this.id,
    required this.name,
    required this.verificationStatus,
    this.ownerUserId,
    this.propertyType,
    this.description,
    this.address,
    this.city,
    this.state,
    this.postcode,
    this.addressValidationStatus,
    this.latitude,
    this.longitude,
    this.rentalPrice,
    this.sizeSqft,
    this.psf,
    this.availability,
    this.floorLevel,
    this.frontageFt,
    this.hasParking = false,
    this.isFnbSuitable = false,
    this.rejectionReason,
    this.isPublished = false,
    this.createdAt,
    this.updatedAt,
    this.photos = const [],
    this.management,
  });

  static double? _d(Object? v) => (v is num) ? v.toDouble() : null;

  factory OwnerListing.fromJson(Map<String, dynamic> row) => OwnerListing(
        id: '${row['id'] ?? row['property_id'] ?? ''}',
        ownerUserId: row['owner_user_id']?.toString(),
        name: '${row['name'] ?? ''}',
        propertyType: row['property_type']?.toString(),
        description: row['description']?.toString(),
        address: row['address']?.toString(),
        city: row['city']?.toString(),
        state: row['state']?.toString(),
        postcode: row['postcode']?.toString(),
        addressValidationStatus: row['address_validation_status']?.toString(),
        latitude: _d(row['latitude']),
        longitude: _d(row['longitude']),
        rentalPrice: _d(row['rental_price']),
        sizeSqft: _d(row['size_sqft']),
        psf: _d(row['psf']),
        availability: row['availability']?.toString(),
        floorLevel: _d(row['floor_level']),
        frontageFt: _d(row['frontage_ft']),
        hasParking: (row['has_parking'] as num?)?.toInt() == 1 ||
            row['has_parking'] == true,
        isFnbSuitable: (row['is_fnb_suitable'] as num?)?.toInt() == 1 ||
            row['is_fnb_suitable'] == true,
        verificationStatus: '${row['verification_status'] ?? 'draft'}',
        rejectionReason: row['rejection_reason']?.toString(),
        isPublished: row['is_published'] == true,
        createdAt: row['created_at']?.toString(),
        updatedAt: row['updated_at']?.toString(),
        photos: (row['photos'] as List? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(OwnerListingPhoto.fromJson)
            .toList(),
        management: row['management'] is Map<String, dynamic>
            ? ListingManagement.fromJson(row['management'] as Map<String, dynamic>)
            : null,
      );

  /// The shared status vocabulary used by badges across the app.
  VerificationStatus get status => switch (verificationStatus) {
        'approved' => VerificationStatus.verified,
        'rejected' => VerificationStatus.rejected,
        'pending' => VerificationStatus.pending,
        _ => VerificationStatus.draft,
      };

  /// Editing is a backend policy (pending/under-review records are locked);
  /// this mirrors it for honest UI hints only — the backend decides.
  bool get locallyEditable =>
      verificationStatus == 'draft' || verificationStatus == 'rejected';

  /// The fields the Add-Property wizard writes, in the backend's wire
  /// vocabulary. Null values clear optional fields server-side.
  Map<String, dynamic> toDraftJson({
    String? name,
    String? propertyType,
    String? description,
    String? address,
    String? city,
    String? state,
    String? postcode,
    double? latitude,
    double? longitude,
    double? rentalPrice,
    double? sizeSqft,
    String? availability,
    String? floorLevel,
    double? frontageFt,
    bool? hasParking,
    bool? isFnbSuitable,
  }) =>
      {
        if (name != null) 'name': name,
        'property_type': propertyType,
        'description': description,
        'address': address,
        'city': city,
        'state': state,
        'postcode': postcode,
        'latitude': latitude,
        'longitude': longitude,
        'rental_price': rentalPrice,
        'size_sqft': sizeSqft,
        'availability': availability,
        'floor_level': floorLevel,
        'frontage_ft': frontageFt,
        'has_parking': hasParking ?? false,
        'is_fnb_suitable': isFnbSuitable ?? false,
      };
}
