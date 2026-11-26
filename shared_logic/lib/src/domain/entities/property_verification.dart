// ## Wire-decoding compatibility boundary
//
// The `fromJson` factories in this library are retained for public API
// compatibility: `fyp_mobile_app` and `fyp_jaspr_web` call some of them
// directly, and removing them would require coordinated edits in both apps
// (outside this package's scope). New transport code must decode through
// the data-layer mappers (`src/data/mappers/`), which are the authoritative
// entry points for backend payloads. These factories contain no business
// rules — they only decode the wire shape, with field names preserved.

/// Unified property verification workflow — the shared model behind the
/// owner submission flow and the administrator review workspace.
///
/// One verification per owner-submitted property (`property.property_id`),
/// with TWO independent dimensions:
///  - listing accuracy (title / address / type / rent / area / description /
///    photos / facilities as submitted), and
///  - ownership & authority (owner identity + deed or authorised-agent letter
///    + authority expiry).
///
/// A property becomes publication-eligible only when BOTH dimensions are
/// verified; the backend recomputes that rule on every decision, so this
/// package only transports the resulting flag.
///
/// Pure Dart — no Flutter, no HTTP and no Jaspr imports. JSON keys mirror the
/// FastAPI payloads exactly (`backend/src/sitewise/services/
/// property_verification_service.py`); every field is read defensively so an
/// added backend column can never break a render.

import 'recommendation_search.dart' show ListingManagement;

// PostgreSQL NUMERIC/DECIMAL may arrive in JSON as either a number or a
// decimal string (for example "32.00"). Decode at the transport boundary;
// do not turn missing/invalid measurements into zero.
num? _wireNum(Object? value) {
  if (value is num) return value.isFinite ? value : null;
  if (value is String) {
    final parsed = num.tryParse(value.trim());
    return parsed != null && parsed.isFinite ? parsed : null;
  }
  return null;
}

double? _wireDouble(Object? value) => _wireNum(value)?.toDouble();
int? _wireInt(Object? value) => _wireNum(value)?.toInt();

/// A wire object, or an empty map when the field is absent or of another type.
Map _wireMap(Object? value) => value is Map ? value : const {};

/// A wire list of strings, ignoring anything that is not a list.
List<String> _wireStringList(Object? value) => [
  for (final item in value is List ? value : const []) item.toString(),
];

/// Which review dimension an action, document or audit row belongs to.
enum VerificationDimension { listing, ownership }

extension VerificationDimensionX on VerificationDimension {
  String get label => switch (this) {
    VerificationDimension.listing => 'Listing accuracy',
    VerificationDimension.ownership => 'Ownership & authority',
  };

  /// Wire name used by the API (`dimension` field) and the audit action
  /// prefix (`listing_…` / `ownership_…`).
  String get wire => name;
}

VerificationDimension? dimensionFromWire(Object? value) => switch (value) {
  'listing' => VerificationDimension.listing,
  'ownership' => VerificationDimension.ownership,
  _ => null,
};

/// Status of one verification dimension. The same six-value vocabulary
/// applies to the listing and the ownership dimension.
enum PropertyVerificationStatus {
  notSubmitted,
  pending,
  underReview,
  verified,
  rejected,
  informationRequested;

  String get wire => switch (this) {
    PropertyVerificationStatus.notSubmitted => 'not_submitted',
    PropertyVerificationStatus.pending => 'pending',
    PropertyVerificationStatus.underReview => 'under_review',
    PropertyVerificationStatus.verified => 'verified',
    PropertyVerificationStatus.rejected => 'rejected',
    PropertyVerificationStatus.informationRequested => 'information_requested',
  };

  String get label => switch (this) {
    PropertyVerificationStatus.notSubmitted => 'Not submitted',
    PropertyVerificationStatus.pending => 'Awaiting review',
    PropertyVerificationStatus.underReview => 'Under review',
    PropertyVerificationStatus.verified => 'Verified',
    PropertyVerificationStatus.rejected => 'Rejected',
    PropertyVerificationStatus.informationRequested => 'Information requested',
  };
}

PropertyVerificationStatus? verificationStatusFromWire(Object? value) {
  for (final status in PropertyVerificationStatus.values) {
    if (status.wire == value) return status;
  }
  return null;
}

/// One dimension's review lifecycle, transported as a pair.
class DimensionStatuses {
  final PropertyVerificationStatus listing;
  final PropertyVerificationStatus ownership;

  const DimensionStatuses({required this.listing, required this.ownership});

  PropertyVerificationStatus statusOf(VerificationDimension dimension) =>
      dimension == VerificationDimension.listing ? listing : ownership;
}

/// The verification record of one property (both dimensions).
class PropertyVerification {
  final String verificationId;
  final int propertyId;
  final PropertyVerificationStatus listingStatus;
  final PropertyVerificationStatus ownershipStatus;
  final String submittedBy;
  final String? reviewedBy;
  final bool publicationEligible;

  /// Latest staff-facing note (a rejection reason or an information
  /// request). `null` = nothing outstanding.
  final String? latestNote;

  /// Optimistic-concurrency counter, bumped by every decision.
  final int version;
  final String? submittedAt;
  final String? updatedAt;

  const PropertyVerification({
    required this.verificationId,
    required this.propertyId,
    required this.listingStatus,
    required this.ownershipStatus,
    required this.submittedBy,
    this.reviewedBy,
    required this.publicationEligible,
    this.latestNote,
    required this.version,
    this.submittedAt,
    this.updatedAt,
  });

  DimensionStatuses get statuses =>
      DimensionStatuses(listing: listingStatus, ownership: ownershipStatus);

  factory PropertyVerification.fromJson(Map<String, dynamic> row) =>
      PropertyVerification(
        verificationId: '${row['verification_id'] ?? ''}',
        propertyId: _wireInt(row['property_id']) ?? 0,
        listingStatus:
            verificationStatusFromWire(row['listing_status']) ??
            PropertyVerificationStatus.notSubmitted,
        ownershipStatus:
            verificationStatusFromWire(row['ownership_status']) ??
            PropertyVerificationStatus.notSubmitted,
        submittedBy: '${row['submitted_by'] ?? ''}',
        reviewedBy: row['reviewed_by'] == null ? null : '${row['reviewed_by']}',
        publicationEligible: row['publication_eligible'] == true,
        latestNote: row['latest_note'] == null ? null : '${row['latest_note']}',
        version: _wireInt(row['version']) ?? 1,
        submittedAt: row['submitted_at'] == null
            ? null
            : '${row['submitted_at']}',
        updatedAt: row['updated_at'] == null ? null : '${row['updated_at']}',
      );

  PropertyVerification copyWith({
    PropertyVerificationStatus? listingStatus,
    PropertyVerificationStatus? ownershipStatus,
    String? reviewedBy,
    bool clearReviewedBy = false,
    bool? publicationEligible,
    String? latestNote,
    bool clearLatestNote = false,
    int? version,
    String? updatedAt,
  }) => PropertyVerification(
    verificationId: verificationId,
    propertyId: propertyId,
    listingStatus: listingStatus ?? this.listingStatus,
    ownershipStatus: ownershipStatus ?? this.ownershipStatus,
    submittedBy: submittedBy,
    reviewedBy: clearReviewedBy ? null : (reviewedBy ?? this.reviewedBy),
    publicationEligible: publicationEligible ?? this.publicationEligible,
    latestNote: clearLatestNote ? null : (latestNote ?? this.latestNote),
    version: version ?? this.version,
    submittedAt: submittedAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
}

/// One evidence document. Metadata only — bytes are streamed through the
/// authenticated download endpoint and are never held in this model.
class VerificationDocument {
  final String documentId;
  final String verificationId;
  final int propertyId;

  /// Which dimension the evidence supports.
  final VerificationDimension? verificationType;

  /// Free-text classification (Deed, SSM extract, signed letter, photos…).
  final String documentType;
  final String originalFilename;
  final String mimeType;
  final int fileSize;
  final String? uploadedAt;

