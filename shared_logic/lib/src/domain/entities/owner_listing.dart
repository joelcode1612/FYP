// ## Wire-decoding compatibility boundary
//
// The `fromJson` factories in this library are retained for public API
// compatibility: `fyp_mobile_app` and `fyp_jaspr_web` call some of them
// directly, and removing them would require coordinated edits in both apps
// (outside this package's scope). New transport code must decode through
// the data-layer mappers (`src/data/mappers/`), which are the authoritative
// entry points for backend payloads. These factories contain no business
// rules — they only decode the wire shape, with field names preserved.

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
  final String? addressFormatted;
  final double? latitude;
  final double? longitude;
  final double? rentalPrice;
  final double? sizeSqft;
  final double? psf;
  final String? availability;
  final double? floorLevel;
  final String? floorDescription;
  final double? frontageFt;
  final String? furnishing;
  final String? tenure;
  final String? unitPosition;
  final bool? hasParking;
  final int? leaseDurationMonths;
  final bool? leaseDurationNegotiable;
  final String? availableFrom;
  final double? rentalDepositMyr;
  final String? titleType;
  final String? landlordFnbPermission;
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

  /// True when the accepted Agent inspection temporarily locks Owner edits.
  final bool agentInspectionActive;

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
    this.addressFormatted,
    this.latitude,
    this.longitude,
    this.rentalPrice,
    this.sizeSqft,
    this.psf,
    this.availability,
    this.floorLevel,
    this.floorDescription,
    this.frontageFt,
    this.furnishing,
    this.tenure,
    this.unitPosition,
    this.hasParking,
    this.leaseDurationMonths,
    this.leaseDurationNegotiable,
    this.availableFrom,
    this.rentalDepositMyr,
    this.titleType,
    this.landlordFnbPermission,
    this.isFnbSuitable = false,
    this.rejectionReason,
    this.isPublished = false,
    this.createdAt,
    this.updatedAt,
    this.photos = const [],
    this.management,
    this.agentInspectionActive = false,
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
    addressFormatted: row['address_formatted']?.toString(),
    latitude: _d(row['latitude']),
    longitude: _d(row['longitude']),
    rentalPrice: _d(row['rental_price']),
    sizeSqft: _d(row['size_sqft']),
    psf: _d(row['psf']),
    availability: row['availability']?.toString(),
    floorLevel: _d(row['floor_level']),
    floorDescription: row['floor_description']?.toString(),
    frontageFt: _d(row['frontage_ft']),
    furnishing: row['furnishing']?.toString(),
    tenure: row['tenure']?.toString(),
    unitPosition: row['unit_position']?.toString(),
    hasParking: row['has_parking'] == null
        ? null
        : (row['has_parking'] as num?)?.toInt() == 1 ||
              row['has_parking'] == true,
    leaseDurationMonths: (row['lease_duration_months'] as num?)?.toInt(),
    leaseDurationNegotiable: row['lease_duration_negotiable'] as bool?,
    availableFrom: row['available_from']?.toString(),
    rentalDepositMyr: _d(row['rental_deposit_myr']),
    titleType: row['title_type']?.toString(),
    landlordFnbPermission: row['landlord_fnb_permission']?.toString(),
    isFnbSuitable:
        (row['is_fnb_suitable'] as num?)?.toInt() == 1 ||
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
    agentInspectionActive: row['owner_edit_locked'] == true,
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
    double? rentalPrice,
    double? sizeSqft,
    String? availability,
    String? floorLevel,
    String? floorDescription,
    double? frontageFt,
    bool? hasParking,
    String? furnishing,
    String? tenure,
    String? unitPosition,
    int? leaseDurationMonths,
    bool? leaseDurationNegotiable,
    String? availableFrom,
    double? rentalDepositMyr,
    String? titleType,
    String? landlordFnbPermission,
    String? draftRequestId,
  }) => {
    if (name != null) 'name': name,
    'property_type': propertyType,
    'description': description,
    'address': address,
    'city': city,
    'state': state,
    'postcode': postcode,
    'rental_price': rentalPrice,
    'size_sqft': sizeSqft,
    'availability': availability,
    'floor_level': floorLevel,
    'floor_description': floorDescription,
    'frontage_ft': frontageFt,
    'furnishing': furnishing,
    'tenure': tenure,
    'unit_position': unitPosition,
    'has_parking': hasParking,
    'lease_duration_months': leaseDurationMonths,
    'lease_duration_negotiable': leaseDurationNegotiable,
    'available_from': availableFrom,
    'rental_deposit_myr': rentalDepositMyr,
    'title_type': titleType,
    'landlord_fnb_permission': landlordFnbPermission,
    if (draftRequestId != null) 'draft_request_id': draftRequestId,
  };
}
