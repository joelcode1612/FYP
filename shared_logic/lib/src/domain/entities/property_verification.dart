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

VerificationDimension? dimensionFromWire(Object? value) =>
    switch (value) { 'listing' => VerificationDimension.listing, 'ownership' => VerificationDimension.ownership, _ => null };

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

  const DimensionStatuses({
    required this.listing,
    required this.ownership,
  });

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

  DimensionStatuses get statuses => DimensionStatuses(
    listing: listingStatus,
    ownership: ownershipStatus,
  );

  factory PropertyVerification.fromJson(Map<String, dynamic> row) =>
      PropertyVerification(
        verificationId: '${row['verification_id'] ?? ''}',
        propertyId: (row['property_id'] as num?)?.toInt() ?? 0,
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
        version: (row['version'] as num?)?.toInt() ?? 1,
        submittedAt: row['submitted_at'] == null ? null : '${row['submitted_at']}',
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
        propertyId: (row['property_id'] as num?)?.toInt() ?? 0,
        verificationType: dimensionFromWire(row['verification_type']),
        documentType: '${row['document_type'] ?? ''}'.trim(),
        originalFilename: '${row['original_filename'] ?? ''}'.trim(),
        mimeType: '${row['mime_type'] ?? ''}',
        fileSize: (row['file_size'] as num?)?.toInt() ?? 0,
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
    final words = action.split('_').map((w) => w.isEmpty ? w : w[0].toUpperCase() + w.substring(1));
    return words.join(' ');
  }

  factory VerificationReviewEvent.fromJson(Map<String, dynamic> row) =>
      VerificationReviewEvent(
        auditId: '${row['audit_id'] ?? ''}',
        propertyId: (row['property_id'] as num?)?.toInt() ?? 0,
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
  final double? frontageFt;
  final bool? hasParking;
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
    this.frontageFt,
    this.hasParking,
    this.isFnbSuitable,
    this.isPublished,
    this.addressFormatted,
    this.addressValidationStatus,
  });

  factory VerificationProperty.fromJson(Map<String, dynamic> row) =>
      VerificationProperty(
        propertyId: (row['property_id'] as num?)?.toInt() ?? 0,
        title: '${row['title'] ?? ''}'.trim(),
        description: row['description'] == null ? null : '${row['description']}',
        propertyType: row['property_type'] == null
            ? null
            : '${row['property_type']}',
        monthlyRent: (row['monthly_rent'] as num?)?.toDouble(),
        builtUpAreaSqft: (row['built_up_area_sqft'] as num?)?.toDouble(),
        landAreaSqft: (row['land_area_sqft'] as num?)?.toDouble(),
        address: row['address'] == null ? null : '${row['address']}',
        city: row['city'] == null ? null : '${row['city']}',
        state: row['state'] == null ? null : '${row['state']}',
        status: row['status'] == null ? null : '${row['status']}',
        companyName: row['company_name'] == null
            ? null
            : '${row['company_name']}',
        userId: row['user_id'] == null ? null : '${row['user_id']}',
        postcode: row['postcode'] == null ? null : '${row['postcode']}',
        latitude: (row['latitude'] as num?)?.toDouble(),
        longitude: (row['longitude'] as num?)?.toDouble(),
        availability: row['availability'] == null
            ? null
            : '${row['availability']}',
        floorLevel: row['floor_level'] == null
            ? null
            : '${row['floor_level']}',
        frontageFt: (row['frontage_ft'] as num?)?.toDouble(),
        hasParking: row['has_parking'] is bool
            ? row['has_parking'] as bool
            : null,
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
            ? PropertyVerification.fromJson(row['verification'] as Map<String, dynamic>)
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
        competitorCount500m: row['competitor_count_500m'] as num?,
        competitorCount1km: row['competitor_count_1km'] as num?,
        competitorStatus:
            row['competitor_status'] == null
                ? null
                : '${row['competitor_status']}',
        demandGeneratorCount500m:
            row['demand_generator_count_500m'] as num?,
        demandGeneratorCount1km:
            row['demand_generator_count_1km'] as num?,
        demandStatus: row['demand_status'] == null
            ? null
            : '${row['demand_status']}',
        population500m: row['population_500m'] as num?,
        population1km: row['population_1km'] as num?,
        populationStatus: row['population_status'] == null
            ? null
            : '${row['population_status']}',
        populationLevel: row['population_level'] == null
            ? null
            : '${row['population_level']}',
        accessibilityScore: row['accessibility_score'] as num?,
        accessibilityStatus: row['accessibility_status'] == null
            ? null
            : '${row['accessibility_status']}',
        nearestMajorRoadM: row['nearest_major_road_m'] as num?,
        roadKm1km: row['accessibility_road_km_1km'] as num?,
        incomeMedian: row['income_median'] as num?,
        marketSegment: row['market_segment'] == null
            ? null
            : '${row['market_segment']}',
        overallLocationScore: row['overall_location_score'] as num?,
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
        latitude: row['latitude'] as num?,
        longitude: row['longitude'] as num?,
        distanceM: row['distance_m'] as num?,
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
        pop500m: (row['pop_ring_0_500m'] ?? row['pop_total_200m']) as num?,
        pop1km: (row['pop_total_1km'] ?? row['pop_ring_500_1km']) as num?,
        popDensityKm2: row['pop_density_km2'] as num?,
        estimatedHouseholds1km: row['estimated_households_1km'] as num?,
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
class VerificationDetail {
  final VerificationProperty property;
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

  const VerificationDetail({
    required this.property,
    this.owner,
    required this.verification,
    this.documents = const [],
    this.history = const [],
    this.photos = const [],
    this.amenities,
    this.geoFeatures,
    this.demandGenerators = const [],
    this.population,
  });

  factory VerificationDetail.fromJson(Map<String, dynamic> row) =>
      VerificationDetail(
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

  const VerificationQueueFilters.initial()
    : this();

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
    propertyType: clearPropertyType ? null : (propertyType ?? this.propertyType),
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

  bool get isPristine =>
      this == const VerificationQueueFilters();
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
  });

  String get displayName => title.isNotEmpty ? title : '#$propertyId';

  factory VerificationQueueRow.fromJson(Map<String, dynamic> row) =>
      VerificationQueueRow(
        propertyId: (row['property_id'] as num?)?.toInt() ?? 0,
        title: '${row['title'] ?? ''}'.trim(),
        normalizedAddress: row['normalized_address'] == null
            ? null
            : '${row['normalized_address']}',
        propertyType: row['property_type_normalized'] == null
            ? null
            : '${row['property_type_normalized']}',
        monthlyRent: (row['price'] as num?)?.toDouble(),
        builtUpAreaSqft: (row['built_up_area_sqft'] as num?)?.toDouble(),
        propertyStatus: row['property_status'] == null
            ? null
            : '${row['property_status']}',
        companyName: row['company_name'] == null
            ? null
            : '${row['company_name']}',
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
        submittedAt: row['submitted_at'] == null
            ? null
            : '${row['submitted_at']}',
        updatedAt: row['updated_at'] == null ? null : '${row['updated_at']}',
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
      for (final entry
          in (raw as Map<String, dynamic>? ?? const {}).entries)
        if (verificationStatusFromWire(entry.key) != null)
          verificationStatusFromWire(entry.key)!:
              (entry.value as num?)?.toInt() ?? 0,
    };
    final counts = row['counts'] as Map<String, dynamic>? ?? const {};
    return VerificationQueuePage(
      items: [
        for (final item
            in (row['items'] as List? ?? const [])
                .whereType<Map<String, dynamic>>())
          VerificationQueueRow.fromJson(item),
      ],
      total: (row['total'] as num?)?.toInt() ?? 0,
      offset: (row['offset'] as num?)?.toInt() ?? 0,
      limit: (row['limit'] as num?)?.toInt() ?? 0,
      counts: {
        if (counts['listing'] is Map<String, dynamic>)
          VerificationDimension.listing: dimensionCounts(counts['listing']),
        if (counts['ownership'] is Map<String, dynamic>)
          VerificationDimension.ownership: dimensionCounts(
            counts['ownership'],
          ),
      },
    );
  }
}