  /// `active` while it counts as evidence; the backend marks superseded
  /// uploads instead of deleting rows.
  final String status;

  const VerificationDocument({
    required this.documentId,
    required this.verificationId,
    required this.propertyId,
    required this.verificationType,
    required this.documentType,
    required this.originalFilename,
    required this.mimeType,
    required this.fileSize,
    this.uploadedAt,
    required this.status,
  });

  bool get isActive => status == 'active';

  factory VerificationDocument.fromJson(Map<String, dynamic> row) =>
      VerificationDocument(
        documentId: '${row['document_id'] ?? ''}',
        verificationId: '${row['verification_id'] ?? ''}',
        propertyId: _wireInt(row['property_id']) ?? 0,
        verificationType: dimensionFromWire(row['verification_type']),
        documentType: '${row['document_type'] ?? ''}'.trim(),
        originalFilename: '${row['original_filename'] ?? ''}'.trim(),
        mimeType: '${row['mime_type'] ?? ''}',
        fileSize: _wireInt(row['file_size']) ?? 0,
        uploadedAt: row['uploaded_at'] == null ? null : '${row['uploaded_at']}',
        status: '${row['status'] ?? 'active'}',
      );
}

/// One audit row — the append-only history of a verification.
class VerificationReviewEvent {
  final String auditId;
  final int propertyId;
  final String? verificationId;
  final VerificationDimension? verificationType;
  final String? previousStatus;
  final String? newStatus;

  /// `submitted`, `evidence_uploaded`, `listing_approved`,
  /// `ownership_rejected`, `listing_information_requested`, …
  final String action;

  /// The administrator's account id; `null` on submitter-side rows.
  final String? adminUserId;
  final String? reason;
  final String? createdAt;

  const VerificationReviewEvent({
    required this.auditId,
    required this.propertyId,
    this.verificationId,
    required this.verificationType,
    this.previousStatus,
    this.newStatus,
    required this.action,
    this.adminUserId,
    this.reason,
    this.createdAt,
  });

  VerificationDimension? get dimension =>
      verificationType ?? dimensionFromWire(action.split('_').first);

  /// Grouping label for the timeline (`listing_review_started` →
  /// `Listing review started`).
  String get label {
    final words = action
        .split('_')
        .map((w) => w.isEmpty ? w : w[0].toUpperCase() + w.substring(1));
    return words.join(' ');
  }

  factory VerificationReviewEvent.fromJson(Map<String, dynamic> row) =>
      VerificationReviewEvent(
        auditId: '${row['audit_id'] ?? ''}',
        propertyId: _wireInt(row['property_id']) ?? 0,
        verificationId: row['verification_id'] == null
            ? null
            : '${row['verification_id']}',
        verificationType: dimensionFromWire(row['verification_type']),
        previousStatus: row['previous_status'] == null
            ? null
            : '${row['previous_status']}',
        newStatus: row['new_status'] == null ? null : '${row['new_status']}',
        action: '${row['action'] ?? ''}',
        adminUserId: row['admin_user_id'] == null
            ? null
            : '${row['admin_user_id']}',
        reason: row['reason'] == null ? null : '${row['reason']}',
        createdAt: row['created_at'] == null ? null : '${row['created_at']}',
      );
}

/// The listing snapshot the backend joins into status and detail responses.
/// All descriptive fields are null when the row records nothing — render the
/// absence honestly, never as a zero.
class VerificationProperty {
  final int propertyId;
  final String title;
  final String? description;
  final String? propertyType;
  final double? monthlyRent;
  final double? builtUpAreaSqft;
  final double? landAreaSqft;
  final String? address;
  final String? city;
  final String? state;
  final String? status;
  final String? companyName;

  /// Owning account, stamped server-side from the verified identity.
  final String? userId;

  // --- Listing-information fields (null-safe additions for the Admin
  // -- overview tab; older detail responses simply leave them null). ---
  final String? postcode;

  /// `null` = no usable coordinates (render "Missing coordinates", not 0,0).
  final double? latitude;
  final double? longitude;
  final String? availability;
  final String? floorLevel;
  final String? floorDescription;
  final double? frontageFt;
  final bool? hasParking;
  final String? furnishing;
  final String? tenure;
  final String? unitPosition;
  final int? leaseDurationMonths;
  final bool? leaseDurationNegotiable;
  final String? availableFrom;
  final double? rentalDepositMyr;
  final String? titleType;
  final String? landlordFnbPermission;
  final bool? isFnbSuitable;
  final bool? isPublished;
  final String? addressFormatted;
  final String? addressValidationStatus;

  const VerificationProperty({
    required this.propertyId,
    required this.title,
    this.description,
    this.propertyType,
    this.monthlyRent,
    this.builtUpAreaSqft,
    this.landAreaSqft,
    this.address,
    this.city,
    this.state,
    this.status,
    this.companyName,
    this.userId,
    this.postcode,
    this.latitude,
    this.longitude,
    this.availability,
    this.floorLevel,
    this.floorDescription,
    this.frontageFt,
    this.hasParking,
    this.furnishing,
    this.tenure,
    this.unitPosition,
    this.leaseDurationMonths,
    this.leaseDurationNegotiable,
    this.availableFrom,
    this.rentalDepositMyr,
    this.titleType,
    this.landlordFnbPermission,
    this.isFnbSuitable,
    this.isPublished,
    this.addressFormatted,
    this.addressValidationStatus,
  });

  factory VerificationProperty.fromJson(
    Map<String, dynamic> row,
  ) => VerificationProperty(
    propertyId: _wireInt(row['property_id']) ?? 0,
    title: '${row['title'] ?? ''}'.trim(),
    description: row['description'] == null ? null : '${row['description']}',
    propertyType: row['property_type'] == null
        ? null
        : '${row['property_type']}',
    monthlyRent: _wireDouble(row['monthly_rent']),
    builtUpAreaSqft: _wireDouble(row['built_up_area_sqft']),
    landAreaSqft: _wireDouble(row['land_area_sqft']),
    address: row['address'] == null ? null : '${row['address']}',
    city: row['city'] == null ? null : '${row['city']}',
    state: row['state'] == null ? null : '${row['state']}',
    status: row['status'] == null ? null : '${row['status']}',
    companyName: row['company_name'] == null ? null : '${row['company_name']}',
    userId: row['user_id'] == null ? null : '${row['user_id']}',
    postcode: row['postcode'] == null ? null : '${row['postcode']}',
    latitude: _wireDouble(row['latitude']),
    longitude: _wireDouble(row['longitude']),
    availability: row['availability'] == null ? null : '${row['availability']}',
    floorLevel: row['floor_level'] == null ? null : '${row['floor_level']}',
    floorDescription: row['floor_description']?.toString(),
    frontageFt: _wireDouble(row['frontage_ft']),
    furnishing: row['furnishing']?.toString(),
    tenure: row['tenure']?.toString(),
    unitPosition: row['unit_position']?.toString(),
    hasParking: row['has_parking'] is bool
        ? row['has_parking'] as bool
        : row['has_parking'] == null
        ? null
        : _wireInt(row['has_parking']) == 1,
    leaseDurationMonths: _wireInt(row['lease_duration_months']),
    leaseDurationNegotiable: row['lease_duration_negotiable'] is bool
        ? row['lease_duration_negotiable'] as bool
        : null,
    availableFrom: row['available_from']?.toString(),
    rentalDepositMyr: _wireDouble(row['rental_deposit_myr']),
    titleType: row['title_type']?.toString(),
    landlordFnbPermission: row['landlord_fnb_permission']?.toString(),
    isFnbSuitable: row['is_fnb_suitable'] is bool
        ? row['is_fnb_suitable'] as bool
        : null,
    isPublished: row['is_published'] is bool
        ? row['is_published'] as bool
        : null,
    addressFormatted: row['address_formatted'] == null
        ? null
        : '${row['address_formatted']}',
    addressValidationStatus: row['address_validation_status'] == null
        ? null
        : '${row['address_validation_status']}',
  );

  /// Display title: the recorded title, falling back to the id so a
  /// title-less row stays addressable.
  String get displayName => title.isNotEmpty ? title : '#$propertyId';

  /// Coordinates usable for mapping — false when absent or the (0,0)
  /// "no coordinates" sentinel.
  bool get hasCoordinates {
    final lat = latitude;
    final lon = longitude;
    if (lat == null || lon == null) return false;
    return lat.isFinite &&
        lon.isFinite &&
        lat >= -90 &&
        lat <= 90 &&
        lon >= -180 &&
        lon <= 180 &&
        !(lat == 0 && lon == 0);
  }

  /// Rent per sq ft derived from the submitted values — `null` when either
  /// input is missing or non-positive, never a fabricated 0.
  double? get rentPerSqft {
    final rent = monthlyRent;
    final size = builtUpAreaSqft;
    if (rent == null || size == null || size <= 0) return null;
    return rent / size;
  }
}

/// The owner account joined into the admin detail response; `null` when the
/// property row carries no owning identity.
class VerificationOwner {
  final String userId;
  final String fullName;
  final String email;

  const VerificationOwner({
    required this.userId,
    required this.fullName,
    required this.email,
  });

  String get displayName => fullName.isNotEmpty ? fullName : email;

  factory VerificationOwner.fromJson(Map<String, dynamic> row) =>
      VerificationOwner(
        userId: '${row['user_id'] ?? ''}',
        fullName: '${row['full_name'] ?? ''}'.trim(),
        email: '${row['email'] ?? ''}'.trim(),
      );
}

/// What the owner sees after staff feedback: the latest staff reason per
/// dimension, present only while that dimension still sits in a
/// note-bearing state (rejected / information requested).
class RequestedCorrections {
  final String? listing;
  final String? ownership;

  const RequestedCorrections({this.listing, this.ownership});

  String? forDimension(VerificationDimension dimension) =>
      dimension == VerificationDimension.listing ? listing : ownership;

  factory RequestedCorrections.fromJson(Map<String, dynamic> row) =>
      RequestedCorrections(
        listing: row['listing'] == null ? null : '${row['listing']}',
        ownership: row['ownership'] == null ? null : '${row['ownership']}',
      );
}

/// Owner-side status response for one property.
class VerificationStatusView {
  final VerificationProperty property;
  final PropertyVerification? verification;
  final List<VerificationDocument> documents;
  final RequestedCorrections requestedCorrections;

  const VerificationStatusView({
    required this.property,
    this.verification,
    this.documents = const [],
    this.requestedCorrections = const RequestedCorrections(),
  });

  factory VerificationStatusView.fromJson(Map<String, dynamic> row) =>
      VerificationStatusView(
        property: VerificationProperty.fromJson(
          (row['property'] as Map<String, dynamic>?) ?? const {},
        ),
        verification: row['verification'] is Map<String, dynamic>
            ? PropertyVerification.fromJson(
                row['verification'] as Map<String, dynamic>,
              )
            : null,
        documents: [
          for (final doc
              in (row['documents'] as List? ?? const [])
                  .whereType<Map<String, dynamic>>())
            VerificationDocument.fromJson(doc),
        ],
        requestedCorrections: RequestedCorrections.fromJson(
          (row['requested_corrections'] as Map<String, dynamic>?) ?? const {},
        ),
      );
}

/// One uploaded property photo from `fyp.property_photos`. Display media
/// lives in a public bucket with permanent URLs — distinct from the private
/// [VerificationDocument] evidence files, which stream through the
/// authenticated download endpoint only.
class VerificationPhoto {
  final String photoId;
  final String url;
  final String? caption;
  final bool isPrimary;
  final String? createdAt;

  const VerificationPhoto({
    required this.photoId,
    required this.url,
    this.caption,
    required this.isPrimary,
    this.createdAt,
  });

  factory VerificationPhoto.fromJson(Map<String, dynamic> row) =>
      VerificationPhoto(
        photoId: '${row['id'] ?? row['photo_id'] ?? ''}',
        url: '${row['url'] ?? ''}'.trim(),
        caption: row['caption'] == null ? null : '${row['caption']}',
        isPrimary: row['is_primary'] == true,
        createdAt: row['created_at'] == null ? null : '${row['created_at']}',
      );

  bool get isUsable => url.isNotEmpty;
}

/// The listing's surrounding-amenity record (`fyp.property_features`).
/// Free-text research fields — absent when the row does not exist.
class VerificationAmenities {
  final String? suitableFor;
  final String? nearbyLandmarks;
  final String? amenities;
  final String? remarks;

  const VerificationAmenities({
    this.suitableFor,
    this.nearbyLandmarks,
    this.amenities,
    this.remarks,
  });

  bool get isEmpty =>
      (suitableFor ?? '').trim().isEmpty &&
      (nearbyLandmarks ?? '').trim().isEmpty &&
      (amenities ?? '').trim().isEmpty &&
      (remarks ?? '').trim().isEmpty;

  factory VerificationAmenities.fromJson(Map<String, dynamic> row) =>
      VerificationAmenities(
        suitableFor: row['suitable_for'] == null
            ? null
            : '${row['suitable_for']}',
        nearbyLandmarks: row['nearby_landmarks'] == null
            ? null
            : '${row['nearby_landmarks']}',
        amenities: row['amenities'] == null ? null : '${row['amenities']}',
        remarks: row['remarks'] == null ? null : '${row['remarks']}',
      );
}

/// The precomputed geospatial feature row for THIS numeric listing
/// (`fyp.property_geospatial_features`, keyed by `fyp.rental_properties.id`).
/// Counts are straight-line-radius aggregates of research datasets; a null
/// means the value was never calculated — never rendered as zero.
class VerificationGeoFeatures {
  final num? competitorCount500m;
  final num? competitorCount1km;
  final String? competitorStatus;
  final num? demandGeneratorCount500m;
  final num? demandGeneratorCount1km;
  final String? demandStatus;
  final num? population500m;
  final num? population1km;
  final String? populationStatus;
  final String? populationLevel;
  final num? accessibilityScore;
  final String? accessibilityStatus;
  final num? nearestMajorRoadM;
  final num? roadKm1km;
  final num? incomeMedian;
  final String? marketSegment;
  final num? overallLocationScore;
  final String? calculatedAt;
  final String? contract;

  const VerificationGeoFeatures({
    this.competitorCount500m,
    this.competitorCount1km,
    this.competitorStatus,
    this.demandGeneratorCount500m,
    this.demandGeneratorCount1km,
    this.demandStatus,
    this.population500m,
    this.population1km,
    this.populationStatus,
    this.populationLevel,
    this.accessibilityScore,
    this.accessibilityStatus,
    this.nearestMajorRoadM,
    this.roadKm1km,
    this.incomeMedian,
    this.marketSegment,
    this.overallLocationScore,
    this.calculatedAt,
    this.contract,
  });

  factory VerificationGeoFeatures.fromJson(Map<String, dynamic> row) =>
      VerificationGeoFeatures(
        competitorCount500m: _wireNum(row['competitor_count_500m']),
        competitorCount1km: _wireNum(row['competitor_count_1km']),
        competitorStatus: row['competitor_status'] == null
            ? null
            : '${row['competitor_status']}',
        demandGeneratorCount500m: _wireNum(row['demand_generator_count_500m']),
        demandGeneratorCount1km: _wireNum(row['demand_generator_count_1km']),
        demandStatus: row['demand_status'] == null
            ? null
            : '${row['demand_status']}',
        population500m: _wireNum(row['population_500m']),
        population1km: _wireNum(row['population_1km']),
        populationStatus: row['population_status'] == null
            ? null
            : '${row['population_status']}',
        populationLevel: row['population_level'] == null
            ? null
            : '${row['population_level']}',
        accessibilityScore: _wireNum(row['accessibility_score']),
        accessibilityStatus: row['accessibility_status'] == null
            ? null
            : '${row['accessibility_status']}',
        nearestMajorRoadM: _wireNum(row['nearest_major_road_m']),
        roadKm1km: _wireNum(row['accessibility_road_km_1km']),
        incomeMedian: _wireNum(row['income_median']),
        marketSegment: row['market_segment'] == null
            ? null
            : '${row['market_segment']}',
        overallLocationScore: _wireNum(row['overall_location_score']),
        calculatedAt: row['last_calculated_at'] == null
            ? null
            : '${row['last_calculated_at']}',
        contract: row['contract'] == null ? null : '${row['contract']}',
      );
}

/// One nearby demand generator from the live spatial lookup
/// (`demand_gen.subjects` within a geodesic radius of the listing).
class DemandGeneratorNearby {
  final String subjectId;
  final String name;
  final String? category;
  final num? latitude;
  final num? longitude;
  final num? distanceM;

  const DemandGeneratorNearby({
    required this.subjectId,
    required this.name,
    this.category,
    this.latitude,
    this.longitude,
    this.distanceM,
  });

  factory DemandGeneratorNearby.fromJson(Map<String, dynamic> row) =>
      DemandGeneratorNearby(
        subjectId: '${row['subject_id'] ?? ''}',
        name: '${row['subject_name'] ?? row['name'] ?? ''}'.trim(),
        category: row['subject_category'] == null
            ? null
            : '${row['subject_category']}',
        latitude: _wireNum(row['latitude']),
        longitude: _wireNum(row['longitude']),
        distanceM: _wireNum(row['distance_m']),
      );
}

/// DOSM population-raster intelligence, resolvable only through a VERIFIED
/// research subject link (`fyp_features.property_population_spatial`). A
/// listing without that link has no legitimate population figure — the UI
/// must show "Not calculated", never a substitute.
class VerificationPopulation {
  final num? pop500m;
  final num? pop1km;
  final num? popDensityKm2;
  final num? estimatedHouseholds1km;
  final String? source;
  final String? sourceYear;
  final String? qualityFlag;

  const VerificationPopulation({
    this.pop500m,
    this.pop1km,
    this.popDensityKm2,
    this.estimatedHouseholds1km,
    this.source,
    this.sourceYear,
    this.qualityFlag,
  });

  factory VerificationPopulation.fromJson(Map<String, dynamic> row) =>
      VerificationPopulation(
        pop500m: _wireNum(row['pop_ring_0_500m']),
        pop1km: _wireNum(row['pop_total_1km']),
        popDensityKm2: _wireNum(row['pop_density_km2']),
        estimatedHouseholds1km: _wireNum(row['estimated_households_1km']),
        source: row['population_source'] == null
            ? null
            : '${row['population_source']}',
        sourceYear: row['population_source_year'] == null
            ? null
            : '${row['population_source_year']}',
        qualityFlag: row['population_quality_flag'] == null
            ? null
            : '${row['population_quality_flag']}',
      );
}

/// Administrator detail response: everything about one verification.
/// Data-freshness/provenance block for a property's calculated features.
///
/// Mirrors `fyp.property_feature_freshness`. `status` is one of
/// `current` | `stale` | `pending` | `failed` | `unavailable`; `available`
/// is false when no trustworthy value exists — an unknown state is never
/// rendered as a zero.
class FeatureFreshness {
  final String status;
  final bool available;
  final String? calculationVersion;
  final String? featuresCalculatedAt;
  final String? lastRefreshAttemptAt;
  final String? lastSuccessfulRefreshAt;
  final String? sourceRelease;
  final String? competitorSource;
  final String? lastError;
  final String? reason;

  const FeatureFreshness({
    required this.status,
    required this.available,
    this.calculationVersion,
    this.featuresCalculatedAt,
    this.lastRefreshAttemptAt,
    this.lastSuccessfulRefreshAt,
    this.sourceRelease,
    this.competitorSource,
    this.lastError,
    this.reason,
  });

  factory FeatureFreshness.fromJson(Map<String, dynamic> row) =>
      FeatureFreshness(
        status: '${row['status'] ?? 'unavailable'}',
        available: row['available'] == true,
        calculationVersion: row['calculation_version']?.toString(),
        featuresCalculatedAt: row['features_calculated_at']?.toString(),
        lastRefreshAttemptAt: row['last_refresh_attempt_at']?.toString(),
        lastSuccessfulRefreshAt: row['last_successful_refresh_at']?.toString(),
        sourceRelease: row['source_release']?.toString(),
        competitorSource: row['competitor_source']?.toString(),
        lastError: row['last_error']?.toString(),
        reason: row['reason']?.toString(),
      );

  /// Human label; unknown states fall back to the raw value.
  String get label => switch (status) {
    'current' => 'Current',
    'stale' => 'Outdated',
    'pending' => 'Updating',
    'failed' => 'Calculation failed',
    _ => 'No analytical data',
  };
}

/// One open-data source licence/snapshot in the provenance block.
class SourceProvenance {
  final String sourceName;
  final String? licence;
  final int snapshots;
  final String? latestSnapshot;

  const SourceProvenance({
    required this.sourceName,
    required this.snapshots,
    this.licence,
    this.latestSnapshot,
  });

  factory SourceProvenance.fromJson(Map<String, dynamic> row) =>
      SourceProvenance(
        sourceName: '${row['source_name'] ?? ''}',
        licence: row['source_licence']?.toString(),
        snapshots: _wireInt(row['snapshots']) ?? 0,
        latestSnapshot: row['latest_snapshot']?.toString(),
      );
}

/// Server-assembled verification-support location analysis
/// (`location_analysis` on the staff review detail). Read-only decision
/// support: it never changes verification state.
class LocationAnalysis {
  final String? analysisVersion;
  final String? generatedAt;
  final bool available;
  final String? error;
  final LocationReadinessPart partA;
  final LocationIntelligencePart partB;
  final LocationConfidencePart partC;
  final LocationRecommendation recommendation;

  const LocationAnalysis({
    this.analysisVersion,
    this.generatedAt,
    required this.available,
    this.error,
    required this.partA,
    required this.partB,
    required this.partC,
    required this.recommendation,
  });

  static const LocationAnalysis unavailable = LocationAnalysis(
    available: false,
    partA: LocationReadinessPart(state: 'unavailable'),
    partB: LocationIntelligencePart.empty,
    partC: LocationConfidencePart.empty,
    recommendation: LocationRecommendation(text: ''),
  );

  factory LocationAnalysis.fromJson(Map<String, dynamic> row) {
    if (row.isEmpty) return LocationAnalysis.unavailable;
    Map<String, dynamic>? block(Object? key) {
      final value = row[key];
      return value is Map<String, dynamic> ? value : null;
    }

    return LocationAnalysis(
      analysisVersion: row['analysis_version']?.toString(),
      generatedAt: row['generated_at']?.toString(),
      available: row['available'] == true,
      error: row['error']?.toString(),
      partA: LocationReadinessPart.fromJson(block('part_a') ?? const {}),
      partB: LocationIntelligencePart.fromJson(block('part_b') ?? const {}),
      partC: LocationConfidencePart.fromJson(block('part_c') ?? const {}),
      recommendation: LocationRecommendation.fromJson(
        block('recommendation') ?? const {},
      ),
    );
  }
}

/// Part A — listing verification readiness and its evidence checks.
class LocationReadinessPart {
  final String state;
  final String listingStatus;
  final String ownershipStatus;
  final List<LocationCheck> checks;

  const LocationReadinessPart({
    required this.state,
    this.listingStatus = '',
    this.ownershipStatus = '',
    this.checks = const [],
  });

  factory LocationReadinessPart.fromJson(Map<String, dynamic> row) =>
      LocationReadinessPart(
        state: row['state']?.toString() ?? 'unknown',
        listingStatus: row['listing_status']?.toString() ?? '',
        ownershipStatus: row['ownership_status']?.toString() ?? '',
        checks: [
          for (final check
              in (row['checks'] as List? ?? const [])
                  .whereType<Map<String, dynamic>>())
            LocationCheck.fromJson(check),
        ],
      );
}

class LocationCheck {
  final String id;
  final String label;
  final String status;
  final String detail;

  const LocationCheck({
    required this.id,
    required this.label,
    required this.status,
    required this.detail,
  });

  factory LocationCheck.fromJson(Map<String, dynamic> row) => LocationCheck(
    id: row['id']?.toString() ?? '',
    label: row['label']?.toString() ?? '',
    status: row['status']?.toString() ?? '',
    detail: row['detail']?.toString() ?? '',
  );
}

/// Part B — the five measurement families. Each keeps its method/source and
/// an explicit unavailable reason; absent values stay null, never zero.
class LocationIntelligencePart {
  final LocationPopulationFamily population;
  final LocationSocioeconomicFamily socioeconomic;
  final LocationFnbFamily fnbEnvironment;
  final LocationAccessibilityFamily accessibility;
  final LocationResearchAssociation researchAssociation;

  const LocationIntelligencePart({
    required this.population,
    required this.socioeconomic,
    required this.fnbEnvironment,
    required this.accessibility,
    required this.researchAssociation,
  });

  static const LocationIntelligencePart empty = LocationIntelligencePart(
    population: LocationPopulationFamily.unavailable,
    socioeconomic: LocationSocioeconomicFamily.unavailable,
    fnbEnvironment: LocationFnbFamily.unavailable,
    accessibility: LocationAccessibilityFamily.unavailable,
    researchAssociation: LocationResearchAssociation.unavailable,
  );

  factory LocationIntelligencePart.fromJson(Map<String, dynamic> row) =>
      LocationIntelligencePart(
        population: LocationPopulationFamily.fromJson(
          (row['population'] as Map<String, dynamic>?) ?? const {},
        ),
        socioeconomic: LocationSocioeconomicFamily.fromJson(
          (row['socioeconomic'] as Map<String, dynamic>?) ?? const {},
        ),
        fnbEnvironment: LocationFnbFamily.fromJson(
          (row['fnb_environment'] as Map<String, dynamic>?) ?? const {},
        ),
        accessibility: LocationAccessibilityFamily.fromJson(
          (row['accessibility'] as Map<String, dynamic>?) ?? const {},
        ),
        researchAssociation: LocationResearchAssociation.fromJson(
          (row['research_association'] as Map<String, dynamic>?) ?? const {},
        ),
      );
}

class LocationPopulationFamily {
  final bool available;
  final String method;
  final String source;
  final String? unavailableReason;
  final double? pop500m;
  final double? pop1km;
  final double? pop3km;
  final double? density1km;
  final double? estimatedHouseholds1km;
  final double? pctAge2034;
  final double? pctAge1564;
  final String? qualityFlag;
  final double? rasterCoveragePct;
  final String? districtKey;
  final double? landscanAmbient1km;
  final double? landscanAmbientRatio1km;
  final String? landscanSourceYear;

  const LocationPopulationFamily({
    required this.available,
    this.method = '',
    this.source = '',
    this.unavailableReason,
    this.pop500m,
    this.pop1km,
    this.pop3km,
    this.density1km,
    this.estimatedHouseholds1km,
    this.pctAge2034,
    this.pctAge1564,
    this.qualityFlag,
    this.rasterCoveragePct,
    this.districtKey,
    this.landscanAmbient1km,
    this.landscanAmbientRatio1km,
    this.landscanSourceYear,
  });

  static const LocationPopulationFamily unavailable = LocationPopulationFamily(
    available: false,
  );

  static double? _d(dynamic v) => _wireDouble(v);

  factory LocationPopulationFamily.fromJson(Map<String, dynamic> row) =>
      LocationPopulationFamily(
        available: row['available'] == true,
        method: row['method']?.toString() ?? '',
        source: row['source']?.toString() ?? '',
        unavailableReason: row['unavailable_reason']?.toString(),
        pop500m: _d(row['pop_500m']),
        pop1km: _d(row['pop_1km']),
        pop3km: _d(row['pop_3km']),
        density1km: _d(row['density_1km']),
        estimatedHouseholds1km: _d(row['estimated_households_1km']),
        pctAge2034: _d(row['pct_age_20_34_1km']),
        pctAge1564: _d(row['pct_age_15_64_1km']),
        qualityFlag: row['quality_flag']?.toString(),
        rasterCoveragePct: _d(row['raster_coverage_pct']),
        districtKey: row['district_key']?.toString(),
        landscanAmbient1km: _d(row['landscan_ambient_1km']),
        landscanAmbientRatio1km: _d(row['landscan_ambient_ratio_1km']),
        landscanSourceYear: row['landscan_source_year']?.toString(),
      );
}

class LocationSocioeconomicFamily {
  final bool available;
  final String method;
  final String source;
  final String? unavailableReason;
  final double? incomeMedian;
  final String? districtKey;

  const LocationSocioeconomicFamily({
    required this.available,
    this.method = '',
    this.source = '',
    this.unavailableReason,
    this.incomeMedian,
    this.districtKey,
  });

  static const LocationSocioeconomicFamily unavailable =
      LocationSocioeconomicFamily(available: false);

  factory LocationSocioeconomicFamily.fromJson(Map<String, dynamic> row) =>
      LocationSocioeconomicFamily(
        available: row['available'] == true,
        method: row['method']?.toString() ?? '',
        source: row['source']?.toString() ?? '',
        unavailableReason: row['unavailable_reason']?.toString(),
        incomeMedian: _wireDouble(row['income_median']),
        districtKey: row['district_key']?.toString(),
      );
}

class LocationFnbFamily {
  final bool available;
  final String method;
  final String source;
  final String? unavailableReason;
  final double? competitorCount500m;
  final double? competitorCount1km;
  final String? competitorStatus;
  final Map<String, double?> competitorBreakdown500m;
  final double? nearestCompetitorM;
  final String? researchAnalysisStatus;
  final double? demandGeneratorCount500m;
  final double? demandGeneratorCount1km;
  final Map<String, double?> nearbyAnchors;
  final bool? ownerDeclaredFnbSuitable;

  const LocationFnbFamily({
    required this.available,
    this.method = '',
    this.source = '',
    this.unavailableReason,
    this.competitorCount500m,
    this.competitorCount1km,
    this.competitorStatus,
    this.competitorBreakdown500m = const {},
    this.nearestCompetitorM,
    this.researchAnalysisStatus,
    this.demandGeneratorCount500m,
    this.demandGeneratorCount1km,
    this.nearbyAnchors = const {},
    this.ownerDeclaredFnbSuitable,
  });

  static const LocationFnbFamily unavailable = LocationFnbFamily(
    available: false,
  );

  static double? _d(dynamic v) => _wireDouble(v);

  static Map<String, double?> _numMap(dynamic raw) => {
    for (final entry in ((raw as Map<String, dynamic>?) ?? const {}).entries)
      entry.key: _d(entry.value),
  };

  factory LocationFnbFamily.fromJson(Map<String, dynamic> row) =>
      LocationFnbFamily(
        available: row['available'] == true,
        method: row['method']?.toString() ?? '',
        source: row['source']?.toString() ?? '',
        unavailableReason: row['unavailable_reason']?.toString(),
        competitorCount500m: _d(row['competitor_count_500m']),
        competitorCount1km: _d(row['competitor_count_1km']),
        competitorStatus: row['competitor_status']?.toString(),
        competitorBreakdown500m: _numMap(row['competitor_breakdown_500m']),
        nearestCompetitorM: _d(row['nearest_competitor_m']),
        researchAnalysisStatus: row['research_analysis_status']?.toString(),
        demandGeneratorCount500m: _d(row['demand_generator_count_500m']),
        demandGeneratorCount1km: _d(row['demand_generator_count_1km']),
        nearbyAnchors: _numMap(row['nearby_anchors']),
        ownerDeclaredFnbSuitable: (row['owner_declared_fnb_suitable'] is bool)
            ? row['owner_declared_fnb_suitable'] as bool
            : null,
      );
}

class LocationAccessibilityFamily {
  final bool available;
  final String method;
  final String source;
  final String? unavailableReason;
  final double? accessibilityScore;
  final String? accessibilityStatus;
  final double? roadKm1km;
  final double? nearestMajorRoadM;
  final Map<String, double?> transit;
  final Map<String, double?> parking;
  final String? parkingStatus;
  final bool? ownerDeclaredParking;
  final String? roadsTransportState;
  final String? parkingState;

  const LocationAccessibilityFamily({
    required this.available,
    this.method = '',
    this.source = '',
    this.unavailableReason,
    this.accessibilityScore,
    this.accessibilityStatus,
    this.roadKm1km,
    this.nearestMajorRoadM,
    this.transit = const {},
    this.parking = const {},
    this.parkingStatus,
    this.ownerDeclaredParking,
    this.roadsTransportState,
    this.parkingState,
  });

  static const LocationAccessibilityFamily unavailable =
      LocationAccessibilityFamily(available: false);

  static double? _d(dynamic v) => _wireDouble(v);

  static Map<String, double?> _numMap(dynamic raw) => {
    for (final entry in ((raw as Map<String, dynamic>?) ?? const {}).entries)
      entry.key: _d(entry.value),
  };

  factory LocationAccessibilityFamily.fromJson(Map<String, dynamic> row) =>
      LocationAccessibilityFamily(
        available: row['available'] == true,
        method: row['method']?.toString() ?? '',
        source: row['source']?.toString() ?? '',
        unavailableReason: row['unavailable_reason']?.toString(),
        accessibilityScore: _d(row['accessibility_score']),
        accessibilityStatus: row['accessibility_status']?.toString(),
        roadKm1km: _d(row['road_km_1km']),
        nearestMajorRoadM: _d(row['nearest_major_road_m']),
        transit: _numMap(row['transit']),
        parking: _numMap(row['parking']),
        parkingStatus: row['parking_status']?.toString(),
        ownerDeclaredParking: (row['owner_declared_parking'] is bool)
            ? row['owner_declared_parking'] as bool
            : null,
        roadsTransportState: row['roads_transport_state']?.toString(),
        parkingState: row['parking_state']?.toString(),
      );
}

/// §5E — strict PU research assessment: never a business-success probability.
class LocationResearchAssociation {
  final bool available;
  final bool predictionPending;
  final Map<String, dynamic> districtContext;
  final Map<String, dynamic> explanation;
  final String? explanationUnavailableReason;
  final double? score;
  final String? label;
  final String? modelVersion;
  final String scoreMeaning;
  final int? featureCount;
  final int? modelFeatureCount;
  final int? modelAvailableFeatures;
  final int? availableFeatures;
  final List<String> missingFeatures;
  // SITEWISE_ADMIN_EXPANDED64_V1
  final Map<String, double> featureValues;
  final Map<String, String> featureSources;
  final Map<String, String> featureMethods;
  final List<String> unvalidatedFeatures;
  final List<String> imputableFeatures;
  final String? unavailableReason;
  final String calculationStatus;
  final bool hasCoordinates;
  final int calculatedFeatures;
  final Map<String, String> featureStates;
  final Map<String, Map<String, dynamic>> measurementCategories;
  /// Server address verdict for the stored coordinates. ``validated`` and
  /// ``partially_validated`` both carry provider-derived coordinates;
  /// anything else means the location was never confirmed.
  final String? addressValidationStatus;

  /// True when the listing has enough saved address detail (street, city and
  /// state) for the geocoding provider to place it. A listing with an address
  /// but no coordinates is therefore still analysable: the analysis action
  /// resolves the location first. False means the address itself must be
  /// completed before any measurement can run.
  final bool addressGeocodable;

  /// Address components still missing when [addressGeocodable] is false.
  final List<String> addressMissingFields;

  const LocationResearchAssociation({
    required this.available,
    this.predictionPending = false,
    this.districtContext = const {},
    this.explanation = const {},
    this.explanationUnavailableReason,
    this.score,
    this.label,
    this.modelVersion,
    this.scoreMeaning = '',
    this.featureCount,
    this.modelFeatureCount,
    this.modelAvailableFeatures,
    this.availableFeatures,
    this.missingFeatures = const [],
    this.featureValues = const {},
    this.featureSources = const {},
    this.featureMethods = const {},
    this.unvalidatedFeatures = const [],
    this.imputableFeatures = const [],
    this.unavailableReason,
    this.calculationStatus = 'not_calculated',
    this.hasCoordinates = true,
    this.calculatedFeatures = 0,
    this.featureStates = const {},
    this.measurementCategories = const {},
    this.addressValidationStatus,
    this.addressGeocodable = false,
    this.addressMissingFields = const [],
  });

  static const LocationResearchAssociation unavailable =
      LocationResearchAssociation(available: false);

  factory LocationResearchAssociation.fromJson(
    Map<String, dynamic> row,
  ) => LocationResearchAssociation(
    districtContext:
        (row['district_context'] as Map?)?.cast<String, dynamic>() ?? const {},
    explanation:
        (row['explanation'] as Map?)?.cast<String, dynamic>() ?? const {},
    explanationUnavailableReason: row['explanation_unavailable_reason']
        ?.toString(),
    predictionPending: row['prediction_pending'] == true,
    available: row['available'] == true,
    score: _wireDouble(row['score']),
    label: row['label']?.toString(),
    modelVersion: row['model_version']?.toString(),
    scoreMeaning: row['score_meaning']?.toString() ?? '',
    modelFeatureCount: _wireInt(row['model_feature_count']),
    modelAvailableFeatures: _wireInt(row['model_available_features']),
    featureCount: _wireInt(row['feature_count']),
    availableFeatures: _wireInt(row['available_features']),
    missingFeatures: [
      for (final name in (row['missing_features'] as List? ?? const []))
        name.toString(),
    ],
    featureValues: {
      for (final entry
          in (row['feature_values'] is Map
                  ? row['feature_values'] as Map
                  : const {})
              .entries)
        if (entry.value is num && (entry.value as num).isFinite)
          entry.key.toString(): (entry.value as num).toDouble(),
    },
    featureSources: {
      for (final entry
          in (row['feature_sources'] is Map
                  ? row['feature_sources'] as Map
                  : const {})
              .entries)
        if (entry.value != null) entry.key.toString(): entry.value.toString(),
    },
    featureMethods: {
      for (final entry in (row['feature_methods'] as Map? ?? const {}).entries)
        entry.key.toString(): entry.value.toString(),
    },
    unvalidatedFeatures: [
      for (final name in (row['unvalidated_features'] as List? ?? const []))
        name.toString(),
    ],
    imputableFeatures: [
      for (final name in (row['imputable_features'] as List? ?? const []))
        name.toString(),
    ],
    unavailableReason: row['unavailable_reason']?.toString(),
    calculationStatus:
        row['calculation_status']?.toString() ?? 'not_calculated',
    hasCoordinates: row['has_coordinates'] != false,
    calculatedFeatures: _wireInt(row['calculated_features']) ?? 0,
    featureStates: {
      for (final entry in (row['feature_states'] as Map? ?? const {}).entries)
        entry.key.toString(): entry.value.toString(),
    },
    measurementCategories: {
      for (final entry in (row['categories'] as Map? ?? const {}).entries)
        if (entry.value is Map)
          entry.key.toString(): Map<String, dynamic>.from(entry.value as Map),
    },
    addressValidationStatus: row['address_validation_status']?.toString(),
    addressGeocodable:
        _wireMap(row['address_resolution'])['geocodable'] == true,
    addressMissingFields: _wireStringList(
      _wireMap(row['address_resolution'])['missing_fields'],
    ),
  );
}

/// Part C — data confidence.
class LocationConfidencePart {
  final int familiesTotal;
  final int familiesAvailable;
  final List<String> familiesAvailableNames;
  final List<LocationDataGap> missing;
  final List<LocationDataGap> outdated;
  final List<String> resolutionNotes;
  final List<LocationLicence> licences;

  const LocationConfidencePart({
    required this.familiesTotal,
    required this.familiesAvailable,
    this.familiesAvailableNames = const [],
    this.missing = const [],
    this.outdated = const [],
    this.resolutionNotes = const [],
    this.licences = const [],
  });

  static const LocationConfidencePart empty = LocationConfidencePart(
    familiesTotal: 0,
    familiesAvailable: 0,
  );

  factory LocationConfidencePart.fromJson(Map<String, dynamic> row) =>
      LocationConfidencePart(
        familiesTotal: _wireInt(row['families_total']) ?? 0,
        familiesAvailable: _wireInt(row['families_available']) ?? 0,
        familiesAvailableNames: [
          for (final name
              in (row['families_available_names'] as List? ?? const []))
            name.toString(),
        ],
        missing: [
          for (final gap
              in (row['missing'] as List? ?? const [])
                  .whereType<Map<String, dynamic>>())
            LocationDataGap.fromJson(gap),
        ],
        outdated: [
          for (final gap
              in (row['outdated'] as List? ?? const [])
                  .whereType<Map<String, dynamic>>())
            LocationDataGap.fromJson(gap),
        ],
        resolutionNotes: [
          for (final note in (row['resolution_notes'] as List? ?? const []))
            note.toString(),
        ],
        licences: [
          for (final licence
              in (row['licences'] as List? ?? const [])
                  .whereType<Map<String, dynamic>>())
            LocationLicence.fromJson(licence),
        ],
      );
}

class LocationDataGap {
  final String family;
  final String reason;
  final String? status;
  final String? detail;

  const LocationDataGap({
    required this.family,
    required this.reason,
    this.status,
    this.detail,
  });

  factory LocationDataGap.fromJson(Map<String, dynamic> row) => LocationDataGap(
    family: (row['family'] ?? row['what'])?.toString() ?? '',
    reason: (row['reason'] ?? row['detail'])?.toString() ?? '',
    status: row['status']?.toString(),
    detail: row['detail']?.toString(),
  );
}

class LocationLicence {
  final String source;
  final String? licence;

  const LocationLicence({required this.source, this.licence});

  factory LocationLicence.fromJson(Map<String, dynamic> row) => LocationLicence(
    source: row['source']?.toString() ?? '',
    licence: row['licence']?.toString(),
  );
}

/// §9 — recommendation with explicit policy separation.
class LocationRecommendation {
  final String text;
  final List<LocationPolicyItem> policySeparation;
  final List<String> suggestedFocus;

  const LocationRecommendation({
    required this.text,
    this.policySeparation = const [],
    this.suggestedFocus = const [],
  });

  factory LocationRecommendation.fromJson(Map<String, dynamic> row) =>
      LocationRecommendation(
        text: row['text']?.toString() ?? '',
        policySeparation: [
          for (final item
              in (row['policy_separation'] as List? ?? const [])
                  .whereType<Map<String, dynamic>>())
            LocationPolicyItem.fromJson(item),
        ],
        suggestedFocus: [
          for (final item in (row['suggested_focus'] as List? ?? const []))
            item.toString(),
        ],
      );
}

class LocationPolicyItem {
  final String domain;
  final String? currentStatus;
  final bool? isPublished;
  final String note;

  const LocationPolicyItem({
    required this.domain,
    this.currentStatus,
    this.isPublished,
    required this.note,
  });

  factory LocationPolicyItem.fromJson(Map<String, dynamic> row) =>
      LocationPolicyItem(
        domain: row['domain']?.toString() ?? '',
        currentStatus: row['current_status']?.toString(),
        isPublished: row['is_published'] is bool
            ? row['is_published'] as bool
            : null,
        note: row['note']?.toString() ?? '',
      );
}

class VerificationDetail {
  final VerificationProperty property;
  final Map<String, dynamic> finalReview;
  final VerificationOwner? owner;
  final PropertyVerification verification;
  final List<VerificationDocument> documents;
  final List<VerificationReviewEvent> history;

  /// Uploaded display photos (`fyp.property_photos`) — empty when the
  /// submission has none; the UI renders a meaningful empty state.
  final List<VerificationPhoto> photos;

  /// Surrounding-amenity research text; `null` when no row exists.
  final VerificationAmenities? amenities;

  /// Precomputed geospatial features for this listing; `null` when the
  /// listing has not been analysed ("Not calculated for this property").
  final VerificationGeoFeatures? geoFeatures;

  /// Nearby demand generators from the live spatial lookup (may be empty —
  /// e.g. when the listing has no usable coordinates).
  final List<DemandGeneratorNearby> demandGenerators;

  /// Research population snapshot; `null` without a verified subject link.
  final VerificationPopulation? population;

  /// Feature freshness (current / stale / pending / failed / unavailable).
  final FeatureFreshness? freshness;

  /// Open-data source provenance/licences backing the calculated features.
  final List<SourceProvenance> provenance;

  /// Server-assembled location analysis (Parts A/B/C + recommendation);
  /// `available: false` payload when it could not be assembled.
  final LocationAnalysis locationAnalysis;

  const VerificationDetail({
    required this.property,
    this.finalReview = const {},
    this.owner,
    required this.verification,
    this.documents = const [],
    this.history = const [],
    this.photos = const [],
    this.amenities,
    this.geoFeatures,
    this.demandGenerators = const [],
    this.population,
    this.freshness,
    this.provenance = const [],
    this.locationAnalysis = LocationAnalysis.unavailable,
  });

  factory VerificationDetail.fromJson(Map<String, dynamic> row) =>
      VerificationDetail(
        finalReview: (row['final_review'] as Map<String, dynamic>?) ?? const {},
        property: VerificationProperty.fromJson(
          (row['property'] as Map<String, dynamic>?) ?? const {},
        ),
        owner: row['owner'] is Map<String, dynamic>
            ? VerificationOwner.fromJson(row['owner'] as Map<String, dynamic>)
            : null,
        verification: PropertyVerification.fromJson(
          (row['verification'] as Map<String, dynamic>?) ?? const {},
        ),
        documents: [
          for (final doc
              in (row['documents'] as List? ?? const [])
                  .whereType<Map<String, dynamic>>())
            VerificationDocument.fromJson(doc),
        ],
        history: [
          for (final event
              in (row['history'] as List? ?? const [])
                  .whereType<Map<String, dynamic>>())
            VerificationReviewEvent.fromJson(event),
        ],
        photos: [
          for (final photo
              in (row['photos'] as List? ?? const [])
                  .whereType<Map<String, dynamic>>())
            VerificationPhoto.fromJson(photo),
        ],
        amenities: row['amenities'] is Map<String, dynamic>
            ? VerificationAmenities.fromJson(
                row['amenities'] as Map<String, dynamic>,
              )
            : null,
        geoFeatures: row['geo_features'] is Map<String, dynamic>
            ? VerificationGeoFeatures.fromJson(
                row['geo_features'] as Map<String, dynamic>,
              )
            : null,
        demandGenerators: [
          for (final generator
              in (row['demand_generators'] as List? ?? const [])
                  .whereType<Map<String, dynamic>>())
            DemandGeneratorNearby.fromJson(generator),
        ],
        population: row['population'] is Map<String, dynamic>
            ? VerificationPopulation.fromJson(
                row['population'] as Map<String, dynamic>,
              )
            : null,
        freshness: row['freshness'] is Map<String, dynamic>
            ? FeatureFreshness.fromJson(
                row['freshness'] as Map<String, dynamic>,
              )
            : null,
        provenance: [
          for (final source
              in ((row['provenance'] as Map<String, dynamic>?)?['sources']
                          as List? ??
                      const [])
                  .whereType<Map<String, dynamic>>())
            SourceProvenance.fromJson(source),
        ],
        locationAnalysis: row['location_analysis'] is Map<String, dynamic>
            ? LocationAnalysis.fromJson(
                row['location_analysis'] as Map<String, dynamic>,
              )
            : LocationAnalysis.unavailable,
      );
}

/// Composable, server-side queue filters. Every field is optional; the
/// backend applies them in one SQL pass, so the UI composes them freely
/// instead of filtering in memory.
class VerificationQueueFilters {
  final String? q;
  final PropertyVerificationStatus? listingStatus;
  final PropertyVerificationStatus? ownershipStatus;
  final String? propertyType;
  final String? state;
  final String? city;

  /// ISO-8601 submission-window bounds.
  final String? submittedFrom;
  final String? submittedTo;

  /// `submitted_at | updated_at | title | monthly_rent`.
  final String sort;

  /// `asc | desc`.
  final String order;
  final int offset;
  final int limit;

  const VerificationQueueFilters({
    this.q,
    this.listingStatus,
    this.ownershipStatus,
    this.propertyType,
    this.state,
    this.city,
    this.submittedFrom,
    this.submittedTo,
    this.sort = 'submitted_at',
    this.order = 'desc',
    this.offset = 0,
    this.limit = 20,
  });

  const VerificationQueueFilters.initial() : this();

  VerificationQueueFilters copyWith({
    String? q,
    bool clearQ = false,
    PropertyVerificationStatus? listingStatus,
    bool clearListingStatus = false,
    PropertyVerificationStatus? ownershipStatus,
    bool clearOwnershipStatus = false,
    String? propertyType,
    bool clearPropertyType = false,
    String? state,
    bool clearState = false,
    String? city,
    bool clearCity = false,
    String? submittedFrom,
    bool clearSubmittedFrom = false,
    String? submittedTo,
    bool clearSubmittedTo = false,
    String? sort,
    String? order,
    int? offset,
    int? limit,
  }) => VerificationQueueFilters(
    q: clearQ ? null : (q ?? this.q),
    listingStatus: clearListingStatus
        ? null
        : (listingStatus ?? this.listingStatus),
    ownershipStatus: clearOwnershipStatus
        ? null
        : (ownershipStatus ?? this.ownershipStatus),
    propertyType: clearPropertyType
        ? null
        : (propertyType ?? this.propertyType),
    state: clearState ? null : (state ?? this.state),
    city: clearCity ? null : (city ?? this.city),
    submittedFrom: clearSubmittedFrom
        ? null
        : (submittedFrom ?? this.submittedFrom),
    submittedTo: clearSubmittedTo ? null : (submittedTo ?? this.submittedTo),
    sort: sort ?? this.sort,
    order: order ?? this.order,
    offset: offset ?? this.offset,
    limit: limit ?? this.limit,
  );

  /// Query parameters for `GET /api/v1/staff/properties/`.
  Map<String, String> toQuery() => {
    if (q != null && q!.isNotEmpty) 'q': q!,
    if (listingStatus != null) 'listing_status': listingStatus!.wire,
    if (ownershipStatus != null) 'ownership_status': ownershipStatus!.wire,
    if (propertyType != null && propertyType!.isNotEmpty)
      'property_type': propertyType!,
    if (state != null && state!.isNotEmpty) 'state': state!,
    if (city != null && city!.isNotEmpty) 'city': city!,
    if (submittedFrom != null && submittedFrom!.isNotEmpty)
      'submitted_from': submittedFrom!,
    if (submittedTo != null && submittedTo!.isNotEmpty)
      'submitted_to': submittedTo!,
    'sort': sort,
    'order': order,
    'offset': '$offset',
    'limit': '$limit',
  };

  bool get isPristine => this == const VerificationQueueFilters();
}

/// One row of the administrator queue (the flat SQL projection).
class VerificationQueueRow {
  final int propertyId;
  final String title;
  final String? normalizedAddress;
  final String? propertyType;
  final double? monthlyRent;
  final double? builtUpAreaSqft;
  final String? propertyStatus;
  final String? companyName;
  final String? city;
  final String? state;
  final String? verificationId;
  final PropertyVerificationStatus listingStatus;
  final PropertyVerificationStatus ownershipStatus;
  final bool publicationEligible;
  final String? latestNote;
  final String? submittedAt;
  final String? updatedAt;

  /// Derived management responsibility for the listing (Agent, Owner, platform
  /// stewardship or unresolved). Null when the payload omits the block.
  final ListingManagement? management;

  const VerificationQueueRow({
    required this.propertyId,
    required this.title,
    this.normalizedAddress,
    this.propertyType,
    this.monthlyRent,
    this.builtUpAreaSqft,
    this.propertyStatus,
    this.companyName,
    this.city,
    this.state,
    this.verificationId,
    required this.listingStatus,
    required this.ownershipStatus,
    required this.publicationEligible,
    this.latestNote,
    this.submittedAt,
    this.updatedAt,
    this.management,
  });

  String get displayName => title.isNotEmpty ? title : '#$propertyId';

  factory VerificationQueueRow.fromJson(
    Map<String, dynamic> row,
  ) => VerificationQueueRow(
    propertyId: _wireInt(row['property_id']) ?? 0,
    title: '${row['title'] ?? ''}'.trim(),
    normalizedAddress: row['normalized_address'] == null
        ? null
        : '${row['normalized_address']}',
    propertyType: row['property_type_normalized'] == null
        ? null
        : '${row['property_type_normalized']}',
    monthlyRent: _wireDouble(row['price']),
    builtUpAreaSqft: _wireDouble(row['built_up_area_sqft']),
    propertyStatus: row['property_status'] == null
        ? null
        : '${row['property_status']}',
    companyName: row['company_name'] == null ? null : '${row['company_name']}',
    city: row['city'] == null ? null : '${row['city']}',
    state: row['state'] == null ? null : '${row['state']}',
    verificationId: row['verification_id'] == null
        ? null
        : '${row['verification_id']}',
    listingStatus:
        verificationStatusFromWire(row['listing_status']) ??
        PropertyVerificationStatus.notSubmitted,
    ownershipStatus:
        verificationStatusFromWire(row['ownership_status']) ??
        PropertyVerificationStatus.notSubmitted,
    publicationEligible: row['publication_eligible'] == true,
    latestNote: row['latest_note'] == null ? null : '${row['latest_note']}',
    submittedAt: row['submitted_at'] == null ? null : '${row['submitted_at']}',
    updatedAt: row['updated_at'] == null ? null : '${row['updated_at']}',
    management: row['management'] is Map<String, dynamic>
        ? ListingManagement.fromJson(row['management'] as Map<String, dynamic>)
        : null,
  );
}

/// One server-computed page of the queue. `counts` holds the faceted
/// per-status counts the backend computed (each dimension counted WITHOUT
/// its own filter applied), keyed by the status wire name.
class VerificationQueuePage {
  final List<VerificationQueueRow> items;
  final int total;
  final int offset;
  final int limit;
  final Map<VerificationDimension, Map<PropertyVerificationStatus, int>> counts;

  const VerificationQueuePage({
    required this.items,
    required this.total,
    required this.offset,
    required this.limit,
    this.counts = const {},
  });

  int? countOf(
    VerificationDimension dimension,
    PropertyVerificationStatus status,
  ) => counts[dimension]?[status];

  factory VerificationQueuePage.fromJson(Map<String, dynamic> row) {
    Map<PropertyVerificationStatus, int> dimensionCounts(Object? raw) => {
      for (final entry in (raw as Map<String, dynamic>? ?? const {}).entries)
        if (verificationStatusFromWire(entry.key) != null)
          verificationStatusFromWire(entry.key)!: _wireInt(entry.value) ?? 0,
    };
    final counts = row['counts'] as Map<String, dynamic>? ?? const {};
    return VerificationQueuePage(
      items: [
        for (final item
            in (row['items'] as List? ?? const [])
                .whereType<Map<String, dynamic>>())
          VerificationQueueRow.fromJson(item),
      ],
      total: _wireInt(row['total']) ?? 0,
      offset: _wireInt(row['offset']) ?? 0,
      limit: _wireInt(row['limit']) ?? 0,
      counts: {
        if (counts['listing'] is Map<String, dynamic>)
          VerificationDimension.listing: dimensionCounts(counts['listing']),
        if (counts['ownership'] is Map<String, dynamic>)
          VerificationDimension.ownership: dimensionCounts(counts['ownership']),
      },
    );
  }
}
